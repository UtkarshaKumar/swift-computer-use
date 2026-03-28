import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import SDDCore

/// Single-frame screen capture utility for the SlowBrain vision path.
/// Uses ScreenCaptureKit (SCScreenshotManager) — the modern macOS 14+ API.
///
/// The daemon's continuous capture pipeline lives in Sources/SDD/Capture/ScreenCapture.swift.
/// This file is a one-shot helper: grab one JPEG, send it to the LLM.
public struct ScreenCapture: Sendable {

    /// Returns JPEG data of the main display, resized to maxWidth pixels wide.
    /// Requires Screen Recording permission.
    public static func jpeg(maxWidth: Int = 1280) async -> Data? {
        do {
            // Get available content (displays, windows, apps)
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                fputs("[screen-capture] No display found\n", stderr)
                return nil
            }

            // Configure one-shot capture
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = maxWidth
            // Preserve aspect ratio
            let aspect = Double(display.height) / Double(display.width)
            config.height = max(1, Int(Double(maxWidth) * aspect))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesAudio = false
            config.showsCursor = true

            // Capture single frame via SCScreenshotManager (macOS 14+)
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            // Convert CGImage → JPEG data
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        } catch {
            fputs("[screen-capture] Capture failed: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    /// Returns JPEG data of the main display with numbered annotations over elements, and a text index connecting coordinates.
    public static func jpegAnnotated(elements: [UIElement], maxWidth: Int = 1280) async -> (Data?, String) {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                fputs("[screen-capture] No display found\n", stderr)
                return (nil, "")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = maxWidth
            let aspect = Double(display.height) / Double(display.width)
            let outHeight = max(1, Int(Double(maxWidth) * aspect))
            config.height = outHeight
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesAudio = false
            config.showsCursor = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            // Logical scale since ScreenCapture bounds are physical pixels, mapped against NSScreen
            let logicalWidth = displayWidth
            let logicalHeight = displayHeight
            let scaleX = Double(maxWidth) / Double(logicalWidth)
            let scaleY = Double(outHeight) / Double(logicalHeight)

            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let baseData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
                return (nil, "")
            }

            // Drawing Text and BBoxes
            guard let dataProvider = CGDataProvider(data: baseData as CFData),
                  let sourceImage = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let context = CGContext(
                      data: nil,
                      width: maxWidth,
                      height: outHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return (baseData, "")
            }

            context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: maxWidth, height: outHeight))

            var lines = [String]()
            
            // Attributes for the numbers inside the pills
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(11 * scaleX, 9.0), nil)
            let boxOutline = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.7)
            let pillFill = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
            let whiteText = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)

            for (idx, elem) in elements.enumerated() {
                if !elem.state.contains(.visible) || !elem.state.contains(.enabled) { continue }

                let n = idx + 1
                let cx = Int(elem.frame.x + elem.frame.width / 2)
                let cy = Int(elem.frame.y + elem.frame.height / 2)
                let roleStr = elem.role.rawValue
                let shortRole = roleStr.hasPrefix("AX") ? String(roleStr.dropFirst(2)) : roleStr
                let actualLabel = elem.label ?? ""
                let nameStr = actualLabel.isEmpty ? "" : " '\(actualLabel)'"
                lines.append("[\(n)] \(shortRole)\(nameStr) — center: (\(cx), \(cy))")

                let relX = elem.frame.x * scaleX
                let relY = elem.frame.y * scaleY
                let pixW = elem.frame.width * scaleX
                let pixH = elem.frame.height * scaleY

                // CGContext flips Y, so we must invert
                let flippedY = Double(outHeight) - relY - pixH

                context.setStrokeColor(boxOutline)
                context.setLineWidth(1.5)
                context.stroke(CGRect(x: relX, y: flippedY, width: pixW, height: pixH))

                let labelStr = "\(n)"
                let attrString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
                CFAttributedStringReplaceString(attrString, CFRangeMake(0, 0), labelStr as CFString)
                CFAttributedStringSetAttribute(attrString, CFRangeMake(0, labelStr.count), kCTFontAttributeName, font)
                CFAttributedStringSetAttribute(attrString, CFRangeMake(0, labelStr.count), kCTForegroundColorAttributeName, whiteText)

                let line = CTLineCreateWithAttributedString(attrString)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let textWidth = Double(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                let textHeight = Double(ascent + descent)

                let padX: Double = 3.0
                let padY: Double = 2.0
                let pillW = textWidth + padX * 2
                let pillH = textHeight + padY * 2
                let pillX = relX + 2
                let pillY = flippedY + pixH - pillH - 2

                context.setFillColor(pillFill)
                context.fill(CGRect(x: pillX, y: pillY, width: pillW, height: pillH))

                context.saveGState()
                context.textPosition = CGPoint(x: pillX + padX, y: pillY + padY + descent)
                CTLineDraw(line, context)
                context.restoreGState()
            }

            let textIndex = lines.joined(separator: "\n")
            guard let annotated = context.makeImage() else {
                return (baseData, textIndex)
            }

            let finalRep = NSBitmapImageRep(cgImage: annotated)
            return (finalRep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]), textIndex)
        } catch {
            fputs("[screen-capture] Annotated Capture failed: \(error.localizedDescription)\n", stderr)
            return (nil, "")
        }
    }

    /// Logical width of the main display in points.
    public static var displayWidth: Int {
        Int(NSScreen.main?.frame.width ?? 1920)
    }

    /// Logical height of the main display in points.
    public static var displayHeight: Int {
        Int(NSScreen.main?.frame.height ?? 1080)
    }
}
