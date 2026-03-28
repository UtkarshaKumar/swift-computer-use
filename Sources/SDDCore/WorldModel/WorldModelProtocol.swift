import Foundation

// MARK: - WorldModelSnapshot

/// Point-in-time snapshot of the entire world model.
/// Used for initial state delivery to new subscribers and for debug/test inspection.
public struct WorldModelSnapshot: Sendable {
    /// All currently tracked elements, keyed by ID.
    public let elements: [UIElementID: UIElement]
    /// ID of the currently focused element, if any.
    public let focusedElementID: UIElementID?
    /// PIDs of all tracked applications.
    public let trackedApps: Set<pid_t>
    /// Wall-clock time this snapshot was captured.
    public let capturedAt: Date

    public init(
        elements: [UIElementID: UIElement],
        focusedElementID: UIElementID?,
        trackedApps: Set<pid_t>,
        capturedAt: Date = .now
    ) {
        self.elements = elements
        self.focusedElementID = focusedElementID
        self.trackedApps = trackedApps
        self.capturedAt = capturedAt
    }
}

// MARK: - WorldModelDiff

/// A minimal structural diff emitted after each meaningful AX event.
/// Subscribers receive diffs, not full snapshots, to minimize bandwidth.
public struct WorldModelDiff: Sendable {
    /// Elements newly added to the world model
    public let added: [UIElement]
    /// Elements that changed (value, state, frame)
    public let updated: [UIElement]
    /// IDs of elements removed from the world model
    public let removed: [UIElementID]
    /// The AX event that triggered this diff
    public let triggeringEvent: AXEvent
    /// Focus state after the diff is applied
    public let focusedElementID: UIElementID?

    public init(
        added: [UIElement] = [],
        updated: [UIElement] = [],
        removed: [UIElementID] = [],
        triggeringEvent: AXEvent,
        focusedElementID: UIElementID?
    ) {
        self.added = added
        self.updated = updated
        self.removed = removed
        self.triggeringEvent = triggeringEvent
        self.focusedElementID = focusedElementID
    }

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
}

// MARK: - SubscriptionToken

/// Returned by `WorldModelProtocol.subscribe`. Cancels the subscription on deinit.
public final class SubscriptionToken: Sendable {
    private let cancelFn: @Sendable () -> Void
    public init(cancel: @escaping @Sendable () -> Void) { self.cancelFn = cancel }
    deinit { cancelFn() }
    public func cancel() { cancelFn() }
}

// MARK: - WorldModelProtocol

/// The world model is a live, in-memory directed graph of all UI elements on screen.
///
/// Consumers (external agents, fast brain, slow brain router) interact via this
/// protocol only — the concrete implementation is internal to SDDCore.
///
/// Protocol constraints:
/// - `apply(event:)` must be called exactly once per AXEvent, in order.
/// - Diffs are emitted synchronously during `apply(event:)` before the call returns.
/// - Subscribers MUST be non-blocking; slow work should be dispatched async.
public protocol WorldModelProtocol: AnyObject, Sendable {

    // MARK: Mutations

    /// Apply an AX event, update the graph, and emit a diff to all subscribers.
    /// Must NOT block — returns after all subscriber callbacks have returned.
    func apply(event: AXEvent)

    // MARK: Subscriptions

    /// Subscribe to world model diffs. The handler is called on the diff-emission
    /// queue (serial). Returns a token; the subscription is cancelled on token deinit.
    @discardableResult
    func subscribe(handler: @escaping @Sendable (WorldModelDiff) -> Void) -> SubscriptionToken

    // MARK: Queries

    /// Current snapshot. O(n) copy — call sparingly.
    var currentSnapshot: WorldModelSnapshot { get }

    /// Look up a single element by ID. O(1).
    func element(for id: UIElementID) -> UIElement?

    /// The currently focused element, if any.
    var focusedElement: UIElement? { get }
}
