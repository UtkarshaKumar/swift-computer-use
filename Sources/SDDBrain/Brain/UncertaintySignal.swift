import Foundation

// MARK: - ResolvedAction

/// A deterministic action ready for the ActionExecutor to dispatch.
/// All actions target an AX element handle — no coordinates.
public enum ResolvedAction: Sendable {
    /// Set the value of a text field or combo box (maps to AXSetValue).
    case setValue(element: FBElement, value: String)

    /// Activate a button, checkbox, or link (maps to AXPress).
    case press(element: FBElement)

    /// Scroll within a scrollable container (maps to AXScroll / AXScrollToVisible).
    case scroll(element: FBElement, direction: ScrollDirection, amount: Int)
}

// MARK: - UncertaintySignal

/// Emitted by FastBrain when confidence is below the configured threshold.
/// The SlowBrain router receives this and forwards to the LLM endpoint.
public struct UncertaintySignal: Sendable {
    /// The snapshot that was evaluated.
    public let snapshot: FBSnapshot
    /// The task that could not be resolved confidently.
    public let task: TaskContext
    /// The best confidence score produced by any rule (may be 0.0 if no rule matched).
    public let confidence: Double
    /// Human-readable explanation of why escalation was triggered.
    public let reason: String

    public init(
        snapshot: FBSnapshot,
        task: TaskContext,
        confidence: Double,
        reason: String
    ) {
        self.snapshot = snapshot
        self.task = task
        self.confidence = confidence
        self.reason = reason
    }
}

// MARK: - FastBrainResult

/// The output of a single FastBrain evaluation cycle.
public enum FastBrainResult: Sendable {
    /// FastBrain resolved the action with sufficient confidence.
    case action(ResolvedAction, confidence: Double)
    /// FastBrain confidence was below threshold — route to SlowBrain.
    case uncertain(UncertaintySignal)
}
