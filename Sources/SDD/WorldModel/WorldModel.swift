import Foundation

public protocol WorldModelProtocol: Actor {
    var currentState: [UIElement] { get }
    
    func update(with axEvent: AXEvent)
    func diff(since: Date) -> WorldModelDiff
    func element(byId: String) -> UIElement?
    var diffStream: AsyncStream<WorldModelDiff> { get }
}

public actor WorldModel: WorldModelProtocol {
    private var elements: [String: UIElement] = [:]
    private var updates: [UIElementUpdate] = []
    private var activeApp: String = ""
    private var focusedElementId: String?
    private var diffContinuation: AsyncStream<WorldModelDiff>.Continuation?
    private var diffStreamInstance: AsyncStream<WorldModelDiff>?
    
    public var currentState: [UIElement] {
        get { Array(elements.values) }
    }
    
    public init() {
        var continuation: AsyncStream<WorldModelDiff>.Continuation?
        diffStreamInstance = AsyncStream { cont in
            continuation = cont
        }
        diffContinuation = continuation
    }
    
    public func update(with axEvent: AXEvent) {
        let timestamp = Date()
        var changedElements: [UIElement] = []
        var removedIds: [String] = []
        
        switch axEvent {
        case .elementCreated(let element, let app):
            elements[element.id] = element
            updates.append(UIElementUpdate(element: element, timestamp: timestamp, operation: .insert))
            changedElements.append(element)
            activeApp = app
            
        case .elementUpdated(let element, let app):
            elements[element.id] = element
            updates.append(UIElementUpdate(element: element, timestamp: timestamp, operation: .update))
            changedElements.append(element)
            activeApp = app
            
        case .elementDestroyed(let id, let app):
            elements.removeValue(forKey: id)
            updates.append(UIElementUpdate(
                element: UIElement(
                    id: id,
                    role: "deleted",
                    frame: .zero
                ),
                timestamp: timestamp,
                operation: .delete
            ))
            removedIds.append(id)
            activeApp = app
            
        case .focusChanged(let elementId, let app):
            focusedElementId = elementId
            activeApp = app
            
        case .appChanged(let app):
            activeApp = app
            
        case .windowCreated(_, let app):
            activeApp = app
            
        case .windowDestroyed(_, let app):
            activeApp = app
        }
        
        trimHistory()
        
        let diff = WorldModelDiff(
            timestamp: timestamp,
            changedElements: changedElements,
            removedIds: removedIds,
            focusedElementId: focusedElementId,
            activeApp: activeApp
        )
        
        diffContinuation?.yield(diff)
    }
    
    public func diff(since: Date) -> WorldModelDiff {
        let relevantUpdates = updates.filter { $0.timestamp >= since }
        let changedElements = relevantUpdates
            .filter { $0.operation != .delete }
            .map { $0.element }
        let removedIds = relevantUpdates
            .filter { $0.operation == .delete }
            .map { $0.element.id }
        
        return WorldModelDiff(
            timestamp: Date(),
            changedElements: changedElements,
            removedIds: removedIds,
            focusedElementId: focusedElementId,
            activeApp: activeApp
        )
    }
    
    public func element(byId id: String) -> UIElement? {
        elements[id]
    }
    
    public var diffStream: AsyncStream<WorldModelDiff> {
        diffStreamInstance ?? AsyncStream { _ in }
    }
    
    private func trimHistory() {
        if updates.count > 100 {
            updates.removeFirst(updates.count - 100)
        }
    }
}
