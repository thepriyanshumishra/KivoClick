//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  DEPRECATED — the menu bar status item and dropdown panel have been
//  replaced by KivoDynamicIslandManager, which shows a permanently-visible
//  Dynamic Island at the top-centre of the screen.
//
//  This file is kept as a stub so that the Xcode target continues to
//  compile without needing a project.pbxproj edit. It defines an empty
//  class that is never instantiated.
//

import AppKit

// Notification name kept for source compatibility with any retained callers.
extension Notification.Name {
    static let kivoClickDismissPanel = Notification.Name("kivoClickDismissPanel")
}

/// Stub — no longer active. All UI is handled by KivoDynamicIslandManager.
@MainActor
final class MenuBarPanelManager: NSObject {
    init(companionManager: CompanionManager) {
        super.init()
    }
}
