import Foundation

/// Represents a single UI element on the screen.
public struct UIElement: Codable {
    public let id: String
    public let role: String
    public let label: String
    public let value: String?
    public let isFocused: Bool
    public let frame: CGRect
    public let parentID: String?
    public let childrenIDs: [String]
    
    public init(id: String, role: String, label: String, value: String? = nil, isFocused: Bool = false, frame: CGRect = .zero, parentID: String? = nil, childrenIDs: [String] = []) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.isFocused = isFocused
        self.frame = frame
        self.parentID = parentID
        self.childrenIDs = childrenIDs
    }
}

/// Represents a historical action and its result.
public struct ActionHistory: Codable {
    public let action: String
    public let elementID: String
    public let result: String
    public let timestamp: Date
    
    public init(action: String, elementID: String, result: String, timestamp: Date = Date()) {
        self.action = action
        self.elementID = elementID
        self.result = result
        self.timestamp = timestamp
    }
}

/// Represents the current active task and its progress.
public struct ActiveTask: Codable {
    public let objective: String
    public let remainingSteps: [String]
    
    public init(objective: String, remainingSteps: [String]) {
        self.objective = objective
        self.remainingSteps = remainingSteps
    }
}

/// The continuous semantic world model of the screen.
public protocol WorldModel {
    var currentApp: String { get }
    var activeWindowTitle: String { get }
    var focusedElementID: String? { get }
    var elements: [String: UIElement] { get }
    var actionHistory: [ActionHistory] { get }
    var activeTask: ActiveTask? { get }
    
    func getElement(by id: String) -> UIElement?
    func getParentChain(for elementID: String, maxDepth: Int) -> [UIElement]
    func getVisibleInteractiveElements() -> [UIElement]
}
