//
//  KivoDynamicIslandView.swift
//  leanring-buddy
//
//  Kivo Click Dynamic Island — completely rebuilt.
//
//  COLLAPSED (ultra-thin pill, 200×24pt, top-center of screen):
//    • Idle        → "Kivo Click" text + subtle dot
//    • Listening   → "Listening…"  + violet mini-waveform
//    • Processing  → "Thinking…"   + amber spinning arc
//    • Responding  → "Speaking"    + orange waveform (exactly like reference image 5)
//
//  EXPANDED (drops down, 560×230pt, flat top):
//    • Tab bar: [Home] [Agents]  +  [⚙] [✕] on right
//    • Home tab: shortcut hint · cursor color picker · model/voice pickers · permissions
//    • Agents tab: active task cards / empty state placeholder
//

import AppKit
import AVFoundation
import SwiftUI

// Selected tab in the expanded panel
enum IslandTab: String, CaseIterable {
    case home   = "Home"
    case agents = "Agents"
}


// MARK: - VisualEffectBackground

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - NotchShape (flat top, rounded bottom corners only)
// The top edge is intentionally square — it appears physically glued to the
// top of the screen. Only the bottom-left and bottom-right corners are rounded.
private struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))          // top-left (square)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))       // top-right (square)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))   // right side
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))   // bottom
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - DynamicIslandShape (interpolates between collapsed capsule and flat-top expanded notch)
private struct DynamicIslandShape: Shape {
    var expansionProgress: CGFloat // 0.0 = collapsed capsule, 1.0 = expanded notch

    var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Interpolate corner radii
        let topRadius = (1.0 - expansionProgress) * (rect.height / 2.0)
        let bottomRadius = (1.0 - expansionProgress) * (rect.height / 2.0) + expansionProgress * 16.0

        // Bottom side bulges down during transition to look like a droplet
        let bulge = sin(expansionProgress * .pi) * 10.0
        let bottomY = rect.maxY + bulge

        var path = Path()
        // Top-left starting point
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        // Top-right
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        if topRadius > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius),
                radius: topRadius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        // Bottom-right
        path.addLine(to: CGPoint(x: rect.maxX, y: bottomY - bottomRadius))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRadius, y: bottomY - bottomRadius),
            radius: bottomRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        // Bottom-left
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: bottomY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomRadius, y: bottomY - bottomRadius),
            radius: bottomRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        // Top-left closing
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        if topRadius > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                radius: topRadius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}


// MARK: - Model Definition

private struct AIModel {
    let id: String
    let displayName: String
    let subtitle: String
}

// MARK: - Voice Definition

private enum VoiceProvider { case gemini, orpheus }

private struct AIVoice {
    let id: String
    let displayName: String
    let gender: String   // "M" or "F"
    let provider: VoiceProvider
}

// MARK: - Cursor Color Option

private struct CursorColorOption: Identifiable {
    let id: String
    let color: Color
    let label: String
}

// MARK: - KivoDynamicIslandView

struct KivoDynamicIslandView: View {

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var islandState: IslandState
    @ObservedObject private var modelManager = SherpaOnnxModelManager.shared
    @ObservedObject private var kokoroModelManager = KokoroTTSModelManager.shared
    private var agentManager = AgentManager.shared

    init(companionManager: CompanionManager, islandState: IslandState) {
        self.companionManager = companionManager
        self.islandState = islandState
    }

    // Animation driver states
    @State private var breathingScale: CGFloat = 1.0
    @State private var spinAngle: Double = 0
    @State private var wavePhase: Double = 0

    @State private var selectedVoiceTemp: String = "Aoede"
    @State private var playingSampleVoice: String? = nil
    @State private var hoveredColorOptionId: String? = nil
    @State private var expandedTaskIds: Set<UUID> = []
    @AppStorage("kivoVoiceSpeed") private var voiceSpeed: Double = 1.0



    // Cursor color: persisted in UserDefaults key "kivoCursorColorId"
    @AppStorage("kivoCursorColorId") private var selectedCursorColorId: String = "blue"


    // ── Model catalogue ───────────────────────────────────────────────────────
    // Row 1 (direct models): Gemini 2.5 → Balanced, Gemini 3.5 → Smartest
    // Row 2 (hybrid):        Llama 4 → Most Capable
    private static let geminiModels: [AIModel] = [
        AIModel(id: "gemini-2.5-flash-preview-05-20", displayName: "Gemini 2.5", subtitle: "Balanced"),
        AIModel(id: "gemini-3.5-flash",               displayName: "Gemini 3.5", subtitle: "Smartest"),
    ]
    private static let hybridModels: [AIModel] = [
        AIModel(id: "llama-3.3-70b-versatile",        displayName: "Llama 4",    subtitle: "Most Capable"),
    ]

    // ── Voice catalogue ───────────────────────────────────────────────────────
    private static let geminiVoices: [AIVoice] = [
        AIVoice(id: "Aoede",   displayName: "Aoede",  gender: "F", provider: .gemini),
        AIVoice(id: "Puck",    displayName: "Puck",   gender: "M", provider: .gemini),
    ]
    private static let orpheusVoices: [AIVoice] = [
        AIVoice(id: "Hannah",  displayName: "Hannah", gender: "F", provider: .orpheus),
        AIVoice(id: "Daniel",  displayName: "Daniel", gender: "M", provider: .orpheus),
    ]

    // ── Cursor color palette (matches the 4 colored pointers in reference image 3) ─
    private static let cursorColorOptions: [CursorColorOption] = [
        CursorColorOption(id: "red",    color: Color(hex: "#EF4444"), label: "Red"),
        CursorColorOption(id: "blue",   color: Color(hex: "#3B82F6"), label: "Blue"),
        CursorColorOption(id: "yellow", color: Color(hex: "#EAB308"), label: "Yellow"),
        CursorColorOption(id: "green",  color: Color(hex: "#22C55E"), label: "Green"),
    ]

    private var activeCursorColor: Color {
        Self.cursorColorOptions.first(where: { $0.id == selectedCursorColorId })?.color ?? Color(hex: "#3B82F6")
    }

    private var allPermissionsGranted: Bool {
        companionManager.hasMicrophonePermission
            && companionManager.hasAccessibilityPermission
            && companionManager.hasScreenRecordingPermission
    }

    // MARK: - Body

    private var currentHeight: CGFloat {
        if !islandState.isExpanded {
            return KivoDynamicIslandManager.collapsedHeight
        }
        if islandState.isShowingSettings {
            switch islandState.currentSettingsScreen {
            case .main:
                return 400
            case .voice:
                return 280
            case .shortcuts:
                return 320
            }
        }
        switch islandState.selectedTab {
        case .home:
            let isTTSReady = kokoroModelManager.isModelReady
            let isSTTReady = modelManager.isModelReady
            let isCheckingSTT = modelManager.isCheckingCache
            if (isTTSReady && isSTTReady) || isCheckingSTT {
                return 215
            } else {
                return 275
            }
        case .agents:
            return agentManager.activeTasks.isEmpty ? 155 : KivoDynamicIslandManager.expandedHeight
        }
    }

    var body: some View {
        GeometryReader { geo in
            let currentWidth = geo.size.width
            let collapsedW = KivoDynamicIslandManager.collapsedWidth
            let expandedW = KivoDynamicIslandManager.expandedWidth
            
            let progress = (currentWidth - collapsedW) / (expandedW - collapsedW)
            let clampedProgress = max(0.0, min(1.0, progress))
            
            ZStack(alignment: .top) {
                if companionManager.voiceState != .idle || clampedProgress > 0.01 {
                    // Morphing background shape
                    DynamicIslandShape(expansionProgress: clampedProgress)
                        .fill(Color(hex: "#0C0C0F").opacity(0.92))
                        .background(
                            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                                .clipShape(DynamicIslandShape(expansionProgress: clampedProgress))
                        )
                        .overlay(
                            DynamicIslandShape(expansionProgress: clampedProgress)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.10),
                                            Color.white.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: activeCursorColor.opacity(0.16), radius: 24, x: 0, y: 8)
                        .shadow(color: .black.opacity(0.70), radius: 28, x: 0, y: 16)
                }
                
                contentLayer
            }
        }
        .onAppear(perform: startAnimations)
        .onChange(of: islandState.isExpanded) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: islandState.isShowingSettings) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: islandState.selectedTab) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: agentManager.activeTasks.count) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: islandState.currentSettingsScreen) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: kokoroModelManager.isModelReady) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: modelManager.isModelReady) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: kokoroModelManager.downloadProgress) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: modelManager.downloadProgress) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
        .onChange(of: modelManager.isCheckingCache) { oldValue, newValue in
            NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
        }
    }

    // MARK: - Content Layer (cross-fades between collapsed and expanded)

    @ViewBuilder
    private var contentLayer: some View {
        if islandState.isExpanded {
            expandedPanel
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: -6))
                            .animation(.spring(response: 0.30, dampingFraction: 0.84).delay(0.06)),
                        removal: .opacity
                            .animation(.easeOut(duration: 0.12))
                    )
                )
        } else {
            collapsedPill
                .transition(
                    .asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.16)),
                        removal:   .opacity.animation(.easeOut(duration: 0.08))
                    )
                )
        }
    }

    // MARK: ─────────────── COLLAPSED PILL ───────────────────────────────────
    // Matches Image 5 exactly: thin bar with status text on left,
    // compact waveform/indicator on right. No icon circles, no heavy chrome.

    private var collapsedPill: some View {
        Group {
            if companionManager.voiceState == .idle {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(hex: "#0C0C0F").opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .frame(width: 80, height: 4)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(
                    width:  KivoDynamicIslandManager.collapsedWidth,
                    height: KivoDynamicIslandManager.collapsedHeight
                )
            } else {
                ZStack {
                    VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            activeCursorColor.opacity(0.60),
                                            activeCursorColor.opacity(0.10)
                                        ],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: activeCursorColor.opacity(0.25), radius: 6, x: 0, y: 0)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)

                    HStack(spacing: 8) {
                        switch companionManager.voiceState {
                        case .listening:
                            AudioWaveView(level: companionManager.currentAudioPowerLevel)
                                .frame(width: 50, height: 20)
                            Text("Listening…")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        case .processing:
                            SpinningArcView()
                                .frame(width: 18, height: 18)
                            Text("Thinking…")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        case .responding:
                            BreathingDotView()
                                .frame(width: 16, height: 16)
                            Text("Speaking")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        case .waitingForAction:
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.yellow)
                            Text("Waiting…")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(
                    width:  KivoDynamicIslandManager.collapsedWidth,
                    height: KivoDynamicIslandManager.collapsedHeight
                )
            }
        }
    }

    // MARK: ─────────────── EXPANDED PANEL ───────────────────────────────────

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            if islandState.isShowingSettings {
                settingsHeader
                thinDivider
                settingsContent
            } else {
                expandedTabBar
                thinDivider

                // Tab content area — switches between Home and Agents
                Group {
                    if islandState.selectedTab == .home {
                        homeTab
                    } else {
                        agentsTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                thinDivider
                expandedFooter
            }
        }
        .frame(
            width:  KivoDynamicIslandManager.expandedWidth,
            height: currentHeight
        )
    }

    // MARK: Tab Bar (top of expanded panel)
    // Layout: [Home] [Agents]    …spacer…    [⚙] [✕]
    // Matches the tab bar style from reference images 2, 3, 4.

    private var expandedTabBar: some View {
        HStack(spacing: 0) {
            // Tab buttons
            HStack(spacing: 4) {
                ForEach(IslandTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.leading, 14)

            Spacer()

            // Right controls: settings gear + close button
            HStack(spacing: 8) {
                // Settings gear
                Button {
                    KivoSoundFeedback.playOrbTap()
                    NotificationCenter.default.post(
                        name: .kivoIslandSettingsStateDidChange,
                        object: nil,
                        userInfo: ["isShowing": true]
                    )
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(islandState.isShowingSettings ? Color(red: 0.45, green: 0.65, blue: 1.0) : .white.opacity(0.40))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.04))
                        )
                }
                .buttonStyle(.plain).pointerCursor().help("Settings")

                // Close / collapse the panel
                Button {
                    NotificationCenter.default.post(name: .kivoIslandShouldCollapse, object: nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.04))
                        )
                }
                .buttonStyle(.plain).pointerCursor().help("Close")
            }
            .padding(.trailing, 14)
        }
        .frame(height: 38)
    }

    private func tabButton(_ tab: IslandTab) -> some View {
        let isSelected = islandState.selectedTab == tab && !islandState.isShowingSettings
        let icon: String = {
            switch tab {
            case .home: return "waveform"
            case .agents: return "cpu"
            }
        }()
        return Button {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.82)) {
                islandState.selectedTab = tab
                islandState.isShowingSettings = false
            }
            KivoSoundFeedback.playTabSwitch()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(
                isSelected
                    ? Color(red: 0.45, green: 0.65, blue: 1.0)
                    : Color.white.opacity(0.4)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.12))
                    : nil
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func headerIconButton(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.32))
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            )
    }

    // MARK: ─────────────── HOME TAB ────────────────────────────────────────
    // Matches reference image 2:
    //   1. Shortcut hint row
    //   2. "Cursor color:" label + 4 color swatches
    //   3. Model picker + Voice picker (two columns)

    private var homeTab: some View {
        VStack(spacing: 0) {
            // ── Shortcut hint ───────────────────────────────────────────────
            shortcutHintRow
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            thinDivider.padding(.horizontal, 16)

            // ── Cursor color picker ─────────────────────────────────────────
            cursorColorRow
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            thinDivider.padding(.horizontal, 16)

            speechModelsStatusSection

            Spacer()

            // ── Footer row with Undock button ───────────────────────────────
            HStack {
                Spacer()
                Button {
                    KivoSoundFeedback.playOrbTap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        islandState.isUndocked.toggle()
                        NotificationCenter.default.post(
                            name: .kivoIslandDockStateDidChange,
                            object: nil,
                            userInfo: ["isUndocked": islandState.isUndocked]
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: islandState.isUndocked ? "macpro.gen3.server" : "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(islandState.isUndocked ? "Dock" : "Undock")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.60))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var speechModelsStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let isTTSReady = kokoroModelManager.isModelReady
            let isSTTReady = modelManager.isModelReady
            let isCheckingSTT = modelManager.isCheckingCache
            let isDownloadingTTS = kokoroModelManager.downloadProgress != nil
            let isDownloadingSTT = modelManager.downloadProgress != nil

            if (isTTSReady && isSTTReady) || isCheckingSTT {
                EmptyView()
            } else if isDownloadingTTS || isDownloadingSTT {
                VStack(alignment: .leading, spacing: 6) {
                    if isDownloadingTTS, let progress = kokoroModelManager.downloadProgress {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "Downloading text-to-speech model... %.0f%%", progress * 100))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.70))
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(DS.Colors.accent)
                        }
                    } else if !isTTSReady {
                        Text("Preparing text-to-speech model...")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.40))
                    }

                    if isDownloadingSTT, let progress = modelManager.downloadProgress {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "Downloading speech-to-text model... %.0f%%", progress * 100))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.70))
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(DS.Colors.accent)
                        }
                    } else if !isSTTReady {
                        Text("Preparing speech-to-text model...")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.40))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Local speech models are missing.")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        KivoSoundFeedback.playOrbTap()
                        // Parallel download start:
                        kokoroModelManager.downloadModelIfNeeded()
                        Task {
                            await modelManager.downloadModelIfNeeded()
                        }
                    } label: {
                        Text("Download Speech Models")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(DS.Colors.accent)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            if let error = kokoroModelManager.downloadError {
                Text(error)
                    .font(.system(size: 8.5))
                    .foregroundColor(.red.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
            if let error = modelManager.downloadError {
                Text(error)
                    .font(.system(size: 8.5))
                    .foregroundColor(.red.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }

    // Shortcut hint row — "Hold ⌃ control + ⌥ option to talk."
    // Also shows the current voice state when active.
    private var shortcutHintRow: some View {
        HStack(spacing: 8) {
            // Live status accent dot
            Circle()
                .fill(accentColor)
                .frame(width: 5, height: 5)
                .scaleEffect(breathingScale)

            if companionManager.voiceState == .idle {
                // Idle: show the keyboard shortcut hint
                HStack(spacing: 3) {
                    Text("Hold")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                    HoverableKeyCapView(key: "⌃")
                    Text("control")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                    Text("+")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                    HoverableKeyCapView(key: "⌥")
                    Text("option to talk.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.45))
                }
            } else {
                // Active: show animated status text
                Text(statusDescription)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accentColor)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: statusDescription)

                // Live waveform or spinner next to status
                shortcutHintActiveIndicator
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var shortcutHintActiveIndicator: some View {
        switch companionManager.voiceState {
        case .listening:
            MiniWaveform(level: companionManager.currentAudioPowerLevel, phase: wavePhase, color: accentColor)
                .frame(width: 28, height: 10)
        case .processing, .waitingForAction:
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(spinAngle))
        default:
            EmptyView()
        }
    }

    // Pointer color row — matches reference image 3:
    // "Pointer color:" label + 4 pointer buttons (Red, Blue, Yellow, Green)
    private var cursorColorRow: some View {
        HStack(spacing: 16) {
            Text("Pointer color")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.38))

            HStack(spacing: 14) {
                ForEach(Self.cursorColorOptions) { colorOption in
                    cursorColorPointer(colorOption: colorOption)
                }
            }

            Spacer()
        }
    }

    private func cursorColorPointer(colorOption: CursorColorOption) -> some View {
        let isSelected = selectedCursorColorId == colorOption.id
        let isHovered = hoveredColorOptionId == colorOption.id

        return Button {
            KivoSoundFeedback.playOrbTap()
            withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) {
                selectedCursorColorId = colorOption.id
                // Notify CompanionManager so the cursor overlay updates immediately
                companionManager.setCursorOverlayColor(colorOption.color)
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Triangle()
                        .fill(colorOption.color)
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(-35.0))
                        .shadow(
                            color: colorOption.color.opacity(isHovered ? 0.60 : 0.35),
                            radius: isHovered ? 8 : (isSelected ? 4 : 0)
                        )
                        .scaleEffect(isSelected ? 1.2 : (isHovered ? 1.15 : 1.0))
                    
                    if isHovered || isSelected {
                        Circle()
                            .stroke(colorOption.color.opacity(isHovered ? 0.40 : 0.20), lineWidth: 1.5)
                            .scaleEffect(isHovered ? 1.4 : 1.2)
                            .frame(width: 20, height: 20)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isHovered)
                    }
                }
                
                // Subtle indicator line below the active cursor color
                RoundedRectangle(cornerRadius: 1)
                    .fill(colorOption.color)
                    .frame(width: 12, height: isSelected ? 2 : 0)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(width: 28, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(colorOption.label)
        .onHover { hovering in
            withAnimation(.spring(response: 0.20, dampingFraction: 0.75)) {
                if hovering {
                    hoveredColorOptionId = colorOption.id
                } else if hoveredColorOptionId == colorOption.id {
                    hoveredColorOptionId = nil
                }
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: selectedCursorColorId)
    }

    // MARK: Model Picker Column

    private var modelPickerColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            pickerRowHeader("Gemini")
            HStack(spacing: 4) {
                ForEach(Self.geminiModels, id: \.id) { model in
                    modelChip(model: model, isOn: companionManager.selectedModel == model.id) {
                        companionManager.setSelectedModel(model.id)
                    }
                }
            }

            pickerRowHeader("Hybrid")
            HStack(spacing: 4) {
                ForEach(Self.hybridModels, id: \.id) { model in
                    modelChip(model: model, isOn: companionManager.selectedModel == model.id) {
                        companionManager.setSelectedModel(model.id)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func pickerRowHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.20))
            .tracking(0.8)
    }

    private func modelChip(model: AIModel, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(model.displayName)
                    .font(.system(size: 10.5, weight: isOn ? .semibold : .medium))
                    .foregroundColor(isOn ? .white : .white.opacity(0.48))
                Text("·")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.16))
                Text(model.subtitle)
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(isOn ? accentColor.opacity(0.80) : .white.opacity(0.20))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(chipBackground(isOn: isOn))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isOn)
    }

    // MARK: Voice Picker Column

    private var voicePickerColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            pickerRowHeader("Gemini Voices")
            HStack(spacing: 4) {
                ForEach(Self.geminiVoices, id: \.id) { voice in
                    voiceChip(voice: voice, isOn: companionManager.selectedVoice == voice.id) {
                        companionManager.setSelectedVoice(voice.id)
                    }
                }
            }

            pickerRowHeader("Orpheus Voices")
            HStack(spacing: 4) {
                ForEach(Self.orpheusVoices, id: \.id) { voice in
                    voiceChip(voice: voice, isOn: companionManager.selectedVoice == voice.id) {
                        companionManager.setSelectedVoice(voice.id)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func voiceChip(voice: AIVoice, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(voice.displayName)
                    .font(.system(size: 10.5, weight: isOn ? .semibold : .medium))
                    .foregroundColor(isOn ? .white : .white.opacity(0.48))
                Text(voice.gender)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(isOn ? accentColor.opacity(0.85) : .white.opacity(0.20))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(isOn ? accentColor.opacity(0.18) : Color.white.opacity(0.05))
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(chipBackground(isOn: isOn))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isOn)
    }

    // Shared chip background
    @ViewBuilder
    private func chipBackground(isOn: Bool) -> some View {
        if isOn {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.accent.opacity(0.30), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        }
    }

    // MARK: ─────────────── AGENTS TAB ──────────────────────────────────────
    // Matches reference image 3: shows task cards when agents are active,
    // or a clean empty state when no tasks are running.

    private var agentsTab: some View {
        VStack(spacing: 0) {
            // Header: label + debug "+" button
            HStack {
                Text("ACTIVE TASKS")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.20))
                    .tracking(0.8)

                Spacer()

                Button {
                    let newTask = agentManager.addDemoTask()
                    if let firstSubtask = newTask.subtasks.first {
                        agentManager.updateSubtask(
                            agentId: newTask.id,
                            subtaskId: firstSubtask.id,
                            newStatus: .inProgress
                        )
                    }
                    KivoSoundFeedback.playAgentStarted()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.40))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.06))
                                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Add demo agent task")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if agentManager.activeTasks.isEmpty {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .frame(width: 34, height: 34)
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.white.opacity(0.16))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No active background tasks")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                        Text("Tap + to demo, or say \u{201c}Create a React app\u{201d}")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.18))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(agentManager.activeTasks) { task in
                            AgentMiniCard(
                                task: task,
                                isExpanded: expandedTaskIds.contains(task.id),
                                onToggle: {
                                    if expandedTaskIds.contains(task.id) {
                                        expandedTaskIds.remove(task.id)
                                    } else {
                                        expandedTaskIds.insert(task.id)
                                    }
                                    NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: agentManager.activeTasks.map { $0.id })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    // MARK: ─────────────── FOOTER ──────────────────────────────────────────
    // Minimized footer: just the whisper/model download indicator (if needed)
    // and the quit button. Settings moved to tab bar header.

    private var expandedFooter: some View {
        HStack(spacing: 10) {
            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                footerIconButton(systemName: "power")
            }
            .buttonStyle(.plain).pointerCursor().help("Quit Kivo Click")
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func footerIconButton(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.30))
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(Color.white.opacity(0.048))
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            )
    }


    // MARK: - Whisper Download Indicator

    private var whisperIndicator: some View {
        Group {
            if let progress = modelManager.downloadProgress {
                HStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(DS.Colors.accent)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.linear(duration: 0.15), value: progress)
                        }
                    }
                    .frame(width: 38, height: 3)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8.5)).foregroundColor(.white.opacity(0.28))
                }
            } else {
                Button {
                    Task { await SherpaOnnxModelManager.shared.downloadModelIfNeeded() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: modelManager.downloadError != nil ? "arrow.clockwise" : "arrow.down.circle")
                            .font(.system(size: 8.5))
                        Text(modelManager.downloadError != nil ? "Retry" : "Get AI")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.accentText)
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
    }

    // MARK: - Kokoro Download Indicator

    private var kokoroIndicator: some View {
        Group {
            if let progress = kokoroModelManager.downloadProgress {
                HStack(spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(Color.blue)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.linear(duration: 0.15), value: progress)
                        }
                    }
                    .frame(width: 38, height: 3)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8.5)).foregroundColor(.white.opacity(0.28))
                }
            } else {
                Button {
                    kokoroModelManager.downloadModelIfNeeded()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: kokoroModelManager.downloadError != nil ? "arrow.clockwise" : "waveform.circle")
                            .font(.system(size: 8.5))
                        Text(kokoroModelManager.downloadError != nil ? "Retry Voice" : "Get Voice")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(Color.blue.opacity(0.85))
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
    }

    // MARK: - Shared Dividers

    private var thinDivider: some View {
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
    }

    private var thinVerticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 0.5)
            .padding(.vertical, 8)
    }

    // MARK: - Inline Settings View components

    private var settingsHeaderIconName: String {
        switch islandState.currentSettingsScreen {
        case .main:
            return "gearshape.fill"
        case .voice:
            return "waveform"
        case .shortcuts:
            return "keyboard"
        }
    }

    private var settingsHeaderTitleText: String {
        switch islandState.currentSettingsScreen {
        case .main:
            return "Settings"
        case .voice:
            return "Voices"
        case .shortcuts:
            return "Shortcuts"
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 0) {
            Button {
                KivoSoundFeedback.playOrbTap()
                if islandState.currentSettingsScreen == .main {
                    // Notify the manager to shrink back to expandedHeight
                    NotificationCenter.default.post(
                        name: .kivoIslandSettingsStateDidChange,
                        object: nil,
                        userInfo: ["isShowing": false]
                    )
                } else {
                    // Stop any playing voice preview sample when going back
                    companionManager.stopVoiceSample()
                    playingSampleVoice = nil
                    // Go back to main settings screen with slide transition
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        islandState.currentSettingsScreen = .main
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Back")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.60))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.leading, 14)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: settingsHeaderIconName)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.accent)
                Text(settingsHeaderTitleText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.90))
            }

            Spacer()

            // Invisible placeholder of the same size to balance the title in the center
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                Text("Back")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .opacity(0)
            .padding(.trailing, 14)
        }
        .frame(height: 44)
    }

    private var settingsContent: some View {
        ZStack {
            switch islandState.currentSettingsScreen {
            case .main:
                mainSettingsView
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            case .voice:
                voiceSettingsView
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
            case .shortcuts:
                shortcutsSettingsView
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: islandState.currentSettingsScreen)
    }

    private var mainSettingsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // 1. Connections Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONNECTIONS")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.30))
                        .tracking(0.8)
                    
                    settingsButtonRow(icon: "square.grid.2x2", title: "Integrations", badge: "Coming soon") {
                        // Action for integrations
                    }
                }

                // 2. Customization Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("CUSTOMIZATION")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.30))
                        .tracking(0.8)

                    VStack(spacing: 0) {
                        settingsButtonRow(icon: "keyboard", title: "Shortcuts") {
                            KivoSoundFeedback.playOrbTap()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                islandState.currentSettingsScreen = .shortcuts
                            }
                        }
                        
                        thinDivider
                        
                        // Model Picker Row
                        settingsPickerRow(icon: "cpu", title: "AI Model", selection: companionManager.selectedModel, options: [
                            "gemini-2.5-flash-preview-05-20": "Gemini 2.5",
                            "gemini-3.5-flash": "Gemini 3.5",
                            "llama-3.3-70b-versatile": "Llama 4"
                        ]) { newModel in
                            companionManager.setSelectedModel(newModel)
                        }

                        thinDivider

                        // Voice Row
                        settingsButtonRow(icon: "waveform", title: "Voice") {
                            KivoSoundFeedback.playOrbTap()
                            selectedVoiceTemp = companionManager.selectedVoice
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                islandState.currentSettingsScreen = .voice
                            }
                        }

                        thinDivider


                        // Microphone Picker Row
                        settingsMicrophoneRow()

                        thinDivider

                        // Agent Folder Row
                        settingsFolderRow()

                        thinDivider

                        settingsButtonRow(icon: "checkmark.shield", title: "Agent Permissions") {
                            // Action for permissions
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
                }

                // 3. Preferences/Toggles Section
                VStack(spacing: 0) {
                    settingsToggleRow(title: "Show in Dock", description: "Turn off to keep Kivo Click notch only.", key: "showInDock")
                    thinDivider
                    settingsToggleRow(title: "Show in screen recordings", description: "Let screen sharing and recording tools capture Kivo Click.", key: "showInScreenRecordings", defaultValue: true)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private struct VoiceOption: Identifiable {
        let id: String
        let label: String
    }

    private var voiceSettingsView: some View {
        VStack(spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    let voices = [
                        VoiceOption(id: "Aoede", label: "Aoede (Female)"),
                        VoiceOption(id: "Puck", label: "Puck (Male)"),
                        VoiceOption(id: "Hannah", label: "Hannah (Female)"),
                        VoiceOption(id: "Daniel", label: "Daniel (Male)")
                    ]
                    
                    ForEach(voices) { voice in
                        HStack(spacing: 12) {
                            // Select indicator
                            Button {
                                KivoSoundFeedback.playOrbTap()
                                selectedVoiceTemp = voice.id
                            } label: {
                                Image(systemName: selectedVoiceTemp == voice.id ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(selectedVoiceTemp == voice.id ? DS.Colors.accent : .white.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()

                            Text(voice.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))

                            Spacer()

                            // Play Button & Miniature Wave visualizer
                            HStack(spacing: 8) {
                                if playingSampleVoice == voice.id && companionManager.isPlaying {
                                    MiniWaveVisualizer(isAnimating: true, color: DS.Colors.accent)
                                }
                                
                                Button {
                                    KivoSoundFeedback.playOrbTap()
                                    if playingSampleVoice == voice.id && companionManager.isPlaying {
                                        companionManager.stopVoiceSample()
                                        playingSampleVoice = nil
                                    } else {
                                        playingSampleVoice = voice.id
                                        companionManager.playVoiceSample(for: voice.id)
                                    }
                                } label: {
                                    Image(systemName: (playingSampleVoice == voice.id && companionManager.isPlaying) ? "stop.fill" : "play.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.8))
                                        .frame(width: 24, height: 24)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedVoiceTemp == voice.id ? Color.white.opacity(0.06) : Color.clear)
                        )
                    }
                    
                    // Voice Speed Slider Row
                    VStack(alignment: .leading, spacing: 6) {
                        Text("VOICE SPEED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.30))
                            .tracking(0.8)
                            .padding(.top, 8)
                        
                        TactileSlider(value: $voiceSpeed, range: 0.5...2.0)
                            .frame(height: 52)
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }

            Spacer(minLength: 0)

            // Save button
            Button {
                KivoSoundFeedback.playOrbTap()
                companionManager.stopVoiceSample()
                playingSampleVoice = nil
                companionManager.setSelectedVoice(selectedVoiceTemp)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    islandState.currentSettingsScreen = .main
                }
            } label: {
                Text("Save")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "#4361EE"), Color(hex: "#3F37C9")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(8)
                    .shadow(color: Color(hex: "#4361EE").opacity(0.3), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }


    private var shortcutsSettingsView: some View {
        VStack(spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    let shortcutOptions = [
                        (BuddyPushToTalkShortcut.ShortcutOption.controlOption, "Control + Option (Default)"),
                        (BuddyPushToTalkShortcut.ShortcutOption.shiftFunction, "Shift + Fn"),
                        (BuddyPushToTalkShortcut.ShortcutOption.shiftControl, "Shift + Control"),
                        (BuddyPushToTalkShortcut.ShortcutOption.controlOptionSpace, "Control + Option + Space"),
                        (BuddyPushToTalkShortcut.ShortcutOption.shiftControlSpace, "Shift + Control + Space")
                    ]

                    ForEach(shortcutOptions, id: \.0) { option, label in
                        Button {
                            KivoSoundFeedback.playOrbTap()
                            BuddyPushToTalkShortcut.currentShortcutOption = option
                            // Force redraw of view
                            self.selectedVoiceTemp = self.selectedVoiceTemp
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: BuddyPushToTalkShortcut.currentShortcutOption == option ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(BuddyPushToTalkShortcut.currentShortcutOption == option ? DS.Colors.accent : .white.opacity(0.3))

                                Text(label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(BuddyPushToTalkShortcut.currentShortcutOption == option ? Color.white.opacity(0.06) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
    }



    private func settingsButtonRow(icon: String, title: String, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.accent)
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                        )
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func settingsPickerRow(icon: String, title: String, selection: String, options: [String: String], action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 20, height: 20)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            
            Menu {
                ForEach(options.keys.sorted(), id: \.self) { key in
                    Button(options[key] ?? key) {
                        action(key)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(options[selection] ?? selection)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.50))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.30))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
    }

    private func settingsMicrophoneRow() -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 20, height: 20)
            Text("Microphone")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            
            Menu {
                Button("System Default") {
                    UserDefaults.standard.set("System Default", forKey: "selectedMicrophone")
                }
                Button("Built-in Microphone") {
                    UserDefaults.standard.set("Built-in Microphone", forKey: "selectedMicrophone")
                }
                Button("External Microphone") {
                    UserDefaults.standard.set("External Microphone", forKey: "selectedMicrophone")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(UserDefaults.standard.string(forKey: "selectedMicrophone") ?? "External Microphone")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.50))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.30))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
    }

    private func settingsFolderRow() -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 20, height: 20)
            Text("Agent Folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            
            Button {
                KivoSoundFeedback.playOrbTap()
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.title = "Select Agent Workspace Folder"
                if panel.runModal() == .OK, let url = panel.url {
                    UserDefaults.standard.set(url.path, forKey: "agentFolderPath")
                }
            } label: {
                HStack(spacing: 4) {
                    let path = UserDefaults.standard.string(forKey: "agentFolderPath") ?? "Kivo Click default"
                    let folderName = path == "Kivo Click default" ? "Kivo Click default" : (path as NSString).lastPathComponent
                    Text(folderName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.50))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.30))
                }
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
    }

    private func settingsToggleRow(title: String, description: String, key: String, defaultValue: Bool = false) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Text(description)
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.35))
            }
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: key)
                    // Trigger didChange notification immediately
                    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                }
            ))
            .toggleStyle(.switch)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Animation Drivers

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breathingScale = 1.10
        }
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
            spinAngle = 360
        }
        withAnimation(.linear(duration: 0.88).repeatForever(autoreverses: false)) {
            wavePhase = 1.0
        }
    }

    // MARK: - State Helpers

    private var collapsedLabel: String {
        switch companionManager.voiceState {
        case .idle:             return "Kivo Click"
        case .listening:        return "Listening…"
        case .processing:       return "Thinking…"
        case .responding:       return "Speaking"
        case .waitingForAction: return "Your turn…"
        }
    }

    private var statusDescription: String {
        switch companionManager.voiceState {
        case .idle:             return allPermissionsGranted ? "Ready" : "Permissions needed"
        case .listening:        return "Listening…"
        case .processing:       return "Thinking…"
        case .responding:       return "Speaking…"
        case .waitingForAction: return "Waiting for action"
        }
    }

    // Premium accent palette — no generic greens for status
    private var accentColor: Color {
        switch companionManager.voiceState {
        case .idle:             return DS.Colors.accent         // Kivo blue
        case .listening:        return Color(hex: "#A78BFA")    // Violet 400
        case .processing:       return Color(hex: "#FBBF24")    // Amber 400
        case .responding:       return Color(hex: "#F97316")    // Orange 400 (matches image 5)
        case .waitingForAction: return Color(hex: "#FBBF24")    // Amber 400
        }
    }

    // Pill glow is only visible when actively doing something (listening/speaking)
    private var pillGlowOpacity: Double {
        switch companionManager.voiceState {
        case .idle:      return 0.0   // No glow at idle — completely invisible
        case .listening: return 0.45
        case .responding: return 0.40
        default:         return 0.25
        }
    }

    private var pillGlowRadius: CGFloat {
        switch companionManager.voiceState {
        case .idle:      return 0
        case .listening: return 14
        default:         return 10
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let kivoIslandShouldCollapse  = Notification.Name("kivoIslandShouldCollapse")
    static let kivoCursorColorDidChange  = Notification.Name("kivoCursorColorDidChange")
    static let kivoIslandSettingsStateDidChange = Notification.Name("kivoIslandSettingsStateDidChange")
    static let kivoIslandDockStateDidChange = Notification.Name("kivoIslandDockStateDidChange")
    static let kivoIslandConfigDidChange = Notification.Name("kivoIslandConfigDidChange")
    static let kivoIslandHeightShouldUpdate = Notification.Name("kivoIslandHeightShouldUpdate")
    static let kivoClickDismissPanel = Notification.Name("kivoClickDismissPanel")
    static let kivoIslandRequestExpand = Notification.Name("kivoIslandRequestExpand")
}

// MARK: - AgentMiniCard

/// Compact task card shown inside the Dynamic Island's Agents tab.
/// Shows the agent color, title, status badge, a compact progress bar,
/// and the first few subtask rows. Tapping "View" opens the full detail card.
// MARK: - AgentMiniCard

private struct AgentMiniCard: View {
    var task: AgentTask
    var isExpanded: Bool
    var onToggle: () -> Void

    @State private var borderGlowProgress: CGFloat = 0.0
    @State private var isFlashingBorder: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header Row (Clicking toggles expansion)
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(task.color)
                        .frame(width: 3, height: 20)
                        .shadow(color: task.color.opacity(0.50), radius: 3)

                    Text(task.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 3) {
                        if task.overallStatus == .running {
                            Circle()
                                .fill(task.statusBadgeColor)
                                .frame(width: 4, height: 4)
                        }
                        Text(task.statusBadgeText)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(task.statusBadgeColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(task.statusBadgeColor.opacity(0.14)))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.30))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(spacing: 6) {
                    // Subtasks Checklist
                    if !task.subtasks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(task.subtasks) { subtask in
                                HStack(spacing: 6) {
                                    Image(systemName: subtask.status == .done ? "checkmark.circle.fill" : (subtask.status == .inProgress ? "ellipsis.circle.fill" : "circle"))
                                        .font(.system(size: 10))
                                        .foregroundColor(subtask.status == .done ? Color(hex: "#22C55E") : (subtask.status == .inProgress ? Color(hex: "#FBBF24") : .white.opacity(0.20)))

                                    Text(subtask.title)
                                        .font(.system(size: 10, weight: subtask.status == .done ? .regular : .medium))
                                        .foregroundColor(subtask.status == .done ? .white.opacity(0.35) : .white.opacity(0.72))
                                        .strikethrough(subtask.status == .done, color: .white.opacity(0.25))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                            }
                        }
                    }

                    // Progress bar
                    if !task.subtasks.isEmpty {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.06))
                                Capsule()
                                    .fill(task.color.opacity(0.70))
                                    .frame(width: geo.size.width * CGFloat(task.completionFraction))
                                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: task.completionFraction)
                            }
                        }
                        .frame(height: 2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }

                    // Actions Row
                    HStack(spacing: 8) {
                        Spacer()
                        // Dismiss button
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                AgentManager.shared.removeTask(id: task.id)
                                KivoSoundFeedback.playOrbTap()
                                NotificationCenter.default.post(name: .kivoIslandHeightShouldUpdate, object: nil)
                            }
                        } label: {
                            Text("Dismiss")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.30))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Collapsed card progress bar
                if !task.subtasks.isEmpty {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                            Capsule()
                                .fill(task.color.opacity(0.70))
                                .frame(width: geo.size.width * CGFloat(task.completionFraction))
                        }
                    }
                    .frame(height: 1.5)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: "#0C0C0F").opacity(0.40))
                .background(
                    VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isFlashingBorder
                                ? AnyShapeStyle(
                                    AngularGradient(
                                        colors: [task.color, .white, task.color.opacity(0.2), task.color],
                                        center: .center,
                                        angle: .degrees(Double(borderGlowProgress * 360))
                                    )
                                  )
                                : AnyShapeStyle(task.color.opacity(0.18)),
                            lineWidth: isFlashingBorder ? 1.5 : 0.6
                        )
                )
        )
        .onChange(of: task.overallStatus) { oldValue, newValue in
            if newValue != oldValue {
                isFlashingBorder = true
                borderGlowProgress = 0.0
                withAnimation(.linear(duration: 1.0)) {
                    borderGlowProgress = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    isFlashingBorder = false
                }
            }
        }
    }
}


// MARK: - MiniWaveform


private struct MiniWaveform: View {
    let level: CGFloat
    let phase: Double
    let color: Color
    private let bars = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(color)
                    .frame(width: 2.2, height: barH(i))
            }
        }
    }

    private func barH(_ i: Int) -> CGFloat {
        let base: CGFloat = 2
        let maxH: CGFloat = 9
        let p = max(0.10, level)
        let wave = CGFloat(sin(Double(i) * 1.2 + phase * .pi * 2) * 0.5 + 0.5)
        return base + (maxH - base) * p * wave
    }
}

// MARK: - Claude Micro-Animations

struct AudioWaveView: View {
    let level: CGFloat
    private let barCount = 7

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                WaveBar(index: i, level: level, total: barCount)
            }
        }
    }
}

private struct WaveBar: View {
    let index: Int
    let level: CGFloat
    let total: Int
    @State private var phase: Double = .random(in: 0...(2 * .pi))

    private var midMultiplier: CGFloat {
        let mid = Double(total - 1) / 2.0
        let dist = abs(Double(index) - mid) / mid
        return CGFloat(1.0 - dist * 0.45)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.45, green: 0.65, blue: 1.0),
                        Color(red: 0.6, green: 0.45, blue: 1.0)
                    ],
                    startPoint: .bottom, endPoint: .top
                )
            )
            .frame(width: 3, height: barHeight)
            .animation(
                .easeInOut(duration: 0.35 + Double(index) * 0.04).repeatForever(autoreverses: true),
                value: barHeight
            )
            .onAppear { phase = Double(index) * 0.7 }
    }

    private var barHeight: CGFloat {
        let minH: CGFloat = 3
        let maxH: CGFloat = 18
        let driven = minH + (maxH - minH) * level * midMultiplier
        return max(minH, driven)
    }
}

struct SpinningArcView: View {
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.65)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color(red: 0.5, green: 0.45, blue: 1.0),
                            Color(red: 0.35, green: 0.65, blue: 1.0),
                            .clear
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(angle))
                .animation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: angle
                )
        }
        .onAppear { angle = 360 }
    }
}

struct BreathingDotView: View {
    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0.5

    var body: some View {
        Circle()
            .fill(Color(red: 0.3, green: 0.9, blue: 0.65))
            .scaleEffect(scale)
            .opacity(opacity)
            .animation(
                .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: scale
            )
            .onAppear {
                scale   = 1.0
                opacity = 1.0
            }
    }
}

// MARK: - HoverableKeyCapView

private struct HoverableKeyCapView: View {
    let key: String
    @State private var isHovered = false

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(isHovered ? 0.24 : 0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.26), radius: 1.5, x: 0, y: 1)
            )
            .scaleEffect(isHovered ? 1.08 : 1.0)
            .onHover { hovering in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - TrianglePointer

private struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Draw a custom triangle pointer pointing up-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.width * 0.52, y: rect.height * 0.65))
        path.addLine(to: CGPoint(x: rect.width * 0.32, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.16, y: rect.maxY * 0.94))
        path.addLine(to: CGPoint(x: rect.width * 0.36, y: rect.height * 0.58))
        path.closeSubpath()
        return path
    }
}

// MARK: - MiniWaveVisualizer

private struct MiniWaveVisualizer: View {
    let isAnimating: Bool
    let color: Color

    @State private var waveHeight1: CGFloat = 4
    @State private var waveHeight2: CGFloat = 6
    @State private var waveHeight3: CGFloat = 5
    @State private var waveHeight4: CGFloat = 7

    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1).fill(color)
                .frame(width: 1.5, height: isAnimating ? waveHeight1 : 3)
            RoundedRectangle(cornerRadius: 1).fill(color)
                .frame(width: 1.5, height: isAnimating ? waveHeight2 : 3)
            RoundedRectangle(cornerRadius: 1).fill(color)
                .frame(width: 1.5, height: isAnimating ? waveHeight3 : 3)
            RoundedRectangle(cornerRadius: 1).fill(color)
                .frame(width: 1.5, height: isAnimating ? waveHeight4 : 3)
        }
        .frame(height: 12)
        .onAppear {
            if isAnimating {
                startAnimation()
            }
        }
        .onChange(of: isAnimating) { oldValue, newValue in
            if newValue {
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
            waveHeight1 = 12
            waveHeight2 = 4
            waveHeight3 = 10
            waveHeight4 = 5
        }
    }
}

// MARK: - TactileSlider

private struct TactileSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    @State private var isDragging: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbSize: CGFloat = 14
            let pct = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let clampedPct = max(0.0, min(1.0, pct))
            let thumbX = clampedPct * (width - thumbSize)

            VStack(spacing: 0) {
                // Tooltip Bubble
                ZStack {
                    if isDragging || isHovered {
                        VStack(spacing: 2) {
                            Text(String(format: "%.1fx", value))
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color(hex: "#3B82F6"))
                                        .shadow(color: Color(hex: "#3B82F6").opacity(0.3), radius: 4)
                                )
                            // Tiny triangle point down
                            Image(systemName: "triangle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(Color(hex: "#3B82F6"))
                                .rotationEffect(.degrees(180))
                                .offset(y: -3)
                        }
                        .transition(.opacity.combined(with: .scale))
                        .offset(x: thumbX - (width / 2) + (thumbSize / 2), y: -6)
                    }
                }
                .frame(height: 22)
                .animation(.spring(response: 0.20, dampingFraction: 0.75), value: isDragging || isHovered)

                // Slider Track
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color(hex: "#3B82F6"))
                        .frame(width: thumbX + thumbSize / 2, height: 4)

                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: thumbX)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    isDragging = true
                                    let locationX = gesture.location.x
                                    let relativeX = max(0, min(width - thumbSize, locationX - thumbSize / 2))
                                    let newPct = Double(relativeX / (width - thumbSize))
                                    value = range.lowerBound + newPct * (range.upperBound - range.lowerBound)
                                }
                                .onEnded { _ in
                                    isDragging = false
                                }
                        )
                }
                .contentShape(Rectangle())
                .onHover { hover in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                        isHovered = hover
                    }
                }
            }
        }
    }
}
