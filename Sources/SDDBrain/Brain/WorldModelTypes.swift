// FastBrain internal snapshot types.
// Distinct from SDDCore.WorldModelSnapshot (canonical for external consumers).
// WorldModel.apply(event:) translates SDDCore diffs into FBSnapshot before
// delivering them to FastBrain.evaluate().

import Foundation
import CoreGraphics

// MARK: - FBElement

/// A single semantic UI element from the AX tree as seen by FastBrain.
public struct FBElement: @unchecked Sendable {
    public let axHandle: OpaquePointer?
    public let role: String
    public let label: String
    public let value: String?
    public let isFocused: Bool
    public let isEnabled: Bool
    public let isVisible: Bool
    public let frame: CGRect

    public init(
        axHandle: OpaquePointer? = nil,
        role: String,
        label: String,
        value: String? = nil,
        isFocused: Bool = false,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        frame: CGRect = .zero
    ) {
        self.axHandle = axHandle; self.role = role; self.label = label
        self.value = value; self.isFocused = isFocused; self.isEnabled = isEnabled
        self.isVisible = isVisible; self.frame = frame
    }
}

// MARK: - FBAppContext

public struct FBAppContext: Sendable {
    public let bundleID: String
    public let windowTitle: String?
    public let focusedElement: FBElement?
    public let viewportFrame: CGRect

    public init(
        bundleID: String,
        windowTitle: String? = nil,
        focusedElement: FBElement? = nil,
        viewportFrame: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    ) {
        self.bundleID = bundleID; self.windowTitle = windowTitle
        self.focusedElement = focusedElement; self.viewportFrame = viewportFrame
    }
}

// MARK: - FBSnapshot

public struct FBSnapshot: Sendable {
    public let timestamp: Date
    public let appContext: FBAppContext
    public let elements: [FBElement]

    public init(timestamp: Date = Date(), appContext: FBAppContext, elements: [FBElement]) {
        self.timestamp = timestamp; self.appContext = appContext; self.elements = elements
    }
}
