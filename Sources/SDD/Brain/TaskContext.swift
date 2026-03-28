import Foundation

// MARK: - ScrollDirection

public enum ScrollDirection: Sendable {
    case up
    case down
    case left
    case right
}

// MARK: - TaskIntent

/// The agent's declared intent for the current action.
/// FastBrain pattern-matches this against WorldModelSnapshot to decide what to do.
public enum TaskIntent: Sendable {
    /// Type a value into a text field. `targetLabel` is the field's accessibility label;
    /// nil means "use whatever is currently focused".
    case typeValue(targetLabel: String?, value: String)

    /// Press a button (or activate a checkbox/link) identified by its label.
    case pressButton(label: String)

    /// Scroll within the window. `targetLabel` identifies an element to scroll to;
    /// nil scrolls the main content area.
    case scroll(targetLabel: String?, direction: ScrollDirection)

    /// A custom intent that FastBrain cannot match deterministically — will always escalate.
    case custom(description: String)
}

// MARK: - TaskContext

/// The full context for a single agent action request.
public struct TaskContext: Sendable {
    public let intent: TaskIntent
    public let sessionID: UUID

    public init(intent: TaskIntent, sessionID: UUID = UUID()) {
        self.intent = intent
        self.sessionID = sessionID
    }
}
