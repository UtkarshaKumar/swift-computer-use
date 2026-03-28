import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import SDDCore

// MARK: - WorkflowMatch

/// Result of WorkflowLibrary.evaluate() — a matched workflow with its confidence.
public struct WorkflowMatch: Sendable {
    public let workflow: any BuiltInWorkflow
    public let confidence: Double

    public init(workflow: any BuiltInWorkflow, confidence: Double) {
        self.workflow = workflow
        self.confidence = confidence
    }
}

// MARK: - BuiltInWorkflow

/// Protocol all built-in workflows conform to.
public protocol BuiltInWorkflow: Sendable {
    var name: String { get }
    /// Returns 0.0 if this workflow cannot handle the goal, or a confidence in 0.0–1.0 otherwise.
    func canHandle(goal: String) -> Double
    /// Execute the workflow. Returns true if successful.
    func execute() async -> Bool
}

// MARK: - WorkflowLibrary

/// Static library of deterministic built-in workflows.
public struct WorkflowLibrary: Sendable {

    public static let all: [any BuiltInWorkflow] = [
        OpenURLWorkflow(),
        FileUploadWorkflow(),
        KeyboardShortcutWorkflow(),
        ScrollToTopWorkflow(),
        WaitForPageLoadWorkflow(),
    ]

    /// Evaluate goal string against all built-in workflows.
    /// Returns the highest-confidence match, or nil if none match above 0.75.
    public static func evaluate(goal: String) -> WorkflowMatch? {
        var best: WorkflowMatch? = nil
        for workflow in all {
            let confidence = workflow.canHandle(goal: goal)
            if confidence > 0.75 {
                if best == nil || confidence > best!.confidence {
                    best = WorkflowMatch(workflow: workflow, confidence: confidence)
                }
            }
        }
        return best
    }
}

// MARK: - Helpers

/// Post a CGEvent key down + up pair.
private func postKeyEvent(_ keyCode: CGKeyCode, modifiers: CGEventFlags = []) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) else { return }
    guard let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
    if !modifiers.isEmpty {
        keyDown.flags = modifiers
        keyUp.flags = modifiers
    }
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

/// Expand `~` at the start of a path to the user's home directory.
private func expandPath(_ path: String) -> String {
    if path.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/" + path.dropFirst(2)
    }
    return path
}

/// Type a string character by character using CGEvent keyboard events.
private func typeString(_ text: String) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    for scalar in text.unicodeScalars {
        let chars = [UniChar(scalar.value)]
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: chars)
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: chars)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - OpenURLWorkflow

public struct OpenURLWorkflow: BuiltInWorkflow, @unchecked Sendable {
    public let name = "OpenURL"

    // Captured URL extracted when canHandle is called from the evaluate loop.
    // Because Sendable semantics require value types, we store no mutable state —
    // the URL is re-extracted inside execute() from the goal stored at init time.
    private let goal: String

    public init(goal: String = "") {
        self.goal = goal
    }

    public func canHandle(goal: String) -> Double {
        let pattern = #"(open|navigate|go\s+to|visit|load)\s+(https?://\S+|www\.\S+)"#
        guard let _ = goal.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0.0
        }
        return 0.95
    }

    public func execute() async -> Bool {
        guard let url = extractURL(from: goal) else { return false }
        // Focus address bar: Cmd+L (keyCode 37 = L)
        postKeyEvent(37, modifiers: .maskCommand)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        // Type the URL
        typeString(url)
        // Press Return (keyCode 36)
        postKeyEvent(36)
        return true
    }

    private func extractURL(from text: String) -> String? {
        let pattern = #"https?://\S+|www\.\S+"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(text[range])
    }
}

// MARK: - FileUploadWorkflow

public struct FileUploadWorkflow: BuiltInWorkflow, @unchecked Sendable {
    public let name = "FileUpload"

    private let goal: String

    public init(goal: String = "") {
        self.goal = goal
    }

    public func canHandle(goal: String) -> Double {
        let actionPattern = #"(upload|attach|select\s+file|choose\s+file)\s+\S+"#
        guard let _ = goal.range(of: actionPattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0.0
        }
        // Must also contain a file path
        let pathPattern = #"(~/|/)\S+"#
        guard let _ = goal.range(of: pathPattern, options: [.regularExpression]) else {
            return 0.0
        }
        return 0.90
    }

    public func execute() async -> Bool {
        guard let filePath = extractFilePath(from: goal) else { return false }
        let expandedPath = expandPath(filePath)

        // Step 1: find an upload button via AX
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppElement: CFTypeRef?
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppElement)
        guard let appElement = focusedAppElement else { return false }

        let uploadButtonLabels = ["upload", "choose", "browse", "attach", "select file"]
        var uploadButton: AXUIElement? = findButton(
            in: appElement as! AXUIElement,
            matchingLabels: uploadButtonLabels,
            maxDepth: 10
        )

        guard let button = uploadButton else { return false }

        // Step 2: click the upload button
        AXUIElementPerformAction(button, kAXPressAction as CFString)

        // Step 3: wait up to 3s for an Open/Choose dialog
        var openDialog: AXUIElement? = nil
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            openDialog = findOpenDialog(in: appElement as! AXUIElement)
            if openDialog != nil { break }
        }
        guard let dialog = openDialog else { return false }

        // Step 4a: try to set path in AXTextField
        if let textField = findTextField(in: dialog) {
            let cfPath = expandedPath as CFString
            let result = AXUIElementSetAttributeValue(textField, kAXValueAttribute as CFString, cfPath)
            if result == .success {
                // Find and press the Open button
                if let openButton = findButton(in: dialog, matchingLabels: ["open"], maxDepth: 5) {
                    AXUIElementPerformAction(openButton, kAXPressAction as CFString)
                    return true
                }
            }
        }

        // Step 4b: fallback — keyboard type the path, then Return
        typeString(expandedPath)
        postKeyEvent(36) // Return
        return true
    }

    private func extractFilePath(from text: String) -> String? {
        let pattern = #"(~/\S+|/\S+)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Recursively search for AXButton with a label matching any of the given strings (case-insensitive).
    private func findButton(in element: AXUIElement, matchingLabels labels: [String], maxDepth: Int) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        if role == "AXButton" {
            var titleRef: CFTypeRef?
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
            let title = ((titleRef as? String) ?? "").lowercased()
            let desc  = ((descRef  as? String) ?? "").lowercased()
            for label in labels {
                if title.contains(label) || desc.contains(label) {
                    return element
                }
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findButton(in: child, matchingLabels: labels, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    /// Search for a window with title containing "Open" or "Choose" — typical file dialog titles.
    private func findOpenDialog(in appElement: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard let windows = windowsRef as? [AXUIElement] else { return nil }
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = ((titleRef as? String) ?? "").lowercased()
            if title.contains("open") || title.contains("choose") {
                return window
            }
        }
        return nil
    }

    /// Find the first AXTextField within an element (non-recursive shallow search at depth 5).
    private func findTextField(in element: AXUIElement) -> AXUIElement? {
        return findRole("AXTextField", in: element, maxDepth: 5)
    }

    private func findRole(_ targetRole: String, in element: AXUIElement, maxDepth: Int) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == targetRole { return element }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findRole(targetRole, in: child, maxDepth: maxDepth - 1) { return found }
        }
        return nil
    }
}

// MARK: - KeyboardShortcutWorkflow

public struct KeyboardShortcutWorkflow: BuiltInWorkflow, @unchecked Sendable {
    public let name = "KeyboardShortcut"

    private let goal: String

    public init(goal: String = "") {
        self.goal = goal
    }

    public func canHandle(goal: String) -> Double {
        let pattern = #"(press|type|hit|send)\s+(cmd|command|ctrl|control|opt|option|shift)\+\w"#
        guard let _ = goal.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0.0
        }
        return 0.97
    }

    public func execute() async -> Bool {
        let (keyCode, flags) = parseShortcut(from: goal)
        guard let code = keyCode else { return false }
        postKeyEvent(code, modifiers: flags)
        return true
    }

    /// Parse the first modifier+key combo from the goal string.
    private func parseShortcut(from text: String) -> (CGKeyCode?, CGEventFlags) {
        let lower = text.lowercased()

        // Extract the shortcut portion after "press/type/hit/send"
        let triggerPattern = #"(press|type|hit|send)\s+([\w\+]+)"#
        guard let range = lower.range(of: triggerPattern, options: .regularExpression) else {
            return (nil, [])
        }
        let shortcutText = String(lower[range])

        // Collect modifier flags
        var flags: CGEventFlags = []
        if shortcutText.contains("cmd") || shortcutText.contains("command") {
            flags.insert(.maskCommand)
        }
        if shortcutText.contains("ctrl") || shortcutText.contains("control") {
            flags.insert(.maskControl)
        }
        if shortcutText.contains("opt") || shortcutText.contains("option") {
            flags.insert(.maskAlternate)
        }
        if shortcutText.contains("shift") {
            flags.insert(.maskShift)
        }

        // Extract the trailing key character
        // e.g. "cmd+l" → "l", "ctrl+shift+t" → "t"
        let parts = shortcutText.components(separatedBy: "+")
        guard let keyPart = parts.last else { return (nil, flags) }

        let keyCode = keyCodeForString(keyPart.trimmingCharacters(in: .whitespacesAndNewlines))
        return (keyCode, flags)
    }

    private func keyCodeForString(_ key: String) -> CGKeyCode? {
        switch key {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "return", "enter": return 36
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "tab": return 48
        case "space": return 49
        case "`": return 50
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default: return nil
        }
    }
}

// MARK: - ScrollToTopWorkflow

public struct ScrollToTopWorkflow: BuiltInWorkflow, @unchecked Sendable {
    public let name = "ScrollToTop"

    public init() {}

    public func canHandle(goal: String) -> Double {
        let pattern = #"(scroll\s+to\s+top|go\s+to\s+top|back\s+to\s+top)"#
        guard let _ = goal.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0.0
        }
        return 0.92
    }

    public func execute() async -> Bool {
        // Cmd+Up Arrow (keyCode 126)
        postKeyEvent(126, modifiers: .maskCommand)
        return true
    }
}

// MARK: - WaitForPageLoadWorkflow

public struct WaitForPageLoadWorkflow: BuiltInWorkflow, @unchecked Sendable {
    public let name = "WaitForPageLoad"

    public init() {}

    public func canHandle(goal: String) -> Double {
        let pattern = #"(wait\s+for|wait\s+until|loading)"#
        guard let _ = goal.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return 0.0
        }
        return 0.80
    }

    public func execute() async -> Bool {
        // Simple 2-second heuristic wait
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return true
    }
}
