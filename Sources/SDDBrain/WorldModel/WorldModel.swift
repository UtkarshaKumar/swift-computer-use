import Foundation
import AppKit
import ApplicationServices
import SDDCore

// MARK: - WorldModel

/// Live, in-memory directed graph of all UI elements on screen.
/// Implements WorldModelProtocol — the canonical contract for all consumers.
///
/// Threading:
/// - `apply(event:)` is called on `diffQueue` (serial, .userInteractive).
/// - Subscriber callbacks are called synchronously inside `apply(event:)` on `diffQueue`.
/// - Snapshot reads hop to `diffQueue` via `sync` so callers always see consistent state.
public final class WorldModel: WorldModelProtocol, @unchecked Sendable {

    // MARK: - State (all access on diffQueue)

    private var elements: [UIElementID: UIElement] = [:]
    private var liveRefs: [UIElementID: AXUIElement] = [:]   // retained live AX handles
    private var focusedID: UIElementID?
    private var trackedPIDs: Set<pid_t> = []
    private var subscribers: [(id: UUID, handler: @Sendable (WorldModelDiff) -> Void)] = []

    private let diffQueue = DispatchQueue(
        label: "com.sdd.worldmodel.diff",
        qos: .userInteractive
    )

    // MARK: - Init

    public init() {}

    // MARK: - WorldModelProtocol: apply

    public func apply(event: AXEvent) {
        diffQueue.async { [weak self] in
            guard let self else { return }
            self._apply(event: event)
        }
    }

    private func _apply(event: AXEvent) {
        var added: [UIElement] = []
        var updated: [UIElement] = []
        var removed: [UIElementID] = []

        switch event.notification {

        case .focusedUIElementChanged:
            let newID = UIElementID(event.elementRef)
            focusedID = newID
            liveRefs[newID] = event.elementRef
            // Hydrate the newly focused element if we haven't seen it
            if elements[newID] == nil {
                if let el = hydrate(event.elementRef, pid: pidOf(event.elementRef)) {
                    elements[newID] = el
                    added.append(el)
                }
            } else if var el = elements[newID] {
                el.state.formUnion(.focused)
                elements[newID] = el
                updated.append(el)
            }
            // Clear focus flag from previous element
            for id in elements.keys where id != newID {
                if elements[id]?.state.contains(.focused) == true {
                    elements[id]?.state.remove(.focused)
                    if let el = elements[id] { updated.append(el) }
                }
            }

        case .windowCreated:
            let pid = pidOf(event.elementRef)
            trackedPIDs.insert(pid)
            // Walk the AX tree rooted at this window and insert all children
            let newElements = walkTree(event.elementRef, pid: pid)
            for el in newElements where elements[el.id] == nil {
                elements[el.id] = el
                added.append(el)
            }

        case .uiElementDestroyed:
            let deadID = UIElementID(event.elementRef)
            liveRefs.removeValue(forKey: deadID)
            if elements.removeValue(forKey: deadID) != nil {
                removed.append(deadID)
                if focusedID == deadID { focusedID = nil }
            }

        case .valueChanged, .selectedTextChanged:
            let changedID = UIElementID(event.elementRef)
            let pid = pidOf(event.elementRef)
            if let fresh = hydrate(event.elementRef, pid: pid) {
                elements[changedID] = fresh
                updated.append(fresh)
            }

        case .windowMiniaturized:
            // Mark all elements owned by this window's PID as non-visible
            let pid = pidOf(event.elementRef)
            for id in elements.keys where elements[id]?.ownerPID == pid {
                elements[id]?.state.remove(.visible)
            }
        }

        let diff = WorldModelDiff(
            added: added,
            updated: updated,
            removed: removed,
            triggeringEvent: event,
            focusedElementID: focusedID
        )

        guard !diff.isEmpty else { return }

        for sub in subscribers {
            sub.handler(diff)
        }
    }

    // MARK: - WorldModelProtocol: subscribe

    @discardableResult
    public func subscribe(handler: @escaping @Sendable (WorldModelDiff) -> Void) -> SubscriptionToken {
        let id = UUID()
        diffQueue.async { [weak self] in
            self?.subscribers.append((id: id, handler: handler))
        }
        return SubscriptionToken { [weak self] in
            self?.diffQueue.async {
                self?.subscribers.removeAll { $0.id == id }
            }
        }
    }

    // MARK: - WorldModelProtocol: queries

    public var currentSnapshot: WorldModelSnapshot {
        diffQueue.sync {
            WorldModelSnapshot(
                elements: elements,
                focusedElementID: focusedID,
                trackedApps: trackedPIDs,
                capturedAt: .now
            )
        }
    }

    public func element(for id: UIElementID) -> UIElement? {
        diffQueue.sync { elements[id] }
    }

    public var focusedElement: UIElement? {
        diffQueue.sync { focusedID.flatMap { elements[$0] } }
    }

    // MARK: - Proactive scan

    /// Walk the AX tree for a running application without waiting for events.
    ///
    /// AX events only fire on *changes*. At startup, apps are already running and
    /// their windows already exist — no `windowCreated` events will fire unless
    /// something changes. This method reads the current state eagerly.
    ///
    /// Safe to call from any thread; dispatches internally to `diffQueue`.
    public func scanApp(pid: pid_t) {
        diffQueue.async { [weak self] in
            guard let self else { return }
            self._scanApp(pid: pid)
        }
    }

    /// Wait for all pending `scanApp` dispatches to complete, then return.
    /// Call this after a series of `scanApp` calls to know when the model is ready.
    public func drainScanQueue() {
        diffQueue.sync { /* barrier — all prior async work is done */ }
    }

    /// Query the system-wide AX API for the globally focused element and update focusedID.
    /// Call this after `drainScanQueue()` so the element is already in the elements table.
    public func captureFocus() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let fr = focusedRef else { return }
        let axFr = fr as! AXUIElement
        let fid = UIElementID(axFr)
        diffQueue.async { [weak self] in
            guard let self else { return }
            self.focusedID = fid
            self.liveRefs[fid] = axFr
            // Hydrate if not yet in the table
            if self.elements[fid] == nil {
                var pid: pid_t = 0
                AXUIElementGetPid(axFr, &pid)
                if let el = self.hydrate(axFr, pid: pid) {
                    self.elements[fid] = el
                }
            }
        }
        diffQueue.sync {} // drain
    }

    private func _scanApp(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)

        // Enumerate windows
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty
        else { return }

        var added: [UIElement] = []
        for window in windows {
            let newEls = walkTree(window, pid: pid)
            for el in newEls where elements[el.id] == nil {
                elements[el.id] = el
                added.append(el)
            }
        }
        trackedPIDs.insert(pid)

        guard !added.isEmpty else { return }

        // Emit a synthetic diff so subscribers (e.g. daemon logger) are notified
        let event = AXEvent(notification: .windowCreated, elementRef: appElement)
        let diff = WorldModelDiff(
            added: added, updated: [], removed: [],
            triggeringEvent: event,
            focusedElementID: focusedID
        )
        for sub in subscribers { sub.handler(diff) }
    }

    // MARK: - FBSnapshot builder (for FastBrain)

    /// Converts the current snapshot into the FBSnapshot shape FastBrain expects.
    /// Called from the diff subscription handler in main.swift.
    public func makeFBSnapshot() -> FBSnapshot {
        let snap = currentSnapshot
        var pid: pid_t = 0
        if let fid = snap.focusedElementID, let el = snap.elements[fid] {
            pid = el.ownerPID
        } else {
            pid = snap.trackedApps.first ?? 0
        }

        let focusedEl: FBElement? = snap.focusedElementID.flatMap { snap.elements[$0] }.map(toFBElement)
        let allElements = snap.elements.values
            .filter { $0.ownerPID == pid || pid == 0 }
            .map(toFBElement)

        return FBSnapshot(
            timestamp: snap.capturedAt,
            appContext: FBAppContext(
                bundleID: bundleIDForPID(pid),
                focusedElement: focusedEl,
                viewportFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            elements: allElements
        )
    }

    // MARK: - AX Tree Hydration

    private func hydrate(_ ref: AXUIElement, pid: pid_t) -> UIElement? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXRoleAttribute as CFString, &roleRef) == .success,
              let roleStr = roleRef as? String
        else { return nil }

        var labelRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXTitleAttribute as CFString, &labelRef)
        if labelRef == nil {
            AXUIElementCopyAttributeValue(ref, kAXDescriptionAttribute as CFString, &labelRef)
        }
        let label = labelRef as? String

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &valueRef)
        let value = valueRef as? String

        var state: UIElementState = []
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(ref, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let enabled = enabledRef as? Bool, enabled { state.insert(.enabled) }

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(ref, kAXFocusedAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef as? Bool, focused { state.insert(.focused) }

        state.insert(.visible)

        let frame = frameOf(ref)
        let childIDs = childIDsOf(ref)

        var parentID: UIElementID? = nil
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(ref, kAXParentAttribute as CFString, &parentRef) == .success,
           let pr = parentRef { parentID = UIElementID(pr as! AXUIElement) }

        return UIElement(
            id: UIElementID(ref),
            role: UIElementRole(axRole: roleStr),
            label: label,
            value: value,
            state: state,
            frame: frame,
            childIDs: childIDs,
            parentID: parentID,
            ownerPID: pid
        )
    }

    private func walkTree(_ root: AXUIElement, pid: pid_t, maxDepth: Int = 8) -> [UIElement] {
        var result: [UIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while !stack.isEmpty {
            let (ref, depth) = stack.removeLast()
            let id = UIElementID(ref)
            liveRefs[id] = ref   // retain live handle for dispatch
            if let el = hydrate(ref, pid: pid) { result.append(el) }
            guard depth < maxDepth else { continue }
            var childRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(ref, kAXChildrenAttribute as CFString, &childRef) == .success,
               let children = childRef as? [AXUIElement] {
                for child in children { stack.append((child, depth + 1)) }
            }
        }
        return result
    }

    /// Returns the screen frame of the first element whose label matches.
    /// Does NOT require liveRefs — uses the stored UIElement.frame directly.
    /// Use this for coordinate-based clicking, which is stable across rescans.
    ///
    /// Match rules (in priority order):
    ///   1. Exact match (case-insensitive)
    ///   2. Element label contains the search target (substring, min 4 chars)
    /// The reverse (target contains element label) is intentionally NOT checked
    /// because it false-matches elements with short labels against any selector.
    public func frameForElement(label: String) -> UIElementFrame? {
        diffQueue.sync {
            let target = label.lowercased()
            guard !target.isEmpty else { return nil }

            // Pass 1: exact match (case-insensitive)
            if let exact = elements.values.first(where: {
                ($0.label ?? "").lowercased() == target
            }) {
                return exact.frame
            }

            // Pass 2: element label contains the target (min 4 chars to avoid noise)
            if target.count >= 4 {
                if let substr = elements.values.first(where: {
                    let elLabel = ($0.label ?? "").lowercased()
                    return !elLabel.isEmpty && elLabel.contains(target)
                }) {
                    return substr.frame
                }
            }

            return nil
        }
    }

    /// Returns the live AXUIElement for the first element matching label + role.
    /// Called by TaskOrchestrator when dispatching actions.
    public func axElement(for label: String, role: String) -> AXUIElement? {
        diffQueue.sync {
            // Find UIElementID matching label + role (role check is optional if role is empty)
            let match = elements.first { _, el in
                (el.label ?? "").lowercased() == label.lowercased() &&
                (role.isEmpty || axRoleString(el.role).lowercased() == role.lowercased() ||
                 el.role.rawValue.lowercased() == role.lowercased())
            }
            guard let id = match?.key else { return nil }
            return liveRefs[id]
        }
    }

    /// Returns the live AXUIElement for a known UIElementID.
    public func axElement(for id: UIElementID) -> AXUIElement? {
        diffQueue.sync { liveRefs[id] }
    }

    private func childIDsOf(_ ref: AXUIElement) -> [UIElementID] {
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement]
        else { return [] }
        return children.map { UIElementID($0) }
    }

    private func frameOf(_ ref: AXUIElement) -> UIElementFrame {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if AXUIElementCopyAttributeValue(ref, kAXPositionAttribute as CFString, &posRef) == .success,
           let posVal = posRef {
            var pt = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
            x = pt.x; y = pt.y
        }
        if AXUIElementCopyAttributeValue(ref, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeVal = sizeRef {
            var sz = CGSize.zero
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
            w = sz.width; h = sz.height
        }
        return UIElementFrame(x: x, y: y, width: w, height: h)
    }

    private func pidOf(_ ref: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(ref, &pid)
        return pid
    }

    private func bundleIDForPID(_ pid: pid_t) -> String {
        guard pid != 0,
              let app = NSRunningApplication(processIdentifier: pid),
              let bid = app.bundleIdentifier
        else { return "unknown" }
        return bid
    }

    private func toFBElement(_ el: UIElement) -> FBElement {
        FBElement(
            axHandle: nil, // live AXUIElement not stored; use element ID for dispatch
            role: axRoleString(el.role),
            label: el.label ?? "",
            value: el.value,
            isFocused: el.state.contains(.focused),
            isEnabled: el.state.contains(.enabled),
            isVisible: el.state.contains(.visible),
            frame: CGRect(x: el.frame.x, y: el.frame.y, width: el.frame.width, height: el.frame.height)
        )
    }

    private func axRoleString(_ role: UIElementRole) -> String {
        // Re-add AX prefix that UIElementRole.init(axRole:) strips
        let raw = role.rawValue
        let capitalized = raw.prefix(1).uppercased() + raw.dropFirst()
        return "AX" + capitalized
    }
}
