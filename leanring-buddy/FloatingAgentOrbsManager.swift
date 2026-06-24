//
//  FloatingAgentOrbsManager.swift
//  leanring-buddy
//
//  Manages the always-on-top NSPanel that shows the agent orb stack in
//  the top-right corner of the primary display.
//
//  KEY BEHAVIOURS:
//    • The panel is non-activating — clicking an orb never steals focus
//      from whatever the user was doing.
//    • It joins all Spaces and Exposé groups so the orbs are always visible
//      no matter what the user switches to.
//    • The panel auto-shows when the first agent is added and auto-hides
//      when all agents are removed (no empty ghost panel cluttering the screen).
//    • The panel auto-resizes vertically as tasks are added / removed.
//    • Positioned 8pt from the right edge and 8pt below the macOS menu bar.
//

import AppKit
import Combine
import Observation
import SwiftUI

@MainActor
final class FloatingAgentOrbsManager {

    // MARK: - Constants

    /// Width of the panel — wide enough for a truncated task name + status badge.
    private static let panelWidth: CGFloat = 256

    /// Height of each orb row pill (including vertical padding between orbs).
    private static let orbRowHeight: CGFloat = 36

    /// Vertical padding inside the panel (top + bottom).
    private static let panelVerticalPadding: CGFloat = 12

    /// Gap between the panel right edge and the screen right edge.
    private static let rightMargin: CGFloat = 10

    /// Gap between the panel top and the macOS menu bar bottom.
    private static let topMargin: CGFloat = 8

    // MARK: - State

    private let agentManager: AgentManager
    private var orbsPanel: NSPanel?

    // MARK: - Init

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        createOrbsPanel()
        observeAgentChanges()
    }

    // MARK: - Panel Setup

    private func createOrbsPanel() {
        let initialFrame = computePanelFrame(taskCount: 0)

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Float above normal windows but below the system status bar / Spotlight
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true

        // Join all Spaces + stay put during Mission Control so orbs are always visible
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        // Content: the SwiftUI orb stack
        let rootView = FloatingAgentOrbsView(agentManager: agentManager)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        // Hidden until the first agent is added
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        self.orbsPanel = panel
    }

    private func observeAgentChanges() {
        // Set the initial state
        handleTaskCountChanged(taskCount: agentManager.activeTasks.count)
        
        // Start recursive observation tracking
        trackAgentChanges()
    }

    private func trackAgentChanges() {
        withObservationTracking {
            _ = agentManager.activeTasks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleTaskCountChanged(taskCount: self.agentManager.activeTasks.count)
                self.trackAgentChanges()
            }
        }
    }


    private func handleTaskCountChanged(taskCount: Int) {
        if taskCount == 0 {
            // No active agents — fade out the panel so it doesn't clutter the desktop
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                orbsPanel?.animator().alphaValue = 0
            }
        } else {
            // Resize to fit the new task count, then fade in if it was hidden
            let newFrame = computePanelFrame(taskCount: taskCount)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                orbsPanel?.animator().setFrame(newFrame, display: true)
                orbsPanel?.animator().alphaValue = 1.0
            }
        }
    }

    // MARK: - Frame Calculation

    /// Computes the panel frame anchored to the top-right corner of the primary screen.
    /// The height grows linearly with the number of tasks (each row is ~36pt tall)
    /// plus a fixed top+bottom padding.
    private func computePanelFrame(taskCount: Int) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        let menuBarHeight: CGFloat = NSApplication.shared.mainMenu?.menuBarHeight ?? 24

        // Total panel height = padding + (rows × rowHeight) + padding
        let panelHeight: CGFloat = taskCount == 0
            ? 0
            : (Self.panelVerticalPadding
               + CGFloat(taskCount) * Self.orbRowHeight
               + CGFloat(max(0, taskCount - 1)) * 6  // 6pt spacing between orbs
               + Self.panelVerticalPadding)

        let panelWidth = Self.panelWidth

        let x = screenFrame.maxX - panelWidth - Self.rightMargin
        // In AppKit coords, Y=0 is the bottom of the screen.
        // Top of panel = screenFrame.maxY - menuBarHeight - topMargin - panelHeight
        let y = screenFrame.maxY - menuBarHeight - Self.topMargin - panelHeight

        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }
}
