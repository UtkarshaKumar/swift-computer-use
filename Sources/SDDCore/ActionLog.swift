import Foundation

/// Represents a single action execution log entry
public struct ActionLog: Codable, Sendable {
    /// ISO8601 timestamp when the action was executed
    public let timestamp: String

    /// Type of action performed (e.g., "click", "type", "scroll")
    public let actionType: String

    /// Unique identifier of the target element
    public let elementId: String?

    /// Human-readable label of the target element
    public let elementLabel: String?

    /// Whether the action was successfully verified
    public let success: Bool

    /// Latency in milliseconds from action initiation to verify signal
    public let latencyMs: Int

    /// True only when tertiary fallback (canvas_region) path was used
    public let usedCoordinates: Bool

    /// Which brain path executed this action.
    /// "fast"      — resolved by FastBrain (built-in or learned rule, <1ms)
    /// "slow"      — escalated to SlowBrain LLM (network latency)
    /// "eval_stub" — synthetic action produced by the EVAL harness
    public let brainPath: String

    /// Error message if the action failed
    public let error: String?

    public init(
        timestamp: Date = Date(),
        actionType: String,
        elementId: String?,
        elementLabel: String?,
        success: Bool,
        latencyMs: Int,
        usedCoordinates: Bool,
        brainPath: String = "fast",
        error: String? = nil
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: timestamp)
        self.actionType = actionType
        self.elementId = elementId
        self.elementLabel = elementLabel
        self.success = success
        self.latencyMs = latencyMs
        self.usedCoordinates = usedCoordinates
        self.brainPath = brainPath
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case actionType = "action_type"
        case elementId = "element_id"
        case elementLabel = "element_label"
        case success
        case latencyMs = "latency_ms"
        case usedCoordinates = "used_coordinates"
        case brainPath = "brain_path"
        case error
    }
}
