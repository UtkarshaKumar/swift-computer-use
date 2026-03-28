import Foundation

/// Represents a single action as part of an action plan from the slow brain.
public struct ActionPlan: Codable {
    public let action: String
    public let elementSelector: String
    public let value: String?
    public let verifyCondition: String?
    
    public enum CodingKeys: String, CodingKey {
        case action
        case elementSelector = "element_selector"
        case value
        case verifyCondition = "verify_condition"
    }
    
    public init(action: String, elementSelector: String, value: String? = nil, verifyCondition: String? = nil) {
        self.action = action
        self.elementSelector = elementSelector
        self.value = value
        self.verifyCondition = verifyCondition
    }
}
