import Foundation

// MARK: - LabelMatchType

/// How a learned rule matches an element's label against its stored pattern.
public enum LabelMatchType: String, Codable, Sendable {
    /// Element label == pattern exactly (most specific; preferred for buttons)
    case exact
    /// Case-insensitive exact match
    case caseInsensitive
    /// Element label contains pattern as a substring
    case substring
}

// MARK: - TaskIntentType

/// Discriminator for the TaskIntent that was resolved.
/// Stored separately from the full TaskIntent because TaskContext is not Codable.
public enum TaskIntentType: String, Codable, Sendable {
    case pressButton
    case typeValue
    case scroll
}

// MARK: - LearnedAction

/// The action to execute, stored without a live AXUIElement (which is not Codable).
/// On evaluation, the executor resolves it against the live snapshot by
/// matching targetRole + targetLabel.
public enum LearnedAction: Codable, Sendable {
    case press(targetRole: String, targetLabel: String)
    case setValue(targetRole: String, targetLabel: String, value: String)
    case scroll(targetRole: String, targetLabel: String, direction: String, amount: Int)

    // MARK: Codable
    private enum CodingKeys: String, CodingKey {
        case type, targetRole, targetLabel, value, direction, amount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let role  = try c.decode(String.self, forKey: .targetRole)
        let label = try c.decode(String.self, forKey: .targetLabel)
        switch type {
        case "press":
            self = .press(targetRole: role, targetLabel: label)
        case "setValue":
            let v = try c.decode(String.self, forKey: .value)
            self = .setValue(targetRole: role, targetLabel: label, value: v)
        case "scroll":
            let dir = try c.decode(String.self, forKey: .direction)
            let amt = try c.decode(Int.self, forKey: .amount)
            self = .scroll(targetRole: role, targetLabel: label, direction: dir, amount: amt)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown LearnedAction type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .press(let role, let label):
            try c.encode("press", forKey: .type)
            try c.encode(role, forKey: .targetRole)
            try c.encode(label, forKey: .targetLabel)
        case .setValue(let role, let label, let value):
            try c.encode("setValue", forKey: .type)
            try c.encode(role, forKey: .targetRole)
            try c.encode(label, forKey: .targetLabel)
            try c.encode(value, forKey: .value)
        case .scroll(let role, let label, let dir, let amt):
            try c.encode("scroll", forKey: .type)
            try c.encode(role, forKey: .targetRole)
            try c.encode(label, forKey: .targetLabel)
            try c.encode(dir, forKey: .direction)
            try c.encode(amt, forKey: .amount)
        }
    }
}

// MARK: - LearnedRule

/// A persistent rule derived from a successful slow-brain action.
/// On startup, the daemon loads all learned rules and injects them into FastBrain
/// as highest-priority rules. Matching is O(n·rules) per snapshot evaluation.
public struct LearnedRule: Codable, Sendable {

    // MARK: Identity
    public let id: UUID
    public let createdAt: Date
    /// How many times this rule has fired successfully in production.
    public var successCount: Int
    public var lastUsedAt: Date?

    // MARK: Matching criteria
    /// App bundle ID this rule applies to. Empty string = match any app.
    public let targetBundleID: String
    public let elementRole: String
    public let elementLabelPattern: String
    public let labelMatchType: LabelMatchType

    // MARK: Intent + action
    public let intentType: TaskIntentType
    public let resolvedAction: LearnedAction

    // MARK: Confidence
    /// Confidence score returned by FastBrain when this rule fires.
    /// Starts at 0.90 for a new rule; can rise with successCount.
    public let confidence: Double

    // MARK: Constraints
    public let requiresEnabled: Bool
    public let requiresVisible: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        successCount: Int = 1,
        lastUsedAt: Date? = nil,
        targetBundleID: String,
        elementRole: String,
        elementLabelPattern: String,
        labelMatchType: LabelMatchType = .caseInsensitive,
        intentType: TaskIntentType,
        resolvedAction: LearnedAction,
        confidence: Double = 0.90,
        requiresEnabled: Bool = true,
        requiresVisible: Bool = true
    ) {
        self.id = id
        self.createdAt = createdAt
        self.successCount = successCount
        self.lastUsedAt = lastUsedAt
        self.targetBundleID = targetBundleID
        self.elementRole = elementRole
        self.elementLabelPattern = elementLabelPattern
        self.labelMatchType = labelMatchType
        self.intentType = intentType
        self.resolvedAction = resolvedAction
        self.confidence = confidence
        self.requiresEnabled = requiresEnabled
        self.requiresVisible = requiresVisible
    }

    // MARK: - Label matching

    public func labelMatches(_ candidate: String) -> Bool {
        switch labelMatchType {
        case .exact:
            return candidate == elementLabelPattern
        case .caseInsensitive:
            return candidate.lowercased() == elementLabelPattern.lowercased()
        case .substring:
            return candidate.lowercased().contains(elementLabelPattern.lowercased())
        }
    }

    // MARK: - Intent type matching

    public func intentTypeMatches(_ intentType: TaskIntentType) -> Bool {
        self.intentType == intentType
    }
}

// MARK: - Sequential Workflow types

/// One step in a recorded workflow sequence.
public struct LearnedWorkflowStep: Sendable, Codable {
    public let stepIndex: Int
    public let elementRole: String
    public let elementLabel: String
    public let action: String          // "press" | "setValue"
    public let value: String           // empty string for press actions
    public let bundleID: String

    public init(stepIndex: Int, elementRole: String, elementLabel: String,
                action: String, value: String, bundleID: String) {
        self.stepIndex = stepIndex
        self.elementRole = elementRole
        self.elementLabel = elementLabel
        self.action = action
        self.value = value
        self.bundleID = bundleID
    }
}

/// An ordered sequence of UI steps that accomplishes a named goal.
public struct LearnedWorkflow: Sendable, Codable {
    public let id: UUID
    public let name: String
    public let goal: String
    public let steps: [LearnedWorkflowStep]
    public let createdAt: Date
    public var successCount: Int

    public init(id: UUID = UUID(), name: String, goal: String,
                steps: [LearnedWorkflowStep], createdAt: Date = Date(),
                successCount: Int = 1) {
        self.id = id
        self.name = name
        self.goal = goal
        self.steps = steps
        self.createdAt = createdAt
        self.successCount = successCount
    }
}
