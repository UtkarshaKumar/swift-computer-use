import Foundation
import ApplicationServices

/// A single accessibility event received from the OS via AXObserver.
///
/// All six subscribed notification types map to this struct.
/// The `elementRef` is the AXUIElement handle — never a coordinate pair.
// AXUIElement is a CoreFoundation-backed object safe to pass across queues
// in practice, but Apple has not annotated it as Sendable in SDK headers.
// @unchecked Sendable documents this deliberate decision.
public struct AXEvent: @unchecked Sendable {
    public let notification: Notification
    public let elementRef: AXUIElement
    public let timestamp: Date

    /// The six event types SDD subscribes to. Exhaustive — adding a new
    /// event type here forces a compiler error at every switch site.
    public enum Notification: String, CaseIterable, Sendable {
        case focusedUIElementChanged = "AXFocusedUIElementChanged"
        case windowCreated          = "AXWindowCreated"
        case windowMiniaturized     = "AXWindowMiniaturized"
        case uiElementDestroyed     = "AXUIElementDestroyed"
        case valueChanged           = "AXValueChanged"
        case selectedTextChanged    = "AXSelectedTextChanged"

        /// Failable init from the raw CFString the OS sends.
        public init?(cfString: CFString) {
            self.init(rawValue: cfString as String)
        }

        public var cfString: CFString { rawValue as CFString }
    }

    public init(notification: Notification, elementRef: AXUIElement, timestamp: Date = .now) {
        self.notification = notification
        self.elementRef = elementRef
        self.timestamp = timestamp
    }
}
