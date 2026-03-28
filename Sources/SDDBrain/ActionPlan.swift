import Foundation

/// Represents a single action as part of an action plan from the slow brain.
/// x, y are screen coordinates (origin top-left) returned when the LLM uses vision.
public struct ActionPlan: Codable, Sendable {
    public let action: String
    public let elementSelector: String
    public let value: String?
    public let verifyCondition: String?
    public let x: Int?   // screen x coordinate (vision path)
    public let y: Int?   // screen y coordinate (vision path)

    public enum CodingKeys: String, CodingKey {
        case action
        case elementSelector = "element_selector"
        case value
        case verifyCondition = "verify_condition"
        case x
        case y
    }

    public init(
        action: String,
        elementSelector: String = "",
        value: String? = nil,
        verifyCondition: String? = nil,
        x: Int? = nil,
        y: Int? = nil
    ) {
        self.action = action
        self.elementSelector = elementSelector
        self.value = value
        self.verifyCondition = verifyCondition
        self.x = x
        self.y = y
    }

    /// Custom decoder: tolerates missing element_selector (defaults to ""),
    /// and handles x/y as Int or Double (LLMs sometimes return floats).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        elementSelector = (try? c.decode(String.self, forKey: .elementSelector)) ?? ""
        value = try? c.decode(String.self, forKey: .value)
        verifyCondition = try? c.decode(String.self, forKey: .verifyCondition)
        // Handle Int or Double for x/y
        if let intX = try? c.decode(Int.self, forKey: .x) {
            x = intX
        } else if let dblX = try? c.decode(Double.self, forKey: .x) {
            x = Int(dblX)
        } else {
            x = nil
        }
        if let intY = try? c.decode(Int.self, forKey: .y) {
            y = intY
        } else if let dblY = try? c.decode(Double.self, forKey: .y) {
            y = Int(dblY)
        } else {
            y = nil
        }
    }
}
