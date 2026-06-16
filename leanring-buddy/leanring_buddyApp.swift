//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window.
//  The Dynamic Island panel (KivoDynamicIslandManager) is the sole UI
//  presence — it lives at the top-center of the screen and expands on hover,
//  replacing the old NSStatusItem + dropdown panel pattern entirely.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the Dynamic Island panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the Dynamic Island panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    /// The Dynamic Island floating panel — the app's sole visible UI element.
    private var dynamicIslandManager: KivoDynamicIslandManager?

    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Kivo Click: Starting…")
        print("🎯 Kivo Click: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        // Start the voice pipeline first, then create the island so the island's
        // CompanionManager references are already wired up when the view renders.
        companionManager.start()

        // Create the Dynamic Island panel — it appears immediately at top-center.
        // No showPanelOnLaunch call needed; the island is always visible.
        dynamicIslandManager = KivoDynamicIslandManager(companionManager: companionManager)

        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Kivo Click: Registered as login item")
            } catch {
                print("⚠️ Kivo Click: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Kivo Click: Sparkle updater failed to start: \(error)")
        }
    }
}
