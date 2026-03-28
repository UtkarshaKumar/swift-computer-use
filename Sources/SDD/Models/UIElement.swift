import Foundation
import CoreGraphics

public struct UIElement: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: CGRect
    public let isEnabled: Bool
    public let isFocused: Bool
    public let children: [UIElement]
    public let isCanvasRegion: Bool
    
    public init(
        id: String,
        role: String,
        label: String? = nil,
        value: String? = nil,
        frame: CGRect,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        children: [UIElement] = [],
        isCanvasRegion: Bool = false
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.children = children
        self.isCanvasRegion = isCanvasRegion
    }
}

public struct UIElementUpdate: Sendable {
    public let element: UIElement
    public let timestamp: Date
    public let operation: UpdateOperation
    
    public enum UpdateOperation: Sendable {
        case insert
        case update
        case delete
    }
    
    public init(element: UIElement, timestamp: Date, operation: UpdateOperation) {
        self.element = element
        self.timestamp = timestamp
        self.operation = operation
    }
}

public struct WorldModelDiff: Sendable, Equatable {
    public let timestamp: Date
    public let changedElements: [UIElement]
    public let removedIds: [String]
    public let focusedElementId: String?
    public let activeApp: String
    
    public init(
        timestamp: Date,
        changedElements: [UIElement],
        removedIds: [String],
        focusedElementId: String?,
        activeApp: String
    ) {
        self.timestamp = timestamp
        self.changedElements = changedElements
        self.removedIds = removedIds
        self.focusedElementId = focusedElementId
        self.activeApp = activeApp
    }
}

public enum AXEvent: Sendable {
    case elementCreated(UIElement, app: String)
    case elementUpdated(UIElement, app: String)
    case elementDestroyed(id: String, app: String)
    case focusChanged(elementId: String?, app: String)
    case appChanged(app: String)
    case windowCreated(windowId: String, app: String)
    case windowDestroyed(windowId: String, app: String)
}
