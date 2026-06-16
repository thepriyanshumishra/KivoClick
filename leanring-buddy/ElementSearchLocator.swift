//
//  ElementSearchLocator.swift
//  leanring-buddy
//
//  Created by Antigravity.
//

import Foundation
import ApplicationServices
import Cocoa
import Vision

@MainActor
class ElementSearchLocator {
    
    /// Searches for a UI element by name using the macOS Accessibility API (if permission is granted).
    /// Returns the AppKit global coordinate (bottom-left origin) and the frame of the screen it's on, or nil.
    static func locateViaAccessibility(query: String) async -> (point: CGPoint, screenFrame: CGRect)? {
        guard AXIsProcessTrusted() else {
            print("ℹ️ ElementSearchLocator: Accessibility permission not granted, skipping AX search.")
            return nil
        }
        
        // Retrieve screen frames directly on the Main Actor
        let screenFrames = NSScreen.screens.map { $0.frame }
        guard !screenFrames.isEmpty else { return nil }
        let primaryHeight = screenFrames[0].height
        
        // Fetch all application info on the Main Actor
        struct AppInfo: Sendable {
            let pid: pid_t
            let name: String
            let bundleIdentifier: String?
        }
        
        let active = NSWorkspace.shared.frontmostApplication.map {
            AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "unknown", bundleIdentifier: $0.bundleIdentifier)
        }
        let running = NSWorkspace.shared.runningApplications
        let dock = running.first(where: { $0.bundleIdentifier == "com.apple.dock" }).map {
            AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "unknown", bundleIdentifier: $0.bundleIdentifier)
        }
        let activeIdentifier = active?.bundleIdentifier
        let others = running.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != activeIdentifier
        }.map {
            AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "unknown", bundleIdentifier: $0.bundleIdentifier)
        }
        
        // Run on a background thread because AX API calls can block / perform IPC.
        return await Task.detached(priority: .userInitiated) {
            let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanQuery.isEmpty else { return nil }
            
            // 1. Check the frontmost (active) application first.
            if let activeApp = active {
                let appRef = AXUIElementCreateApplication(activeApp.pid)
                if let found = searchApplication(appRef, query: cleanQuery, screenFrames: screenFrames, primaryHeight: primaryHeight) {
                    print("🎯 ElementSearchLocator: Found via AX API in active app (\(activeApp.name))")
                    return found
                }
            }
            
            // 2. Check the Dock (com.apple.dock) where many key icons live.
            if let dockApp = dock {
                let dockRef = AXUIElementCreateApplication(dockApp.pid)
                if let found = searchApplication(dockRef, query: cleanQuery, screenFrames: screenFrames, primaryHeight: primaryHeight) {
                    print("🎯 ElementSearchLocator: Found via AX API in Dock")
                    return found
                }
            }
            
            // 3. Check other running applications.
            for app in others {
                let appRef = AXUIElementCreateApplication(app.pid)
                if let found = searchApplication(appRef, query: cleanQuery, screenFrames: screenFrames, primaryHeight: primaryHeight) {
                    print("🎯 ElementSearchLocator: Found via AX API in app (\(app.name))")
                    return found
                }
            }
            
            return nil
        }.value
    }
    
    private static nonisolated func searchApplication(
        _ appRef: AXUIElement,
        query: String,
        screenFrames: [CGRect],
        primaryHeight: CGFloat
    ) -> (point: CGPoint, screenFrame: CGRect)? {
        var visitedCount = 0
        let maxVisited = 500 // Safety limit to keep it fast
        let maxDepth = 6
        
        // A) Search the menu bar first if it exists
        var menuBarVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXMenuBarAttribute as CFString, &menuBarVal) == .success {
            let menuBar = menuBarVal as! AXUIElement
            if let element = searchElementTree(menuBar, query: query, currentDepth: 0, maxDepth: maxDepth, visitedCount: &visitedCount, maxVisited: maxVisited) {
                if let frame = getElementAppKitFrame(element, primaryHeight: primaryHeight) {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    if let screenFrame = getScreenFrame(for: center, screenFrames: screenFrames) {
                        return (center, screenFrame)
                    }
                }
            }
        }
        
        // B) Search the windows
        var windowsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsVal) == .success,
           let windows = windowsVal as? [AXUIElement] {
            for window in windows {
                if let element = searchElementTree(window, query: query, currentDepth: 0, maxDepth: maxDepth, visitedCount: &visitedCount, maxVisited: maxVisited) {
                    if let frame = getElementAppKitFrame(element, primaryHeight: primaryHeight) {
                        let center = CGPoint(x: frame.midX, y: frame.midY)
                        if let screenFrame = getScreenFrame(for: center, screenFrames: screenFrames) {
                            return (center, screenFrame)
                        }
                    }
                }
            }
        }
        
        // C) Fallback: Search the application element tree directly
        if let element = searchElementTree(appRef, query: query, currentDepth: 0, maxDepth: maxDepth, visitedCount: &visitedCount, maxVisited: maxVisited) {
            if let frame = getElementAppKitFrame(element, primaryHeight: primaryHeight) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                if let screenFrame = getScreenFrame(for: center, screenFrames: screenFrames) {
                    return (center, screenFrame)
                }
            }
        }
        
        return nil
    }
    
    private static nonisolated func searchElementTree(
        _ element: AXUIElement,
        query: String,
        currentDepth: Int,
        maxDepth: Int,
        visitedCount: inout Int,
        maxVisited: Int
    ) -> AXUIElement? {
        if visitedCount >= maxVisited { return nil }
        visitedCount += 1
        
        // Check current element role
        var shouldCheckAttributes = true
        var roleVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal) == .success,
           let role = roleVal as? String,
           role == "AXApplication" {
            shouldCheckAttributes = false
        }
        
        if shouldCheckAttributes {
            let attrs = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
            for attr in attrs {
                var val: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(element, attr as CFString, &val)
                if err == .success, let str = val as? String {
                    let cleanStr = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanStr.localizedCaseInsensitiveContains(query) {
                        // Make sure it has a valid size/position before returning
                        var posVal: AnyObject?
                        var sizeVal: AnyObject?
                        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
                           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success {
                            var point = CGPoint.zero
                            var size = CGSize.zero
                            if AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
                               AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) {
                                if size.width > 1.0 && size.height > 1.0 {
                                    return element
                                }
                            }
                        }
                    }
                }
            }
        }
        
        if currentDepth >= maxDepth { return nil }
        
        // Search children
        var childrenVal: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal)
        guard err == .success, let children = childrenVal as? [AXUIElement] else {
            return nil
        }
        
        for child in children {
            if let found = searchElementTree(
                child,
                query: query,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                visitedCount: &visitedCount,
                maxVisited: maxVisited
            ) {
                return found
            }
        }
        
        return nil
    }
    
    private static nonisolated func getElementAppKitFrame(_ element: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }
        
        var point = CGPoint.zero
        var size = CGSize.zero
        
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        
        let cgRect = CGRect(origin: point, size: size)
        
        // Convert CoreGraphics coords (top-left origin) to AppKit global coords (bottom-left origin)
        let appKitY = primaryHeight - (cgRect.origin.y + cgRect.height)
        return CGRect(x: cgRect.origin.x, y: appKitY, width: cgRect.width, height: cgRect.height)
    }
    
    private static nonisolated func getScreenFrame(for point: CGPoint, screenFrames: [CGRect]) -> CGRect? {
        if let frame = screenFrames.first(where: { $0.contains(point) }) {
            return frame
        }
        return screenFrames.first
    }
    
    /// Searches for text on a CGImage using the Apple Vision framework's OCR capability.
    /// Returns the pixel coordinate (top-left origin of screenshot) if found.
    static nonisolated func locateViaVisionOCR(query: String, cleanCGImage: CGImage) async -> CGPoint? {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return nil }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // 1. Look for exact case-insensitive matches first
                for observation in observations {
                    if let topCandidate = observation.topCandidates(1).first {
                        let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        if text.caseInsensitiveCompare(cleanQuery) == .orderedSame {
                            let rect = observation.boundingBox
                            let pixelX = rect.midX * CGFloat(cleanCGImage.width)
                            let pixelY = (1.0 - rect.midY) * CGFloat(cleanCGImage.height)
                            print("🎯 ElementSearchLocator: Exact match via Vision OCR for \"\(cleanQuery)\" at (\(pixelX), \(pixelY))")
                            continuation.resume(returning: CGPoint(x: pixelX, y: pixelY))
                            return
                        }
                    }
                }
                
                // 2. Look for substring matches
                for observation in observations {
                    if let topCandidate = observation.topCandidates(1).first {
                        let text = topCandidate.string
                        if text.localizedCaseInsensitiveContains(cleanQuery) {
                            let rect = observation.boundingBox
                            let pixelX = rect.midX * CGFloat(cleanCGImage.width)
                            let pixelY = (1.0 - rect.midY) * CGFloat(cleanCGImage.height)
                            print("🎯 ElementSearchLocator: Substring match via Vision OCR for \"\(cleanQuery)\" in \"\(text)\" at (\(pixelX), \(pixelY))")
                            continuation.resume(returning: CGPoint(x: pixelX, y: pixelY))
                            return
                        }
                    }
                }
                
                continuation.resume(returning: nil)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cleanCGImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("⚠️ ElementSearchLocator: Vision OCR failed: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }
}
