import Foundation

// MARK: - gRPC Service Definitions

// WorldModel message representing the semantic state of the screen
public struct WorldModel: Codable, Sendable {
    public let timestamp: Double
    public let elements: [UIElement]
    public let activeApp: String?
    public let focusedElement: String?
    
    public init(timestamp: Double, elements: [UIElement], activeApp: String?, focusedElement: String?) {
        self.timestamp = timestamp
        self.elements = elements
        self.activeApp = activeApp
        self.focusedElement = focusedElement
    }
}

// UI Element in the world model
public struct UIElement: Codable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: ElementFrame?
    public let enabled: Bool
    public let focused: Bool
    public let children: [String]
    public let parent: String?
    public let app: String
    public let window: String?
    
    public init(
        id: String,
        role: String,
        label: String? = nil,
        value: String? = nil,
        frame: ElementFrame? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        children: [String] = [],
        parent: String? = nil,
        app: String,
        window: String? = nil
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
        self.children = children
        self.parent = parent
        self.app = app
        self.window = window
    }
}

// Element frame/bounds
public struct ElementFrame: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// World model diff for streaming updates
public struct WorldModelDiff: Codable, Sendable {
    public let timestamp: Double
    public let added: [UIElement]
    public let removed: [String]
    public let modified: [UIElement]
    
    public init(timestamp: Double, added: [UIElement], removed: [String], modified: [UIElement]) {
        self.timestamp = timestamp
        self.added = added
        self.removed = removed
        self.modified = modified
    }
}

// Action request/response types
public struct ClickRequest: Codable, Sendable {
    public let label: String
    
    public init(label: String) {
        self.label = label
    }
}

public struct TypeTextRequest: Codable, Sendable {
    public let field: String
    public let value: String
    
    public init(field: String, value: String) {
        self.field = field
        self.value = value
    }
}

public struct ScrollRequest: Codable, Sendable {
    public let direction: String
    public let amount: Int
    
    public init(direction: String, amount: Int) {
        self.direction = direction
        self.amount = amount
    }
}

public struct ScreenshotRequest: Codable, Sendable {
    public let region: String?
    
    public init(region: String? = nil) {
        self.region = region
    }
}

public struct ActionResponse: Codable, Sendable {
    public let success: Bool
    public let message: String?
    
    public init(success: Bool, message: String? = nil) {
        self.success = success
        self.message = message
    }
}

public struct ScreenshotResponse: Codable, Sendable {
    public let success: Bool
    public let data: String?  // Base64 encoded image
    public let mimeType: String?
    public let message: String?
    
    public init(success: Bool, data: String? = nil, mimeType: String? = nil, message: String? = nil) {
        self.success = success
        self.data = data
        self.mimeType = mimeType
        self.message = message
    }
}
