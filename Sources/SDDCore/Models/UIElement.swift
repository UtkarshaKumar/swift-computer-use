import Foundation
import ApplicationServices

// MARK: - UIElementID

/// Stable, opaque identifier for a UI element within the world model.
/// Derived from the AXUIElement hash — stable across world model rebuilds
/// within a single daemon session, but not across restarts.
public struct UIElementID: Hashable, Sendable, Codable {
    public let rawValue: UInt64

    public init(_ axElement: AXUIElement) {
        self.rawValue = UInt64(CFHash(axElement))
    }

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

// MARK: - UIElementRole

/// Semantic role of a UI element. Maps from AX role strings.
public enum UIElementRole: String, Sendable, Codable, CaseIterable {
    case button
    case textField
    case staticText
    case checkBox
    case radioButton
    case popUpButton
    case comboBox
    case slider
    case progressIndicator
    case link
    case image
    case scrollArea
    case scrollBar
    case group
    case window
    case sheet
    case dialog
    case toolbar
    case menuBar
    case menu
    case menuItem
    case table
    case tableRow
    case tableColumn
    case outline
    case outlineRow
    case list
    case listItem
    case tabGroup
    case tab
    case splitGroup
    case splitter
    case webArea
    case unknown

    public init(axRole: String) {
        // Strip the "AX" prefix that Apple prepends
        let stripped = axRole.hasPrefix("AX") ? String(axRole.dropFirst(2)) : axRole
        let lower = stripped.prefix(1).lowercased() + stripped.dropFirst()
        self = UIElementRole(rawValue: lower) ?? .unknown
    }
}

// MARK: - UIElementState

/// Mutable state flags for a UI element.
public struct UIElementState: OptionSet, Sendable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let enabled   = UIElementState(rawValue: 1 << 0)
    public static let focused   = UIElementState(rawValue: 1 << 1)
    public static let selected  = UIElementState(rawValue: 1 << 2)
    public static let expanded  = UIElementState(rawValue: 1 << 3)
    public static let minimized = UIElementState(rawValue: 1 << 4)
    public static let visible   = UIElementState(rawValue: 1 << 5)
}

// MARK: - UIElementFrame

/// Screen-relative bounding rectangle. All coordinates are in points (not pixels).
/// Used for informational purposes only — actions MUST use the element's AX handle,
/// not these coordinates.
public struct UIElementFrame: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let zero = UIElementFrame(x: 0, y: 0, width: 0, height: 0)
}

// MARK: - UIElement

/// A node in the SDD world model representing a single accessible UI element.
/// This is the canonical type shared between SDD internals and external consumers.
public struct UIElement: Sendable, Codable {
    public let id: UIElementID
    public let role: UIElementRole
    /// Human-readable label (kAXTitleAttribute or kAXDescriptionAttribute)
    public let label: String?
    /// Current value (kAXValueAttribute) — text for text fields, Bool for checkboxes, etc.
    public let value: String?
    public var state: UIElementState
    /// Screen frame. Informational only. Do not use for action targeting.
    public let frame: UIElementFrame
    /// IDs of direct children in the AX tree
    public let childIDs: [UIElementID]
    /// ID of the parent element, nil for window roots
    public let parentID: UIElementID?
    /// PID of the owning application
    public let ownerPID: pid_t

    public init(
        id: UIElementID,
        role: UIElementRole,
        label: String?,
        value: String?,
        state: UIElementState,
        frame: UIElementFrame,
        childIDs: [UIElementID],
        parentID: UIElementID?,
        ownerPID: pid_t
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.state = state
        self.frame = frame
        self.childIDs = childIDs
        self.parentID = parentID
        self.ownerPID = ownerPID
    }
}
