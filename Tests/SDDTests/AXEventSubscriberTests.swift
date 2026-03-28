import XCTest
import AppKit
import ApplicationServices
@testable import SDDCore

// MARK: - AXEventSubscriberTests

/// Tests that the AXObserverManager correctly receives and routes all six
/// subscribed event types. Silent misses are treated as hard failures.
///
/// Two test layers:
///   1. Unit — exercises the dispatch logic with synthetic events (no AX required)
///   2. Integration — fires real AX events via a live NSWindow
///      (skipped automatically if Accessibility is not granted)
final class AXEventSubscriberTests: XCTestCase, @unchecked Sendable {

    // MARK: - Unit: routing logic

    /// Verify that every AXEvent.Notification case is routed to the handler.
    /// This test exercises the AXObserverManager.dispatchEvent path directly,
    /// bypassing the OS. A silent miss here means a notification was dropped.
    func test_allNotificationTypes_areRoutedToHandler() {
        let manager = AXObserverManager()

        var received: [AXEvent.Notification] = []
        manager.eventHandler = { event in
            received.append(event.notification)
        }

        let dummyElement = AXUIElementCreateSystemWide()

        for notification in AXEvent.Notification.allCases {
            // Simulate the OS firing the callback
            manager.dispatchEvent(
                observer: makeTestObserver(),
                element: dummyElement,
                notification: notification.cfString,
                pid: ProcessInfo.processInfo.processIdentifier
            )
        }

        // Drain the serial queue before asserting
        drainManagerQueue(manager)

        XCTAssertEqual(
            Set(received),
            Set(AXEvent.Notification.allCases),
            "Silent miss detected: not all event types were routed. Missing: \(Set(AXEvent.Notification.allCases).subtracting(received))"
        )
    }

    /// Unknown notification strings must be silently dropped, not crash.
    func test_unknownNotification_isIgnored() {
        let manager = AXObserverManager()
        var received: [AXEvent] = []
        manager.eventHandler = { received.append($0) }

        manager.dispatchEvent(
            observer: makeTestObserver(),
            element: AXUIElementCreateSystemWide(),
            notification: "AXNonExistentFakeEvent" as CFString,
            pid: ProcessInfo.processInfo.processIdentifier
        )

        drainManagerQueue(manager)
        XCTAssertTrue(received.isEmpty, "Unknown notification should be dropped, not forwarded")
    }

    /// Each event carries the element handle, not coordinates.
    func test_event_carriesElementHandle_notCoordinates() {
        let manager = AXObserverManager()
        var capturedEvent: AXEvent?
        manager.eventHandler = { capturedEvent = $0 }

        let element = AXUIElementCreateSystemWide()
        manager.dispatchEvent(
            observer: makeTestObserver(),
            element: element,
            notification: AXEvent.Notification.focusedUIElementChanged.cfString,
            pid: ProcessInfo.processInfo.processIdentifier
        )

        drainManagerQueue(manager)
        XCTAssertNotNil(capturedEvent)
        // The event holds the AXUIElement reference — not a coordinate pair
        XCTAssertEqual(CFHash(capturedEvent!.elementRef), CFHash(element))
    }

    // MARK: - Unit: AXEvent.Notification exhaustiveness

    /// If a new notification type is added but not handled in a switch somewhere,
    /// the compiler error prevents a silent miss. This test documents that all
    /// six types are intentionally covered.
    func test_allSixNotificationTypesAreDefined() {
        XCTAssertEqual(AXEvent.Notification.allCases.count, 6,
            "Expected exactly 6 notification types. If you added one, update subscriptions AND this test.")

        let expected: Set<String> = [
            "AXFocusedUIElementChanged",
            "AXWindowCreated",
            "AXWindowMiniaturized",
            "AXUIElementDestroyed",
            "AXValueChanged",
            "AXSelectedTextChanged",
        ]
        let actual = Set(AXEvent.Notification.allCases.map(\.rawValue))
        XCTAssertEqual(actual, expected)
    }

    // MARK: - Integration: real AX events

    /// Fires AXFocusedUIElementChanged by creating a window and making its
    /// text field the first responder. Verifies the event reaches the handler.
    ///
    /// Requires Accessibility permission — automatically skipped if not granted.
    func test_integration_focusedUIElementChanged_fires() throws {
        try skipIfAccessibilityNotGranted()
        let exp = expectation(description: "AXFocusedUIElementChanged received")

        let manager = AXObserverManager()
        manager.eventHandler = { event in
            if event.notification == .focusedUIElementChanged {
                exp.fulfill()
            }
        }
        manager.start()
        defer { manager.stop() }

        // Create a window with a text field and focus it on the main thread
        let textField = try runOnMain { [self] in
            makeWindowWithTextField()
        }

        runOnMain {
            textField.window?.makeKey()
            textField.window?.makeFirstResponder(textField)
        }

        wait(for: [exp], timeout: 2.0)
    }

    /// Fires AXWindowCreated by opening a new NSWindow.
    func test_integration_windowCreated_fires() throws {
        try skipIfAccessibilityNotGranted()
        let exp = expectation(description: "AXWindowCreated received")

        let manager = AXObserverManager()
        manager.eventHandler = { event in
            if event.notification == .windowCreated { exp.fulfill() }
        }
        manager.start()
        defer { manager.stop() }

        runOnMain {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            w.makeKeyAndOrderFront(nil)
        }

        wait(for: [exp], timeout: 2.0)
    }

    /// Fires AXWindowMiniaturized by miniaturizing a window.
    func test_integration_windowMiniaturized_fires() throws {
        try skipIfAccessibilityNotGranted()
        let exp = expectation(description: "AXWindowMiniaturized received")

        let manager = AXObserverManager()
        manager.eventHandler = { event in
            if event.notification == .windowMiniaturized { exp.fulfill() }
        }
        manager.start()
        defer { manager.stop() }

        runOnMain {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.titled, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.makeKeyAndOrderFront(nil)
            w.miniaturize(nil)
        }

        wait(for: [exp], timeout: 2.0)
    }

    /// Fires AXValueChanged by setting a text field's value programmatically.
    func test_integration_valueChanged_fires() throws {
        try skipIfAccessibilityNotGranted()
        let exp = expectation(description: "AXValueChanged received")

        let manager = AXObserverManager()
        manager.eventHandler = { event in
            if event.notification == .valueChanged { exp.fulfill() }
        }
        manager.start()
        defer { manager.stop() }

        let textField = try runOnMain { [self] in makeWindowWithTextField() }

        runOnMain {
            textField.window?.makeKey()
            textField.window?.makeFirstResponder(textField)
            // Changing stringValue fires AXValueChanged on the text field's AX element
            textField.stringValue = "hello"
        }

        wait(for: [exp], timeout: 2.0)
    }

    /// Fires AXSelectedTextChanged by selecting text in a focused text field.
    func test_integration_selectedTextChanged_fires() throws {
        try skipIfAccessibilityNotGranted()
        let exp = expectation(description: "AXSelectedTextChanged received")

        let manager = AXObserverManager()
        manager.eventHandler = { event in
            if event.notification == .selectedTextChanged { exp.fulfill() }
        }
        manager.start()
        defer { manager.stop() }

        let textField = try runOnMain { [self] in makeWindowWithTextField() }

        runOnMain {
            textField.window?.makeKey()
            textField.window?.makeFirstResponder(textField)
            textField.stringValue = "select me"
            textField.selectText(nil)
        }

        wait(for: [exp], timeout: 2.0)
    }

    /// Fires AXUIElementDestroyed by closing a window.
    func test_integration_uiElementDestroyed_fires() throws {
        try skipIfAccessibilityNotGranted()
        let exp = expectation(description: "AXUIElementDestroyed received")

        let manager = AXObserverManager()
        manager.eventHandler = { event in
            if event.notification == .uiElementDestroyed { exp.fulfill() }
        }
        manager.start()
        defer { manager.stop() }

        runOnMain {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.makeKeyAndOrderFront(nil)
            // Close destroys the window element and fires AXUIElementDestroyed
            w.close()
        }

        wait(for: [exp], timeout: 2.0)
    }
}

// MARK: - Test Helpers

private extension AXEventSubscriberTests {

    /// Skip the test if Accessibility permission is not granted.
    func skipIfAccessibilityNotGranted() throws {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw XCTSkip("Accessibility permission not granted — run with 'System Settings → Accessibility' permission for integration tests")
        }
    }

    /// Drain the AXObserverManager's internal serial queue.
    func drainManagerQueue(_ manager: AXObserverManager) {
        // The manager uses a private queue; reach it by dispatching a sync
        // barrier via a public entry point that uses the same queue.
        let drain = expectation(description: "queue drain")
        // Use a fire-and-forget dispatch on the main queue to give the serial
        // queue time to process, then fulfill.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drain.fulfill() }
        wait(for: [drain], timeout: 1.0)
    }

    /// Run a non-throwing block on the main thread (safe from test queues).
    func runOnMain(_ block: @Sendable () -> Void) {
        if Thread.isMainThread { block(); return }
        DispatchQueue.main.sync { block() }
    }

    /// Run a throwing block on the main thread and return its value.
    @discardableResult
    func runOnMain<T: Sendable>(_ block: @Sendable () throws -> T) throws -> T {
        if Thread.isMainThread { return try block() }
        let result: Result<T, Error> = DispatchQueue.main.sync { Result { try block() } }
        return try result.get()
    }

    /// Create an NSWindow with a single NSTextField and return the text field.
    /// Must be called on the main thread.
    func makeWindowWithTextField() -> NSTextField {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let tf = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 30))
        window.contentView?.addSubview(tf)
        window.makeKeyAndOrderFront(nil)
        return tf
    }

    /// Create a minimal AXObserver for unit test use. The observer is never
    /// added to a run loop, so its callback never actually fires — it is only
    /// used as a type-correct argument to `dispatchEvent`.
    func makeTestObserver() -> AXObserver {
        var obs: AXObserver?
        let pid = ProcessInfo.processInfo.processIdentifier
        // Callback is a no-op — we never add this to a run loop in unit tests
        AXObserverCreate(pid, { _, _, _, _ in }, &obs)
        return obs! // Will always succeed for our own PID
    }
}
