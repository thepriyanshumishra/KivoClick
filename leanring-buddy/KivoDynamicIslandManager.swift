//
//  KivoDynamicIslandManager.swift
//  leanring-buddy
//
//  Dynamic Island panel controller.
//  Key animation fix: NSAnimationContext with spring-like bezier curve
//  for smooth NSPanel frame changes, decoupled from SwiftUI animation.
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
    // Collapsed: very thin pill, like iPhone Dynamic Island
    // Expanded: wide, shorter panel (Notch Nook proportions)
    static let collapsedWidth: CGFloat  = 160
    static let collapsedHeight: CGFloat = 28
    static let expandedWidth: CGFloat   = 580
    static let expandedHeight: CGFloat  = 252

    // MARK: - State
    let islandState = IslandState()
    private let companionManager: CompanionManager
    private var islandPanel: NSPanel?
    private var collapseDebounceTimer: Timer?

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

        // Level statusBar+2 (=27): puts us above the menu bar (level 24-25)
        // so cursor events reach our panel before the system intercepts them.
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
        hostingView.frame = NSRect(origin: .zero, size: collapsedFrame(on: screen).size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.islandManager = self

        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.islandPanel = panel
    }

    // MARK: - Expand / Collapse

    func expand() {
        collapseDebounceTimer?.invalidate()
        collapseDebounceTimer = nil
        guard !islandState.isExpanded else { return }

        let screen = NSScreen.main ?? NSScreen.screens[0]

        // 1. Animate NSPanel frame outward with a spring-like cubic bezier.
        //    controlPoints (0.34, 1.56, 0.64, 1.0) produces a slight overshoot
        //    that mimics a spring — the panel bounces gently at the end.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.46
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.38, 0.64, 1.0)
            self.islandPanel?.animator().setFrame(self.expandedFrame(on: screen), display: true)
        }

        // 2. SwiftUI content animates in with a matching spring (slight delay so
        //    the panel is already growing when content begins to appear).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            withAnimation(.spring(response: 0.44, dampingFraction: 0.70)) {
                self?.islandState.isExpanded = true
            }
        }
    }

    func collapse() {
        collapseDebounceTimer?.invalidate()
        // Debounce: ignore rapid exits that fire during panel resize
        collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.islandState.isExpanded else { return }
                if let panel = self.islandPanel, panel.frame.contains(NSEvent.mouseLocation) { return }

                let screen = NSScreen.main ?? NSScreen.screens[0]

                // 1. Fade SwiftUI content out first so the user sees the collapse start
                withAnimation(.easeIn(duration: 0.14)) {
                    self.islandState.isExpanded = false
                }

                // 2. After content has mostly disappeared, shrink the panel
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, !self.islandState.isExpanded else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.28
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                        self.islandPanel?.animator().setFrame(self.collapsedFrame(on: screen), display: true)
                    }
                }
            }
        }
    }

    // MARK: - Frame Calculations
    // Panel sits at the very top of the screen (in the menu bar/notch zone).
    // Level statusBar+2 ensures our panel is above the menu bar, so events reach us.
    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let x = sf.midX - Self.collapsedWidth / 2
        let y = sf.maxY - Self.collapsedHeight
        return NSRect(x: x, y: y, width: Self.collapsedWidth, height: Self.collapsedHeight)
    }

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

/// NSHostingView subclass that installs a .activeAlways NSTrackingArea
/// so hover events fire even when another app is frontmost.
/// AppKit calls updateTrackingAreas() automatically whenever view bounds change.
final class KivoDynamicIslandHostingView: NSHostingView<KivoDynamicIslandView> {

    weak var islandManager: KivoDynamicIslandManager?
    private var hoverArea: NSTrackingArea?

    required init(rootView: KivoDynamicIslandView) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverArea { removeTrackingArea(old); hoverArea = nil }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { islandManager?.expand() }
    override func mouseExited(with event: NSEvent)  { islandManager?.collapse() }
}
