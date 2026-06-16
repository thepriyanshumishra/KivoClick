//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let cleanCGImage: CGImage
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            // Draw an 18-column × 11-row coordinate grid over the screenshot before sending
            // to the AI. Large centered labels (e.g. "D09") let even weak vision models
            // reliably read the cell reference for any on-screen element.
            let gridImage = drawGridOverlay(on: cgImage)
            guard let jpegData = NSBitmapImageRep(cgImage: gridImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height,
                cleanCGImage: cgImage
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }


        return capturedScreens
    }

    // MARK: - Grid Overlay

    /// Draws an 18-column × 11-row coordinate grid over a screenshot image.
    /// Each cell has its label (e.g. "D09") printed in large bold text centered
    /// inside the cell on a dark background, so vision models can read the reference
    /// even when the screenshot is downscaled for API transmission.
    /// Rows are labeled A–K (top to bottom). Columns are labeled 01–18 (left to right).
    private static func drawGridOverlay(on cgImage: CGImage) -> CGImage {
        let totalCols = 18
        let totalRows = 11
        let width = cgImage.width
        let height = cgImage.height

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return cgImage
        }

        bitmapRep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext

        // Draw the original screenshot as the background layer
        let drawRect = NSRect(x: 0, y: 0, width: width, height: height)
        let nsImage = NSImage(cgImage: cgImage, size: bitmapRep.size)
        nsImage.draw(in: drawRect)

        let colWidth = CGFloat(width) / CGFloat(totalCols)
        let rowHeight = CGFloat(height) / CGFloat(totalRows)

        // Thin white vertical dividers between columns
        for col in 1..<totalCols {
            let x = CGFloat(col) * colWidth
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: CGFloat(height)))
            path.lineWidth = 0.8
            NSColor(white: 1.0, alpha: 0.25).setStroke()
            path.stroke()
        }

        // Thin white horizontal dividers between rows
        for row in 1..<totalRows {
            let y = CGFloat(row) * rowHeight
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: CGFloat(width), y: y))
            path.lineWidth = 0.8
            NSColor(white: 1.0, alpha: 0.25).setStroke()
            path.stroke()
        }

        // Centered label in each cell. AppKit has bottom-left origin, so visual
        // row 0 (top of image) corresponds to the highest AppKit Y values.
        let labelFont = NSFont.boldSystemFont(ofSize: 14)
        let labelTextAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let backgroundPadding: CGFloat = 3

        for visualRow in 0..<totalRows {
            let cellTopAppKitY = CGFloat(height) - (CGFloat(visualRow) * rowHeight)
            let cellBottomAppKitY = cellTopAppKitY - rowHeight
            let cellCenterY = (cellTopAppKitY + cellBottomAppKitY) / 2.0

            for col in 0..<totalCols {
                let cellCenterX = (CGFloat(col) * colWidth) + colWidth / 2.0

                // Build label: row letter + zero-padded column number (e.g. "D09")
                guard let letterUnicode = UnicodeScalar(65 + visualRow) else { continue }
                let rowLetter = String(letterUnicode)
                let colDigits = String(format: "%02d", col + 1)
                let cellLabel = "\(rowLetter)\(colDigits)"

                let labelSize = (cellLabel as NSString).size(withAttributes: labelTextAttributes)

                // Dark rounded background behind the label for contrast on any background
                let backgroundRect = NSRect(
                    x: cellCenterX - labelSize.width / 2 - backgroundPadding,
                    y: cellCenterY - labelSize.height / 2 - backgroundPadding,
                    width: labelSize.width + backgroundPadding * 2,
                    height: labelSize.height + backgroundPadding * 2
                )
                let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 3, yRadius: 3)
                NSColor(white: 0.0, alpha: 0.55).setFill()
                backgroundPath.fill()

                // Centered white label text
                let textRect = NSRect(
                    x: cellCenterX - labelSize.width / 2,
                    y: cellCenterY - labelSize.height / 2,
                    width: labelSize.width,
                    height: labelSize.height
                )
                (cellLabel as NSString).draw(in: textRect, withAttributes: labelTextAttributes)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        return bitmapRep.cgImage ?? cgImage
    }
}
