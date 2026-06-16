//
//  KivoDynamicIslandManager.swift
//  leanring-buddy
//
//  Dynamic Island panel controller.
//
//  KEY FIX — Hover Loop Prevention:
//  The tracking area covers only the COLLAPSED pill region when collapsed.
//  When the panel EXPANDS, the window grows downward, but we do NOT call
//  updateTrackingAreas again during the resize, avoiding the
//  mouseEntered→expand→resize→mouseExited→collapse→resize→mouseEntered loop.
//
//  HOW IT WORKS:
//    1. The hosting view has a FIXED tracking rect equal to the FULL expanded
//       frame from the start (maxSize). This never changes — no loop.
//    2. expand() / collapse() guard with `isTransitioning` so they cannot
//       fire simultaneously.
//    3. collapse() debounces with 0.15s and also verifies mouse is actually
//       outside before proceeding.
//

import AppKit
import Combine
import SwiftUI

// MARK: - IslandState

final class IslandState: ObservableObject {
    @Published var isExpanded: Bool = false
}

// MARK: - KivoDynamicIslandManager

@MainActor
final class KivoDynamicIslandManager: NSObject {

    // MARK: - Sizes
    static let collapsedWidth: CGFloat  = 160
    static let collapsedHeight: CGFloat = 30
    static let expandedWidth: CGFloat   = 600
    static let expandedHeight: CGFloat  = 152

    // MARK: - State
    let islandState = IslandState()
    private let companionManager: CompanionManager
    private var islandPanel: NSPanel?

    // Prevents simultaneous expand/collapse calls from fighting each other
    // (the root cause of the resize → tracking area → loop bug).
    private var isTransitioning: Bool = false
    private var collapseWorkItem: DispatchWorkItem?

    // MARK: - Init
    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createIslandPanel()
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
        // The hosting view is sized to the MAXIMUM (expanded) dimensions from the start.
        // The window acts as a clipping viewport. This prevents tracking area
        // reinstallation on resize which causes the expand/collapse loop.
        hostingView.frame = NSRect(origin: .zero, size: CGSize(width: Self.expandedWidth, height: Self.expandedHeight))
        // Never auto-resize: the viewport (window) resizes, not the content.
        hostingView.autoresizingMask = []
        hostingView.islandManager = self

        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.islandPanel = panel

        // Start at collapsed frame (the viewport is narrow/short initially).
        panel.setFrame(collapsedFrame(on: screen), display: false)
    }

    // MARK: - Expand

    func expand() {
        // Bail if already expanded or mid-transition
        guard !islandState.isExpanded, !isTransitioning else { return }

        // Cancel any pending collapse
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        let screen = NSScreen.main ?? NSScreen.screens[0]
        isTransitioning = true

        // Step 1: Immediately widen the window (the clip viewport) so the
        // expanded content can render without SwiftUI clipping it.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.42
            // A slightly spring-like ease-out cubic
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.islandPanel?.animator().setFrame(self.expandedFrame(on: screen), display: true)
        } completionHandler: {
            Task { @MainActor [weak self] in
                self?.isTransitioning = false
            }
        }

        // Step 2: Trigger SwiftUI content swap with a short delay so the
        // window is already growing before the content cross-fades in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            withAnimation(.smooth(duration: 0.30)) {
                self?.islandState.isExpanded = true
            }
        }
    }

    // MARK: - Collapse

    func collapse() {
        guard islandState.isExpanded, !isTransitioning else { return }

        collapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.islandState.isExpanded, !self.isTransitioning else { return }

                // Safety: verify mouse is actually outside the expanded panel
                if let panel = self.islandPanel,
                   panel.frame.contains(NSEvent.mouseLocation) { return }

                let screen = NSScreen.main ?? NSScreen.screens[0]
                self.isTransitioning = true

                // Step 1: Fade out SwiftUI content immediately
                withAnimation(.easeOut(duration: 0.18)) {
                    self.islandState.isExpanded = false
                }

                // Step 2: Shrink the window after content has faded
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self, !self.islandState.isExpanded else {
                        self?.isTransitioning = false
                        return
                    }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.28
                        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
                        self.islandPanel?.animator().setFrame(self.collapsedFrame(on: screen), display: true)
                    } completionHandler: {
                        Task { @MainActor [weak self] in
                            self?.isTransitioning = false
                        }
                    }
                }
            }
        }
        collapseWorkItem = workItem
        // 0.15s debounce before collapsing — ignores transient mouseExit events
        // that fire during the expand resize itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    // MARK: - Frame Calculations

    /// The collapsed pill sits at the top of the screen, horizontally centered.
    /// Its y-anchor is the top of the screen (screen.maxY in AppKit coords).
    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let x = sf.midX - Self.collapsedWidth / 2
        let y = sf.maxY - Self.collapsedHeight
        return NSRect(x: x, y: y, width: Self.collapsedWidth, height: Self.collapsedHeight)
    }

    /// The expanded panel grows downward from the same top anchor.
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let x = sf.midX - Self.expandedWidth / 2
        let y = sf.maxY - Self.expandedHeight
        return NSRect(x: x, y: y, width: Self.expandedWidth, height: Self.expandedHeight)
    }
}

// MARK: - KeyableIslandPanel

private final class KeyableIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - KivoDynamicIslandHostingView

/// NSHostingView subclass with a STATIC tracking area.
/// The key insight: the tracking area is installed ONCE on the full expanded
/// rect and never reinstalled during window resizes. This prevents the
/// mouseEntered/mouseExited loop that occurs when tracking areas are
/// reinstalled on every bounds change during a size animation.
final class KivoDynamicIslandHostingView: NSHostingView<KivoDynamicIslandView> {

    weak var islandManager: KivoDynamicIslandManager?
    private var hoverArea: NSTrackingArea?

    required init(rootView: KivoDynamicIslandView) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installStaticTrackingArea()
    }

    /// Installs a single tracking area covering the full hosting view bounds.
    /// Called only once (when the view first attaches to the window).
    /// We deliberately do NOT override updateTrackingAreas() to prevent
    /// reinstallation during frame animations.
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

    override func mouseEntered(with event: NSEvent) { islandManager?.expand() }
    override func mouseExited(with event: NSEvent)  { islandManager?.collapse() }
}
