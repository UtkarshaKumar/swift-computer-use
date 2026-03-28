// ISSUE-1 INTERFACE
// These types define the boundary between Issue #1 (WorldModel) and Issue #2 (FastBrain).
// When Issue #1 lands, replace these stubs with the real WorldModel types.
// All AX element access is via opaque handle — no coordinates.

import Foundation
import CoreGraphics

// MARK: - UIElement

/// A single semantic UI element from the AX tree.
/// axHandle wraps AXUIElement in production; OpaquePointer? allows test compilation
/// without importing ApplicationServices.
public struct UIElement: @unchecked Sendable {
    /// Opaque handle to the backing AXUIElement. Never use coordinates — always dispatch
    /// actions via this handle (AXPress, AXSetValue, etc.).
    public let axHandle: OpaquePointer?

    /// AX role string, e.g. "AXTextField", "AXButton", "AXTextArea", "AXSearchField",
    /// "AXCheckBox", "AXComboBox". "AXUnknown" signals a canvas region with no AX coverage.
    public let role: String

    /// Human-readable accessibility label (AXLabel / AXDescription).
    public let label: String

    /// Current value (AXValue), if any.
    public let value: String?

    /// True if this element currently holds AX focus.
    public let isFocused: Bool

    /// True if the element is interactive (AXEnabled).
    public let isEnabled: Bool

    /// True if the element lies within the current viewport. Elements outside the
    /// viewport require a scroll action before they can be interacted with.
    public let isVisible: Bool

    /// Screen-space bounding rect. Used ONLY for scroll detection (is element below fold?).
    /// Never pass frame coordinates to action execution — use axHandle.
    public let frame: CGRect

    /// Direct AX children (one level only; flatten recursively for full subtree).
    public let children: [UIElement]

    public init(
        axHandle: OpaquePointer? = nil,
        role: String,
        label: String,
        value: String? = nil,
        isFocused: Bool = false,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        frame: CGRect = CGRect(x: 0, y: 0, width: 0, height: 0),
        children: [UIElement] = []
    ) {
        self.axHandle = axHandle
        self.role = role
        self.label = label
        self.value = value
        self.isFocused = isFocused
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.frame = frame
        self.children = children
    }
}

// MARK: - AppContext

/// The foreground application and window state at the time of the snapshot.
public struct AppContext: Sendable {
    public let bundleID: String
    public let windowTitle: String?
    /// The element that currently holds AX focus, if any.
    public let focusedElement: UIElement?
    /// Viewport rect of the active window (used for fold detection).
    public let viewportFrame: CGRect

    public init(
        bundleID: String,
        windowTitle: String? = nil,
        focusedElement: UIElement? = nil,
        viewportFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.focusedElement = focusedElement
        self.viewportFrame = viewportFrame
    }
}

// MARK: - WorldModelSnapshot

/// Point-in-time snapshot of the world model delivered to FastBrain for evaluation.
/// Issue #1 will stream these as diffs; FastBrain receives the latest materialized snapshot.
public struct WorldModelSnapshot: Sendable {
    public let timestamp: Date
    public let appContext: AppContext
    /// Flat list of all known interactive elements in the active window.
    /// Issue #1 will deliver this pre-flattened from the AX graph.
    public let elements: [UIElement]

    public init(
        timestamp: Date = Date(),
        appContext: AppContext,
        elements: [UIElement]
    ) {
        self.timestamp = timestamp
        self.appContext = appContext
        self.elements = elements
    }
}
