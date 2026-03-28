import Foundation
import ApplicationServices

// MARK: - ElementSelector

/// How an external agent specifies which element to act on.
/// AX element ID is the primary path. Role+label is a fallback for agents that
/// don't yet have a full world model snapshot.
///
/// CRITICAL: Coordinate-based targeting is intentionally absent.
/// All actions route through AX handles. See ADR-004.
public enum ElementSelector: Sendable, Codable {
    /// Direct AX element ID from the world model. Preferred — O(1) lookup.
    case elementID(UIElementID)
    /// Match by exact role and label. Used when the element ID is not known.
    case roleAndLabel(role: UIElementRole, label: String)
    /// Match by role and partial label (case-insensitive prefix).
    case roleAndLabelPrefix(role: UIElementRole, labelPrefix: String)
}

// MARK: - ActionRequest

/// A single action to be executed by the ActionExecutor.
/// Every action targets an element via `ElementSelector`, never via coordinates.
public enum ActionRequest: Sendable {
    /// Equivalent to AXPress — clicks a button, follows a link, etc.
    case press(ElementSelector)
    /// Sets the value of a text field, checkbox, slider, etc. (AXSetValue)
    case setValue(ElementSelector, value: String)
    /// Moves keyboard focus to the element (AXSetFocused = true)
    case setFocused(ElementSelector)
    /// Scrolls the element into view
    case scrollIntoView(ElementSelector)
    /// Keyboard shortcut injection via CGEvent (modifiers + key)
    case keyboardShortcut(modifiers: CGEventFlags, key: CGKeyCode)
}

// MARK: - ActionResult

/// Synchronous result of executing an action. The verify signal is populated
/// by waiting for the world model to confirm the expected state change.
public struct ActionResult: Sendable {
    public enum Outcome: Sendable {
        /// Action executed and world model confirmed the state change
        case success
        /// Action executed but world model did not confirm within the timeout
        case unverified
        /// Element was not found in the world model
        case elementNotFound
        /// AX API returned an error
        case axError(AXError)
        /// The element was flagged as canvas_region — AX action not possible
        case canvasRegion
    }

    public let outcome: Outcome
    /// Elapsed time from API call receipt to verify signal (or timeout)
    public let latencyMs: Double
    /// ID of the element acted on, if resolved
    public let resolvedElementID: UIElementID?

    public init(outcome: Outcome, latencyMs: Double, resolvedElementID: UIElementID?) {
        self.outcome = outcome
        self.latencyMs = latencyMs
        self.resolvedElementID = resolvedElementID
    }
}

// MARK: - ActionExecutorProtocol

/// Executes actions on UI elements via AX handles.
///
/// Implementation contract:
/// - All methods are async; they await the world model verify signal.
/// - Target latency: P95 < 50ms for AX actions (EVAL-SYS-002).
/// - Coordinate fallback is prohibited except for canvas_region elements.
/// - Every action that uses a coordinate MUST increment `coordinateFallbackCount`.
///   This counter feeds EVAL-SYS-004.
public protocol ActionExecutorProtocol: AnyObject, Sendable {

    /// Counter for coordinate-based fallback actions. Must stay < 3% of total.
    var coordinateFallbackCount: Int { get }

    /// Total actions executed since start.
    var totalActionCount: Int { get }

    /// Execute a single action request. Returns after the verify signal fires or
    /// the 50ms timeout elapses.
    func execute(_ request: ActionRequest) async throws -> ActionResult

    /// Execute a sequence of actions. Stops on first failure unless
    /// `continueOnFailure` is true.
    func executeSequence(
        _ requests: [ActionRequest],
        continueOnFailure: Bool
    ) async throws -> [ActionResult]
}
