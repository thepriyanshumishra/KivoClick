//
//  KivoDynamicIslandManager.swift
//  leanring-buddy
//
//  Manages the status-bar Dynamic Island panel.
//  It expands on hover (with a 0.8s delay) or on click (instantly),
//  and collapses when the mouse leaves.
//
//  KEY BEHAVIOURS:
//    • Sized dynamically: Collapsed pill at top-center, expanding downward
//      into the detail panel (or even further down for settings).
//    • Sits on the primary screen at the top-center.
//    • Fully rounded corner styling.
//

import AppKit
import Combine
import SwiftUI

// MARK: - IslandState

enum SettingsSubScreen: Equatable {
    case main
    case voice
    case shortcuts
}

final class IslandState: ObservableObject {
    @Published var isExpanded: Bool = false
    @Published var isShowingSettings: Bool = false
    @Published var isUndocked: Bool = false
    @Published var selectedTab: IslandTab = .home
    @Published var currentSettingsScreen: SettingsSubScreen = .main
}

// MARK: - KivoDynamicIslandManager

@MainActor
final class KivoDynamicIslandManager: NSObject {

    // MARK: - Sizes
    static let collapsedWidth: CGFloat  = 200
    static let collapsedHeight: CGFloat = 24
    static let expandedWidth: CGFloat   = 560
    static let expandedHeight: CGFloat  = 270
    static let settingsHeight: CGFloat  = 480

    // MARK: - State
    let islandState = IslandState()
    private let companionManager: CompanionManager
    private var islandPanel: NSPanel?

    // Prevents simultaneous expand/collapse calls from fighting each other
    private var isTransitioning: Bool = false

    // Task-based delays (using structured concurrency)
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private let expandDelay: UInt64 = 100_000_000 // 100ms in nanoseconds
    private let collapseDelay: UInt64 = 250_000_000 // 250ms in nanoseconds

    // MARK: - Init
    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createIslandPanel()

        // Observe collapse request notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCollapseNotification),
            name: .kivoIslandShouldCollapse,
            object: nil
        )

        // Observe settings state changed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsStateNotification(_:)),
            name: .kivoIslandSettingsStateDidChange,
            object: nil
        )

        // Observe dock state changed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDockStateNotification(_:)),
            name: .kivoIslandDockStateDidChange,
            object: nil
        )

        // Observe dynamic height update notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHeightUpdateNotification),
            name: .kivoIslandHeightShouldUpdate,
            object: nil
        )

        // Observe request expand notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRequestExpandNotification(_:)),
            name: .kivoIslandRequestExpand,
            object: nil
        )

        // Observe config change from UserDefaults
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDefaultsChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        // Run once initially to apply settings
        handleUserDefaultsChange()
    }

    @objc @MainActor private func handleRequestExpandNotification(_ notification: Notification) {
        islandState.selectedTab = .home
        islandState.isShowingSettings = false
        
        cancelPendingCollapse()
        expand()
    }

    @objc @MainActor private func handleCollapseNotification() {
        collapse()
    }

    private func targetHeightForCurrentState(isExpanding: Bool = false) -> CGFloat {
        if !islandState.isExpanded && !isExpanding {
            return Self.collapsedHeight
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
            let isTTSReady = KokoroTTSModelManager.shared.isModelReady
            let isSTTReady = SherpaOnnxModelManager.shared.isModelReady
            let isCheckingSTT = SherpaOnnxModelManager.shared.isCheckingCache

            if (isTTSReady && isSTTReady) || isCheckingSTT {
                return 215
            } else {
                return 275
            }
        case .agents:
            if AgentManager.shared.activeTasks.isEmpty {
                return 155
            } else {
                return Self.expandedHeight
            }
        }
    }

    @objc @MainActor private func handleHeightUpdateNotification() {
        guard islandState.isExpanded, !isTransitioning else { return }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let targetHeight = targetHeightForCurrentState()
        let newFrame = resizeFrame(height: targetHeight, on: screen)

        isTransitioning = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.islandPanel?.animator().setFrame(newFrame, display: true)
        } completionHandler: {
            Task { @MainActor [weak self] in
                self?.isTransitioning = false
            }
        }
    }

    @objc @MainActor private func handleSettingsStateNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let isShowing = userInfo["isShowing"] as? Bool else { return }

        // Update state
        islandState.isShowingSettings = isShowing
        islandState.currentSettingsScreen = .main

        // If not expanded, expand now (this shouldn't happen, but just in case)
        if !islandState.isExpanded {
            expand()
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let targetHeight = targetHeightForCurrentState()
        let newFrame = resizeFrame(height: targetHeight, on: screen)

        isTransitioning = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.islandPanel?.animator().setFrame(newFrame, display: true)
        } completionHandler: {
            Task { @MainActor [weak self] in
                self?.isTransitioning = false
            }
        }
    }

    @objc @MainActor private func handleDockStateNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let isUndocked = userInfo["isUndocked"] as? Bool else { return }

        islandState.isUndocked = isUndocked
        islandPanel?.isMovableByWindowBackground = isUndocked

        if !isUndocked {
            // Animate back to top-center of screen
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let targetHeight = targetHeightForCurrentState()
            let dockedFrame = resizeFrame(height: targetHeight, on: screen)

            isTransitioning = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                self.islandPanel?.animator().setFrame(dockedFrame, display: true)
            } completionHandler: {
                Task { @MainActor [weak self] in
                    self?.isTransitioning = false
                }
            }
        }
    }

    @objc @MainActor private func handleUserDefaultsChange() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        let showInScreenRecordings = UserDefaults.standard.object(forKey: "showInScreenRecordings") as? Bool ?? true

        // Update Dock Activation Policy
        let currentPolicy = NSApp.activationPolicy()
        let targetPolicy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        if currentPolicy != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }

        // Update Window Sharing Type
        let targetSharingType: NSWindow.SharingType = showInScreenRecordings ? .readWrite : .readOnly
        if islandPanel?.sharingType != targetSharingType {
            islandPanel?.sharingType = targetSharingType
        }
    }

    // MARK: - Panel Setup

    private func createIslandPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]

        let panel = KeyableIslandPanel(
            contentRect: collapsedFrame(on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let rootView = KivoDynamicIslandView(
            companionManager: companionManager,
            islandState: islandState
        )

        let hostingView = KivoDynamicIslandHostingView(rootView: rootView)
        // Use settingsHeight (the maximum possible height) for the hosting view.
        // The window acts as a clipping viewport, preventing resizing/rendering loops.
        hostingView.frame = NSRect(origin: .zero, size: CGSize(width: Self.expandedWidth, height: Self.settingsHeight))
        hostingView.autoresizingMask = []
        hostingView.islandManager = self

        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.islandPanel = panel

        // Start at collapsed frame
        panel.setFrame(collapsedFrame(on: screen), display: false)
    }

    // MARK: - Hover / Click Actions

    func startHoverExpand() {
        collapseTask?.cancel()
        collapseTask = nil

        guard !islandState.isExpanded, !isTransitioning else { return }

        expandTask?.cancel()
        expandTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: expandDelay)
                guard !Task.isCancelled else { return }
                self.expand()
            } catch {}
        }
    }

    func startHoverCollapse() {
        expandTask?.cancel()
        expandTask = nil

        guard islandState.isExpanded, !isTransitioning, !islandState.isUndocked else { return }

        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: collapseDelay)
                guard !Task.isCancelled else { return }
                self.collapse()
            } catch {}
        }
    }

    func cancelPendingCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    func expandImmediately() {
        expandTask?.cancel()
        expandTask = nil
        expand()
    }

    // MARK: - Expand

    func expand() {
        guard !islandState.isExpanded, !isTransitioning else { return }

        collapseTask?.cancel()
        collapseTask = nil

        let screen = NSScreen.main ?? NSScreen.screens[0]
        isTransitioning = true

        let targetHeight = self.targetHeightForCurrentState(isExpanding: true)
        let targetFrame = self.resizeFrame(height: targetHeight, on: screen)

        // Single-stage fluid expansion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            self.islandPanel?.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isTransitioning = false
            }
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            self.islandState.isExpanded = true
        }
    }

    // MARK: - Collapse

    func collapse() {
        guard islandState.isExpanded, !isTransitioning else { return }

        collapseTask?.cancel()
        collapseTask = nil

        let screen = NSScreen.main ?? NSScreen.screens[0]
        isTransitioning = true

        // Reset settings and dock state on collapse
        self.islandState.isShowingSettings = false
        self.islandState.isUndocked = false
        self.islandPanel?.isMovableByWindowBackground = false

        // Step 1: Fade out SwiftUI content immediately
        withAnimation(.easeOut(duration: 0.12)) {
            self.islandState.isExpanded = false
        }

        // Step 2: Shrink the window after content has faded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.islandState.isExpanded else {
                    self?.isTransitioning = false
                    return
                }
                let screen = NSScreen.main ?? NSScreen.screens[0]
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.30
                    // Smooth deceleration curve for collapse
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
                    self.islandPanel?.animator().setFrame(self.collapsedFrame(on: screen), display: true)
                } completionHandler: {
                    Task { @MainActor [weak self] in
                        self?.isTransitioning = false
                    }
                }
            }
        }
    }

    // MARK: - Frame Calculations

    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let x = sf.midX - Self.collapsedWidth / 2
        let y = sf.maxY - Self.collapsedHeight
        return NSRect(x: x, y: y, width: Self.collapsedWidth, height: Self.collapsedHeight)
    }

    private func resizeFrame(height: CGFloat, on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let x = sf.midX - Self.expandedWidth / 2
        let y = sf.maxY - height
        return NSRect(x: x, y: y, width: Self.expandedWidth, height: height)
    }
}

// MARK: - KeyableIslandPanel

private final class KeyableIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - KivoDynamicIslandHostingView

final class KivoDynamicIslandHostingView: NSHostingView<KivoDynamicIslandView> {

    weak var islandManager: KivoDynamicIslandManager?
    private var hoverArea: NSTrackingArea?

    required init(rootView: KivoDynamicIslandView) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installStaticTrackingArea()
    }

    private func installStaticTrackingArea() {
        if let old = hoverArea {
            removeTrackingArea(old)
            hoverArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        islandManager?.startHoverExpand()
    }

    override func mouseExited(with event: NSEvent) {
        islandManager?.startHoverCollapse()
    }

    override func mouseDown(with event: NSEvent) {
        if let manager = islandManager, !manager.islandState.isExpanded {
            // Cancel hover delay timer and expand immediately on click
            manager.expandImmediately()
        } else {
            super.mouseDown(with: event)
        }
    }
}
