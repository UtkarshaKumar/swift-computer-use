import AppKit
import ApplicationServices

// MARK: - AXObserverManager

/// Manages AXObserver registrations across all running applications.
///
/// Design constraints (see ADR-002):
/// - Event-driven only. Polling is prohibited.
/// - Registers per-app AND per-window observers.
/// - Handles app launches via NSWorkspace notifications so newly started
///   apps are automatically covered.
///
/// Thread safety: all mutation happens on `queue` (serial, QoS userInteractive).
/// The event handler is called on that same queue.
public final class AXObserverManager: @unchecked Sendable {

    public init() {}

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - App-level vs window-level event split
    //
    // AXFocusedUIElementChanged and AXWindowCreated are app-scoped:
    // subscribing on the application element receives them for the entire app.
    //
    // The remaining four are element-scoped: they must be subscribed on each
    // window (or UI element) individually. We subscribe them on every window
    // the app currently has and on each new window created (via AXWindowCreated).

    static let appLevelNotifications: [AXEvent.Notification] = [
        .focusedUIElementChanged,
        .windowCreated,
    ]

    static let windowLevelNotifications: [AXEvent.Notification] = [
        .windowMiniaturized,
        .uiElementDestroyed,
        .valueChanged,
        .selectedTextChanged,
    ]

    // MARK: - Internal state

    private struct AppEntry {
        let observer: AXObserver
        let appElement: AXUIElement
        /// CFHash of windows already subscribed, to avoid double-registration.
        var subscribedWindowHashes: Set<UInt>
        /// Retained pointer to the ObserverContext passed as AXObserver refcon.
        let contextPtr: UnsafeMutableRawPointer
    }

    private var apps: [pid_t: AppEntry] = [:]
    private let queue = DispatchQueue(label: "com.sdd.axobserver", qos: .userInteractive)

    // MARK: - Public interface

    /// Called for every AX event on the serial `queue`.
    public var eventHandler: ((AXEvent) -> Void)?

    /// Start observing all running regular-activation apps and any future launches.
    /// Safe to call from any thread.
    public func start() {
        // Capture the running app list on whichever thread we're on — NSWorkspace is thread-safe.
        // Dispatch registration onto queue because registerApp requires .onQueue(queue).
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier }

        queue.async { [weak self] in
            guard let self else { return }
            for pid in pids {
                self.registerApp(pid: pid)
            }
        }

        // Future launches — addObserver is thread-safe; delivery hops to queue inside the handlers.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// Stop all observations and release resources.
    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        queue.sync {
            for entry in apps.values {
                let src = AXObserverGetRunLoopSource(entry.observer)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
                // Release the retained ObserverContext
                Unmanaged<ObserverContext>.fromOpaque(entry.contextPtr).release()
            }
            apps.removeAll()
        }
    }

    // MARK: - NSWorkspace callbacks

    @objc private func handleAppLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        // Give the app 200 ms to set up its AX tree before we observe it.
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.registerApp(pid: app.processIdentifier)
        }
    }

    @objc private func handleAppTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        queue.async { [weak self] in
            self?.deregisterApp(pid: app.processIdentifier)
        }
    }

    // MARK: - Observer registration

    private func registerApp(pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard apps[pid] == nil else { return }

        // Create context before the observer so we can pass it as refcon.
        let ctx = ObserverContext(manager: self, pid: pid)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        var rawObserver: AXObserver?
        let err = AXObserverCreate(pid, axEventCallback, &rawObserver)
        guard err == .success, let observer = rawObserver else {
            Unmanaged<ObserverContext>.fromOpaque(ctxPtr).release()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Subscribe app-level events
        for notification in AXObserverManager.appLevelNotifications {
            AXObserverAddNotification(observer, appElement, notification.cfString, ctxPtr)
        }

        // Subscribe window-level events on existing windows
        var subscribedHashes: Set<UInt> = []
        if let windows = axWindows(of: appElement) {
            for window in windows {
                subscribeWindowEvents(observer: observer, window: window, ctxPtr: ctxPtr)
                subscribedHashes.insert(CFHash(window))
            }
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        apps[pid] = AppEntry(
            observer: observer,
            appElement: appElement,
            subscribedWindowHashes: subscribedHashes,
            contextPtr: ctxPtr
        )
    }

    private func deregisterApp(pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let entry = apps.removeValue(forKey: pid) else { return }
        let src = AXObserverGetRunLoopSource(entry.observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        Unmanaged<ObserverContext>.fromOpaque(entry.contextPtr).release()
    }

    private func subscribeWindowEvents(
        observer: AXObserver,
        window: AXUIElement,
        ctxPtr: UnsafeMutableRawPointer
    ) {
        for notification in AXObserverManager.windowLevelNotifications {
            AXObserverAddNotification(observer, window, notification.cfString, ctxPtr)
        }
    }

    // MARK: - Internal event dispatch (called from C callback)

    /// Called on the main run loop by the AX callback. Hops to `queue` for
    /// state mutation, then calls `eventHandler`.
    func dispatchEvent(observer: AXObserver, element: AXUIElement, notification: CFString, pid: pid_t) {
        guard let axNotification = AXEvent.Notification(cfString: notification) else {
            // Unknown notification — ignore rather than crash.
            return
        }

        // If a new window was created, subscribe window-level events on it.
        if axNotification == .windowCreated {
            queue.async { [weak self] in
                self?.handleWindowCreated(for: pid)
            }
        }

        let event = AXEvent(notification: axNotification, elementRef: element)
        queue.async { [weak self] in
            self?.eventHandler?(event)
        }
    }

    private func handleWindowCreated(for pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var entry = apps[pid] else { return }

        if let windows = axWindows(of: entry.appElement) {
            for window in windows {
                let hash = CFHash(window)
                guard !entry.subscribedWindowHashes.contains(hash) else { continue }
                subscribeWindowEvents(observer: entry.observer, window: window, ctxPtr: entry.contextPtr)
                entry.subscribedWindowHashes.insert(hash)
            }
        }
        apps[pid] = entry
    }

    // MARK: - Helpers

    private func axWindows(of appElement: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? [AXUIElement]
    }
}

// MARK: - ObserverContext

/// Lightweight context object threaded through every AXObserver refcon pointer.
/// Holds an unowned reference to the manager (the manager owns the observer lifetime).
final class ObserverContext {
    unowned let manager: AXObserverManager
    let pid: pid_t

    init(manager: AXObserverManager, pid: pid_t) {
        self.manager = manager
        self.pid = pid
    }
}

// MARK: - C callback (must be a free function — no captures)

/// Entry point called by the OS on the main run loop whenever an AX event fires.
/// Bridges to Swift by extracting the `ObserverContext` from `refcon`.
private func axEventCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let ptr = refcon else { return }
    let ctx = Unmanaged<ObserverContext>.fromOpaque(ptr).takeUnretainedValue()
    ctx.manager.dispatchEvent(observer: observer, element: element, notification: notification, pid: ctx.pid)
}
