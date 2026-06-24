import Foundation
import ApplicationServices
import Cocoa

func searchElementTree(
    _ element: AXUIElement,
    query: String,
    currentDepth: Int,
    maxDepth: Int,
    visitedCount: inout Int,
    maxVisited: Int,
    appName: String
) {
    if visitedCount >= maxVisited { return }
    visitedCount += 1
    
    let attrs = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
    for attr in attrs {
        var val: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &val)
        if err == .success, let str = val as? String {
            let cleanStr = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanStr.localizedCaseInsensitiveContains(query) {
                var posVal: AnyObject?
                var sizeVal: AnyObject?
                let hasPos = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success
                let hasSize = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success
                
                var point = CGPoint.zero
                var size = CGSize.zero
                if hasPos, posVal != nil {
                    AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
                }
                if hasSize, sizeVal != nil {
                    AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
                }
                
                var roleVal: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
                let role = (roleVal as? String) ?? "unknown"
                
                if role == "AXApplication" {
                    continue
                }
                
                if size.width > 1.0 && size.height > 1.0 {
                    print("Match in [\(appName)] Role: \(role), Attribute '\(attr)': '\(cleanStr)'")
                    print("  Pos: \(point), Size: \(size)")
                }
            }
        }
    }
    
    if currentDepth >= maxDepth { return }
    
    var childrenVal: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal)
    guard err == .success, let children = childrenVal as? [AXUIElement] else {
        return
    }
    
    for child in children {
        searchElementTree(child, query: query, currentDepth: currentDepth + 1, maxDepth: maxDepth, visitedCount: &visitedCount, maxVisited: maxVisited, appName: appName)
    }
}

func runDiagnostic() {
    print("Searching all running apps for 'App Store'...")
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    for app in apps {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var visited = 0
        searchElementTree(appRef, query: "App Store", currentDepth: 0, maxDepth: 6, visitedCount: &visited, maxVisited: 1000, appName: app.localizedName ?? "unknown")
    }

    if let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) {
        let dockRef = AXUIElementCreateApplication(dockApp.processIdentifier)
        var visited = 0
        searchElementTree(dockRef, query: "App Store", currentDepth: 0, maxDepth: 6, visitedCount: &visited, maxVisited: 1000, appName: "Dock")
    }
}

// NOTE: To run this diagnostic file, uncomment the call below and execute in terminal:
// swift test_ax.swift
//
// Keep it commented out during normal Xcode builds so it compiles cleanly.
// runDiagnostic()
