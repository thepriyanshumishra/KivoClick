//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
    case waitingForAction
}

struct PointingTarget: Equatable {
    let id: UUID
    let screenLocation: CGPoint
    let displayFrame: CGRect
    let label: String
    let isFinal: Bool
}

struct TriggerableTarget {
    let triggerTime: TimeInterval
    let screenLocation: CGPoint
    let displayFrame: CGRect
    let label: String
    let isFinal: Bool
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// The active target coordinate the pointer is navigating to or pointing at.
    @Published var currentPointingTarget: PointingTarget? {
        didSet {
            detectedElementScreenLocation = currentPointingTarget?.screenLocation
            detectedElementDisplayFrame = currentPointingTarget?.displayFrame
            detectedElementBubbleText = currentPointingTarget?.label
        }
    }

    /// The interactive click-waiting tutorial state.
    @Published private(set) var isWaitingForClick = false

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "http://localhost:8787"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    private var playbackTimelineTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var shouldWaitForClickAfterSpeech = false

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The AI model used for voice responses. Persisted to UserDefaults with migration.
    @Published var selectedModel: String = {
        let saved = UserDefaults.standard.string(forKey: "selectedClaudeModel")
        if saved == "claude-sonnet-4-6" || saved == "claude-opus-4-6" || saved == "gemini-2.0-flash" || saved == nil {
            return "gemini-3.5-flash"
        }
        return saved!
    }()

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// The voice gender/name used for Gemini TTS responses (e.g. "Aoede" for Female, "Puck" for Male).
    @Published var selectedVoice: String = {
        return UserDefaults.standard.string(forKey: "selectedVoice") ?? "Aoede"
    }()

    func setSelectedVoice(_ voice: String) {
        selectedVoice = voice
        UserDefaults.standard.set(voice, forKey: "selectedVoice")
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .kivoClickDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .kivoClickDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        currentPointingTarget = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        playbackTimelineTimer?.invalidate()
        playbackTimelineTimer = nil
        stopWaitingForClick()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .kivoClickDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            playbackTimelineTimer?.invalidate()
            playbackTimelineTimer = nil
            stopWaitingForClick()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're kivo click, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. USE IT EVERY SINGLE TIME you reference any on-screen element, button, icon, or area.

    RULE: if your response mentions ANY location, button, icon, menu, text field, or area on screen — you MUST point at it. never describe where something is without also pointing at it.
    [GRID:none] is ONLY for pure knowledge questions completely disconnected from the screen (e.g. "what is javascript?" or "how does wifi work?").

    GRID POINTING (preferred — most accurate for all models):
    the screenshot has a visible coordinate grid drawn over it.
    - rows are labeled A through K from top to bottom (11 rows)
    - columns are labeled 01 through 18 from left to right (18 columns)
    - every cell shows its label (e.g. "D09", "B14", "K02") in bold text centered inside the cell

    to point: find the element in the screenshot, read the cell label whose center is closest to the element's center, and use it.
    format: [GRID:RowCol:label] — e.g. [GRID:D09:app store] or [GRID:B02:new conversation]
    always include a label. for elements on a different screen, append :screenN.

    FALLBACK POINTING (if grid labels are unclear):
    format: [POINT:X%,Y%:label] — X is 0-100% from left, Y is 0-100% from top.

    common macOS spatial anchors:
    - macOS menu bar (top strip): row A, Y ≈1-2%
    - dock at bottom (default): row K, Y ≈94-98%
    - apple menu (top-left): A01
    - window title bar / traffic lights: row A or B
    - system tray / menu bar app icons (top-right): row A, high column numbers

    examples:
    - user asks how to open app store (icon visible in dock): "the app store is right in your dock. [GRID:K11:app store]"
    - user asks how to start a new conversation (button top-left): "hit that new conversation button up top-left. [GRID:B02:new conversation]"
    - user asks how to commit in xcode (source control in menu bar): "go to source control in the top menu. [GRID:A04:source control]"
    - user asks what javascript is: "javascript is what makes web pages interactive. [GRID:none]"
    - element on screen 2: "that terminal is on your second monitor. [GRID:F09:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in }
                )

                guard !Task.isCancelled else { return }

                await processVoiceResponse(
                    fullResponseText: fullResponseText,
                    transcriptUsed: transcript,
                    screenCaptures: screenCaptures
                )
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                let isRateLimit = error.localizedDescription.contains("429") || error.localizedDescription.contains("quota") || error.localizedDescription.contains("limit")
                let errorText = isRateLimit ? "Gemini rate limit reached." : "An error occurred."
                voiceState = .responding
                try? await elevenLabsTTSClient.speakText(errorText, voice: selectedVoice)
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func processVoiceResponse(
        fullResponseText: String,
        transcriptUsed: String,
        screenCaptures: [CompanionScreenCapture]
    ) async {
        playbackTimelineTimer?.invalidate()
        playbackTimelineTimer = nil
        currentPointingTarget = nil
        stopWaitingForClick()

        let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
        let spokenText = parseResult.spokenText
        shouldWaitForClickAfterSpeech = parseResult.hasWaitForClick

        var resolvedTargets: [TriggerableTarget] = []

        for (index, tag) in parseResult.targets.enumerated() {
            var targetScreenCapture: CompanionScreenCapture? = {
                if let screenNumber = tag.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenCaptures[screenNumber - 1]
                }
                return screenCaptures.first(where: { $0.isCursorScreen })
            }()

            var resolvedPointCoordinate: CGPoint? = nil
            var axGlobalLocation: CGPoint? = nil
            var axDisplayFrame: CGRect? = nil

            if let elementLabel = tag.elementLabel, !elementLabel.isEmpty {
                print("🎯 Attempting high-accuracy search for label: \"\(elementLabel)\"")
                
                if let axResult = await ElementSearchLocator.locateViaAccessibility(query: elementLabel) {
                    axGlobalLocation = axResult.point
                    axDisplayFrame = axResult.screenFrame
                }

                if axGlobalLocation == nil {
                    var resolvedVisionCoordinate: CGPoint? = nil
                    var resolvedVisionScreenCapture: CompanionScreenCapture? = nil

                    if let target = targetScreenCapture {
                        if let pixelCoord = await ElementSearchLocator.locateViaVisionOCR(query: elementLabel, cleanCGImage: target.cleanCGImage) {
                            resolvedVisionCoordinate = pixelCoord
                            resolvedVisionScreenCapture = target
                        }
                    }

                    if resolvedVisionCoordinate == nil {
                        for capture in screenCaptures {
                            if capture.label != targetScreenCapture?.label {
                                if let pixelCoord = await ElementSearchLocator.locateViaVisionOCR(query: elementLabel, cleanCGImage: capture.cleanCGImage) {
                                    resolvedVisionCoordinate = pixelCoord
                                    resolvedVisionScreenCapture = capture
                                    break
                                }
                            }
                        }
                    }

                    if let pixelCoord = resolvedVisionCoordinate, let capture = resolvedVisionScreenCapture {
                        resolvedPointCoordinate = pixelCoord
                        targetScreenCapture = capture
                    }
                }
            }

            if axGlobalLocation == nil && resolvedPointCoordinate == nil {
                print("🎯 Falling back to model visual estimation (grid/percentage)")
                if let gridCell = tag.gridCell, let target = targetScreenCapture {
                    let screenshotWidth = CGFloat(target.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(target.screenshotHeightInPixels)
                    let cellCenterX = (Double(gridCell.col) + 0.5) * (Double(screenshotWidth) / 18.0)
                    let cellCenterY = (Double(gridCell.row) + 0.5) * (Double(screenshotHeight) / 11.0)
                    resolvedPointCoordinate = CGPoint(x: cellCenterX, y: cellCenterY)
                } else if let rawCoord = tag.coordinate, let target = targetScreenCapture {
                    if tag.isPercentageCoordinate {
                        let screenshotWidth = CGFloat(target.screenshotWidthInPixels)
                        let screenshotHeight = CGFloat(target.screenshotHeightInPixels)
                        resolvedPointCoordinate = CGPoint(
                            x: (rawCoord.x / 100.0) * screenshotWidth,
                            y: (rawCoord.y / 100.0) * screenshotHeight
                        )
                    } else {
                        resolvedPointCoordinate = rawCoord
                    }
                }
            }

            var finalPointLocation: CGPoint? = nil
            var finalDisplayFrame: CGRect? = nil

            if let axLocation = axGlobalLocation, let displayFrame = axDisplayFrame {
                finalPointLocation = axLocation
                finalDisplayFrame = displayFrame
            } else if let pointCoordinate = resolvedPointCoordinate, let target = targetScreenCapture {
                let screenshotWidth = CGFloat(target.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(target.screenshotHeightInPixels)
                let displayWidth = CGFloat(target.displayWidthInPoints)
                let displayHeight = CGFloat(target.displayHeightInPoints)
                let displayFrame = target.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY

                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                finalPointLocation = globalLocation
                finalDisplayFrame = displayFrame
            }

            if let pointLoc = finalPointLocation, let dispFrame = finalDisplayFrame {
                let isFinal = index == parseResult.targets.count - 1
                let totalChars = max(1, spokenText.count)
                let ratio = Double(tag.charIndex) / Double(totalChars)
                
                resolvedTargets.append(TriggerableTarget(
                    triggerTime: ratio,
                    screenLocation: pointLoc,
                    displayFrame: dispFrame,
                    label: tag.elementLabel ?? "element",
                    isFinal: isFinal
                ))
            }
        }

        conversationHistory.append((
            userTranscript: transcriptUsed,
            assistantResponse: spokenText
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        ClickyAnalytics.trackAIResponseReceived(response: spokenText)

        if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try await elevenLabsTTSClient.speakText(spokenText, voice: selectedVoice)
                voiceState = .responding
                
                let duration = elevenLabsTTSClient.duration
                let rate = Double(elevenLabsTTSClient.rate)
                
                var currentPos = NSEvent.mouseLocation
                var lastArrivalTime: TimeInterval = 0.0
                
                var activeTargetsQueue: [TriggerableTarget] = []
                for target in resolvedTargets {
                    let distance = hypot(target.screenLocation.x - currentPos.x, target.screenLocation.y - currentPos.y)
                    let flightDurationReal = min(max(distance / 800.0, 0.6), 1.4)
                    
                    let flightDurationNominal = flightDurationReal * rate
                    let arrivalBufferNominal = 1.0 * rate
                    
                    let spokenTimeNominal = target.triggerTime * duration
                    
                    let desiredArrivalTimeNominal = max(lastArrivalTime + 0.1, spokenTimeNominal - arrivalBufferNominal)
                    let desiredStartTimeNominal = max(lastArrivalTime, desiredArrivalTimeNominal - flightDurationNominal)
                    
                    let finalArrivalTimeNominal = desiredStartTimeNominal + flightDurationNominal
                    lastArrivalTime = finalArrivalTimeNominal
                    currentPos = target.screenLocation
                    
                    activeTargetsQueue.append(TriggerableTarget(
                        triggerTime: desiredStartTimeNominal,
                        screenLocation: target.screenLocation,
                        displayFrame: target.displayFrame,
                        label: target.label,
                        isFinal: target.isFinal
                    ))
                }

                playbackTimelineTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
                    guard let self = self else {
                        timer.invalidate()
                        return
                    }

                    guard self.elevenLabsTTSClient.isPlaying else {
                        timer.invalidate()
                        self.playbackTimelineTimer = nil
                        
                        // Wait 0.8 seconds after speech finishes, then clear target
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                            guard let self = self else { return }
                            if self.voiceState == .responding && !self.elevenLabsTTSClient.isPlaying {
                                self.currentPointingTarget = nil
                                if self.shouldWaitForClickAfterSpeech {
                                    self.startWaitingForClick()
                                } else {
                                    self.voiceState = .idle
                                    self.scheduleTransientHideIfNeeded()
                                }
                            }
                        }
                        return
                    }

                    let currentTime = self.elevenLabsTTSClient.currentTime

                    var remainingTargets: [TriggerableTarget] = []
                    for target in activeTargetsQueue {
                        if currentTime >= target.triggerTime {
                            let pointingTarget = PointingTarget(
                                id: UUID(),
                                screenLocation: target.screenLocation,
                                displayFrame: target.displayFrame,
                                label: target.label,
                                isFinal: target.isFinal
                            )
                            self.currentPointingTarget = pointingTarget
                            ClickyAnalytics.trackElementPointed(elementLabel: target.label)
                            print("🎯 Playback Timeline Triggered: Pointing at \"\(target.label)\" at \(currentTime)s (target offset \(target.triggerTime)s)")
                        } else {
                            remainingTargets.append(target)
                        }
                    }
                    activeTargetsQueue = remainingTargets
                }
            } catch {
                ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                print("⚠️ TTS error: \(error)")
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        } else {
            voiceState = .idle
            for target in resolvedTargets {
                let pointingTarget = PointingTarget(
                    id: UUID(),
                    screenLocation: target.screenLocation,
                    displayFrame: target.displayFrame,
                    label: target.label,
                    isFinal: target.isFinal
                )
                self.currentPointingTarget = pointingTarget
                ClickyAnalytics.trackElementPointed(elementLabel: target.label)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self.currentPointingTarget = nil
            if shouldWaitForClickAfterSpeech {
                startWaitingForClick()
            } else {
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Interactive Click-Waiting Tutorial Mode

    func startWaitingForClick() {
        guard !isWaitingForClick else { return }
        isWaitingForClick = true
        voiceState = .waitingForAction
        print("🖱️ Starting to wait for user click...")

        let clickHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            self.handleUserClickDetected()
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: clickHandler
        )
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            clickHandler(event)
            return event
        }
    }

    func stopWaitingForClick() {
        guard isWaitingForClick else { return }
        isWaitingForClick = false
        if voiceState == .waitingForAction {
            voiceState = .idle
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    private func handleUserClickDetected() {
        stopWaitingForClick()
        print("🖱️ User click detected! Preparing follow-up screenshot in 0.5s...")
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            sendFollowUpTurnAfterClick()
        }
    }

    private func sendFollowUpTurnAfterClick() {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let followUpPrompt = "I have clicked the item as instructed. Here is the updated screen. Please tell me the next step of the tutorial."

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: followUpPrompt,
                    onTextChunk: { _ in }
                )

                guard !Task.isCancelled else { return }

                await processVoiceResponse(
                    fullResponseText: fullResponseText,
                    transcriptUsed: followUpPrompt,
                    screenCaptures: screenCaptures
                )
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Follow-up response error: \(error)")
                let isRateLimit = error.localizedDescription.contains("429") || error.localizedDescription.contains("quota") || error.localizedDescription.contains("limit")
                let errorText = isRateLimit ? "Gemini rate limit reached." : "An error occurred."
                voiceState = .responding
                try? await elevenLabsTTSClient.speakText(errorText, voice: selectedVoice)
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }



    // MARK: - Point Tag Parsing

    struct ParsedPointingTag {
        let charIndex: Int
        let coordinate: CGPoint?
        let isPercentageCoordinate: Bool
        let elementLabel: String?
        let screenNumber: Int?
        let gridCell: (col: Int, row: Int)?
    }

    struct MultiPointingParseResult {
        let spokenText: String
        let targets: [ParsedPointingTag]
        let hasWaitForClick: Bool
    }

    /// Parses all [GRID:RowCol:label] tags, [POINT:X%,Y%:label] tags, [POINT:x,y:label] tags,
    /// and [WAIT_FOR_CLICK] from anywhere in responseText.
    /// Returns the fully cleaned spoken text, resolved target tags with character indices,
    /// and whether a wait tag was detected.
    static func parsePointingCoordinates(from responseText: String) -> MultiPointingParseResult {
        let hasWaitForClick = responseText.contains("[WAIT_FOR_CLICK]")

        let gridPattern = #"\.?\[GRID:(?:none|\s*([A-Za-z])(\d{1,2})\s*(?::\s*([^\]:]+?)\s*)?(?::screen\s*(\d+))?\s*)\]"#
        let percentPattern = #"\.?\[POINT:\s*(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%\s*(?::\s*([^\]:]+?)\s*)?(?::screen\s*(\d+))?\s*\]"#
        let pixelPattern = #"\.?\[POINT:(?:none|\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*(?::\s*([^\]:]+?)\s*)?(?::screen\s*(\d+))?\s*)\]"#
        let waitPattern = #"\[WAIT_FOR_CLICK\]"#

        enum PatternType {
            case grid
            case percent
            case pixel
            case wait
        }

        struct RawMatch {
            let range: Range<String.Index>
            let patternType: PatternType
            let regexMatch: NSTextCheckingResult
        }

        var rawMatches: [RawMatch] = []
        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        // Find grid matches
        if let regex = try? NSRegularExpression(pattern: gridPattern, options: []) {
            regex.enumerateMatches(in: responseText, options: [], range: fullRange) { match, _, _ in
                if let match = match, let range = Range(match.range, in: responseText) {
                    rawMatches.append(RawMatch(range: range, patternType: .grid, regexMatch: match))
                }
            }
        }

        // Find percent matches
        if let regex = try? NSRegularExpression(pattern: percentPattern, options: []) {
            regex.enumerateMatches(in: responseText, options: [], range: fullRange) { match, _, _ in
                if let match = match, let range = Range(match.range, in: responseText) {
                    rawMatches.append(RawMatch(range: range, patternType: .percent, regexMatch: match))
                }
            }
        }

        // Find pixel matches
        if let regex = try? NSRegularExpression(pattern: pixelPattern, options: []) {
            regex.enumerateMatches(in: responseText, options: [], range: fullRange) { match, _, _ in
                if let match = match, let range = Range(match.range, in: responseText) {
                    rawMatches.append(RawMatch(range: range, patternType: .pixel, regexMatch: match))
                }
            }
        }

        // Find wait matches
        if let regex = try? NSRegularExpression(pattern: waitPattern, options: []) {
            regex.enumerateMatches(in: responseText, options: [], range: fullRange) { match, _, _ in
                if let match = match, let range = Range(match.range, in: responseText) {
                    rawMatches.append(RawMatch(range: range, patternType: .wait, regexMatch: match))
                }
            }
        }

        // Sort matches by starting position
        let sortedMatches = rawMatches.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var cleanedText = ""
        var currentPos = responseText.startIndex
        var parsedTags: [ParsedPointingTag] = []

        func cleanSegment(_ segment: String) -> String {
            var cleaned = segment.replacingOccurrences(of: "\n", with: " ")
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
            cleaned = cleaned.replacingOccurrences(of: " .", with: ".")
            cleaned = cleaned.replacingOccurrences(of: " ,", with: ",")
            return cleaned
        }

        for rawMatch in sortedMatches {
            let segment = String(responseText[currentPos..<rawMatch.range.lowerBound])
            cleanedText.append(cleanSegment(segment))

            let charIndex = cleanedText.count
            currentPos = rawMatch.range.upperBound

            switch rawMatch.patternType {
            case .grid:
                let match = rawMatch.regexMatch
                guard match.numberOfRanges >= 3,
                      let letterRange = Range(match.range(at: 1), in: responseText),
                      let numberRange = Range(match.range(at: 2), in: responseText) else {
                    continue
                }

                let rowLetter = String(responseText[letterRange]).uppercased()
                let colNumberString = String(responseText[numberRange])
                let rowChar = rowLetter.first ?? "A"
                let rowIndex = max(0, min(Int(rowChar.asciiValue ?? 65) - 65, 10))
                let colIndex = max(0, min((Int(colNumberString) ?? 1) - 1, 17))

                var elementLabel: String? = nil
                if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
                    elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                }

                var screenNumber: Int? = nil
                if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }

                parsedTags.append(ParsedPointingTag(
                    charIndex: charIndex,
                    coordinate: nil,
                    isPercentageCoordinate: false,
                    elementLabel: elementLabel,
                    screenNumber: screenNumber,
                    gridCell: (col: colIndex, row: rowIndex)
                ))

            case .percent:
                let match = rawMatch.regexMatch
                guard match.numberOfRanges >= 3,
                      let xRange = Range(match.range(at: 1), in: responseText),
                      let yRange = Range(match.range(at: 2), in: responseText),
                      let xPercent = Double(responseText[xRange]),
                      let yPercent = Double(responseText[yRange]) else {
                    continue
                }

                let clampedX = max(0.0, min(xPercent, 100.0))
                let clampedY = max(0.0, min(yPercent, 100.0))

                var elementLabel: String? = nil
                if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
                    elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                }

                var screenNumber: Int? = nil
                if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }

                parsedTags.append(ParsedPointingTag(
                    charIndex: charIndex,
                    coordinate: CGPoint(x: clampedX, y: clampedY),
                    isPercentageCoordinate: true,
                    elementLabel: elementLabel,
                    screenNumber: screenNumber,
                    gridCell: nil
                ))

            case .pixel:
                let match = rawMatch.regexMatch
                guard match.numberOfRanges >= 3,
                      let xRange = Range(match.range(at: 1), in: responseText),
                      let yRange = Range(match.range(at: 2), in: responseText) else {
                    continue
                }

                let xPixel = Double(responseText[xRange]) ?? 0
                let yPixel = Double(responseText[yRange]) ?? 0

                var elementLabel: String? = nil
                if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
                    elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                }

                var screenNumber: Int? = nil
                if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }

                parsedTags.append(ParsedPointingTag(
                    charIndex: charIndex,
                    coordinate: CGPoint(x: xPixel, y: yPixel),
                    isPercentageCoordinate: false,
                    elementLabel: elementLabel,
                    screenNumber: screenNumber,
                    gridCell: nil
                ))

            case .wait:
                break
            }
        }

        let remainingSegment = String(responseText[currentPos...])
        cleanedText.append(cleanSegment(remainingSegment))

        cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)

        return MultiPointingParseResult(
            spokenText: cleanedText,
            targets: parsedTags,
            hasWaitForClick: hasWaitForClick
        )
    }

    // MARK: - Onboarding Video


    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're kivo click, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let firstTarget = parseResult.targets.first,
                      let pointCoordinate = firstTarget.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                let target = PointingTarget(
                    id: UUID(),
                    screenLocation: globalLocation,
                    displayFrame: displayFrame,
                    label: parseResult.spokenText,
                    isFinal: true
                )
                currentPointingTarget = target
                print("🎯 Onboarding demo: pointing at \"\(firstTarget.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
