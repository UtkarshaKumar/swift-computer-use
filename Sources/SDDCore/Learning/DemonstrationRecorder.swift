import Foundation
import AppKit
import ApplicationServices

/// A service that listens to global mouse/keyboard events and extracts UI element
/// data underneath the exact cursor location, synthesizing a LearnedRule iteratively.
///
/// Note: Requires Accessibility privileges (System Settings > Privacy > Accessibility)
@MainActor
public class DemonstrationRecorder {
    
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    
    private var currentTypeBuffer = ""
    public var onRuleExtracted: ((LearnedRule) -> Void)?
    
    public init() {}
    
    /// Starts the recording session. Requires an active NSApplication runloop.
    public func startRecording(taskGoal: String) {
        let systemWide = AXUIElementCreateSystemWide()
        
        // 1. Monitor Left Mouse Up (Click)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self else { return }

            // If the user previously typed something before clicking elsewhere, extract a typeRule first.
            self.flushTypeBuffer()

            let nsLoc = event.locationInWindow
            // Convert to CoreGraphics screen space
            guard let screen = NSScreen.screens.first else { return }
            let cgLoc = CGPoint(x: nsLoc.x, y: screen.frame.height - nsLoc.y)

            var elementRef: AXUIElement? = nil
            let err = AXUIElementCopyElementAtPosition(systemWide, Float(cgLoc.x), Float(cgLoc.y), &elementRef)

            guard err == .success, let axElement = elementRef else { return }

            // Extract role and label (AX calls are safe on any thread)
            var roleRef: CFTypeRef?
            var labelRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &labelRef)
            if labelRef == nil {
                AXUIElementCopyAttributeValue(axElement, kAXDescriptionAttribute as CFString, &labelRef)
            }

            let role = (roleRef as? String) ?? "AXUnknown"
            let label = (labelRef as? String) ?? ""

            // We only care about interactive elements (ignoring pure text overlays unless they're buttons/links)
            guard role == "AXButton" || role == "AXLink" || role == "AXMenuItem"
                    || role == "AXTextField" || role == "AXStaticText" else { return }

            // NSWorkspace.shared must be accessed on the main thread.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

                let rule = LearnedRule(
                    id: UUID(),
                    createdAt: Date(),
                    successCount: 1,
                    targetBundleID: bundleID,
                    elementRole: role,
                    elementLabelPattern: label,
                    labelMatchType: .caseInsensitive,
                    intentType: .pressButton,
                    resolvedAction: .press(targetRole: role, targetLabel: label),
                    confidence: 1.0 // 100% confidence — user physically demonstrated it
                )
                self.onRuleExtracted?(rule)
            }
        }
        
        // 2. Monitor typing (Key Down)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            if let chars = event.charactersIgnoringModifiers {
                if event.keyCode == 36 { // Return key
                    self.flushTypeBuffer() // Commit buffer on Enter
                } else if event.keyCode == 51 { // Delete key
                    if !self.currentTypeBuffer.isEmpty {
                        self.currentTypeBuffer.removeLast()
                    }
                } else {
                    self.currentTypeBuffer.append(chars)
                }
            }
        }
    }
    
    private func flushTypeBuffer() {
        guard !currentTypeBuffer.isEmpty else { return }

        let bufferSnapshot = currentTypeBuffer
        currentTypeBuffer = ""

        // AX focused-element query — safe on any thread
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)

        guard err == .success, let axElement = focusedElementRef as! AXUIElement? else { return }

        var roleRef: CFTypeRef?
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleRef)
        if titleRef == nil {
            AXUIElementCopyAttributeValue(axElement, kAXDescriptionAttribute as CFString, &titleRef)
        }

        let role  = (roleRef  as? String) ?? "AXTextField"
        let label = (titleRef as? String) ?? "FocusedField"

        // NSWorkspace.shared must run on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

            let rule = LearnedRule(
                id: UUID(),
                createdAt: Date(),
                successCount: 1,
                targetBundleID: bundleID,
                elementRole: role,
                elementLabelPattern: label,
                labelMatchType: .caseInsensitive,
                intentType: .typeValue,
                resolvedAction: .setValue(targetRole: role, targetLabel: label, value: bufferSnapshot),
                confidence: 1.0
            )
            self.onRuleExtracted?(rule)
        }
    }
    
    public func stopRecording() {
        if let m1 = mouseMonitor { NSEvent.removeMonitor(m1) }
        if let m2 = keyMonitor { NSEvent.removeMonitor(m2) }
        flushTypeBuffer()
        mouseMonitor = nil
        keyMonitor = nil
    }
}
