import Foundation
import ApplicationServices

/// Represents the execution path used for an action
public enum ActionExecutionPath {
    /// Primary path: AXUIElement actions (AXPress, AXSetValue, etc.)
    case accessibility
    
    /// Secondary path: CGEvent keyboard injection
    case keyboardInjection
    
    /// Tertiary path: Coordinate-based mouse events (canvas regions only)
    case canvasRegion
    
    /// Browser path: Playwright/CDP bridge
    case playwright
    
    /// File dialog path: AX-based navigation
    case fileDialog
}

/// Result of an action execution
public struct ActionResult {
    public let success: Bool
    public let latencyMs: Int
    public let error: String?
    
    public init(success: Bool, latencyMs: Int, error: String? = nil) {
        self.success = success
        self.latencyMs = latencyMs
        self.error = error
    }
}

/// Executes UI actions and logs results
public actor ActionExecutor {
    public static let shared = ActionExecutor()
    
    private let logger: ActionLogger
    
    public init(logger: ActionLogger = .shared) {
        self.logger = logger
    }
    
    /// Execute a click action on an element
    public func click(
        elementId: String?,
        elementLabel: String?,
        element: AXUIElement?,
        path: ActionExecutionPath = .accessibility
    ) async -> ActionResult {
        let startTime = Date()
        
        do {
            let result = try await performClick(element: element, path: path)
            await logAction(
                actionType: "click",
                elementId: elementId,
                elementLabel: elementLabel,
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        } catch {
            let result = ActionResult(
                success: false,
                latencyMs: Int(Date().timeIntervalSince(startTime) * 1000),
                error: error.localizedDescription
            )
            await logAction(
                actionType: "click",
                elementId: elementId,
                elementLabel: elementLabel,
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        }
    }
    
    /// Execute a type action on an element
    public func type(
        elementId: String?,
        elementLabel: String?,
        element: AXUIElement?,
        value: String,
        path: ActionExecutionPath = .accessibility
    ) async -> ActionResult {
        let startTime = Date()
        
        do {
            let result = try await performType(element: element, value: value, path: path)
            await logAction(
                actionType: "type",
                elementId: elementId,
                elementLabel: elementLabel,
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        } catch {
            let result = ActionResult(
                success: false,
                latencyMs: Int(Date().timeIntervalSince(startTime) * 1000),
                error: error.localizedDescription
            )
            await logAction(
                actionType: "type",
                elementId: elementId,
                elementLabel: elementLabel,
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        }
    }
    
    /// Execute a scroll action
    public func scroll(
        elementId: String?,
        elementLabel: String?,
        element: AXUIElement?,
        direction: ScrollDirection,
        path: ActionExecutionPath = .accessibility
    ) async -> ActionResult {
        let startTime = Date()
        
        do {
            let result = try await performScroll(element: element, direction: direction, path: path)
            await logAction(
                actionType: "scroll_\(direction.rawValue)",
                elementId: elementId,
                elementLabel: elementLabel,
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        } catch {
            let result = ActionResult(
                success: false,
                latencyMs: Int(Date().timeIntervalSince(startTime) * 1000),
                error: error.localizedDescription
            )
            await logAction(
                actionType: "scroll_\(direction.rawValue)",
                elementId: elementId,
                elementLabel: elementLabel,
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        }
    }
    
    /// Execute a key combo action
    public func keyCombo(
        keys: [String],
        path: ActionExecutionPath = .keyboardInjection
    ) async -> ActionResult {
        let startTime = Date()
        
        do {
            let result = try await performKeyCombo(keys: keys)
            await logAction(
                actionType: "key_combo",
                elementId: nil,
                elementLabel: keys.joined(separator: "+"),
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        } catch {
            let result = ActionResult(
                success: false,
                latencyMs: Int(Date().timeIntervalSince(startTime) * 1000),
                error: error.localizedDescription
            )
            await logAction(
                actionType: "key_combo",
                elementId: nil,
                elementLabel: keys.joined(separator: "+"),
                result: result,
                path: path,
                startTime: startTime
            )
            return result
        }
    }
    
    // MARK: - Private Methods
    
    private func logAction(
        actionType: String,
        elementId: String?,
        elementLabel: String?,
        result: ActionResult,
        path: ActionExecutionPath,
        startTime: Date
    ) async {
        let logEntry = ActionLog(
            timestamp: Date(),
            actionType: actionType,
            elementId: elementId,
            elementLabel: elementLabel,
            success: result.success,
            latencyMs: result.latencyMs,
            usedCoordinates: path == .canvasRegion,
            error: result.error
        )
        
        do {
            try await logger.log(logEntry)
        } catch {
            // Log to stderr if we can't write to the log file
            print("Failed to write action log: \(error)", to: &stderr)
        }
    }
    
    private func performClick(element: AXUIElement?, path: ActionExecutionPath) async throws -> ActionResult {
        let startTime = Date()
        
        // Simulate verify signal (in real implementation, this would wait for world model update)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms simulated verify
        
        // In real implementation:
        // 1. Execute the action based on path
        // 2. Wait for verify signal from world model
        // 3. Return result
        
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        return ActionResult(success: true, latencyMs: latency)
    }
    
    private func performType(element: AXUIElement?, value: String, path: ActionExecutionPath) async throws -> ActionResult {
        let startTime = Date()
        
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms simulated verify
        
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        return ActionResult(success: true, latencyMs: latency)
    }
    
    private func performScroll(element: AXUIElement?, direction: ScrollDirection, path: ActionExecutionPath) async throws -> ActionResult {
        let startTime = Date()
        
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms simulated verify
        
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        return ActionResult(success: true, latencyMs: latency)
    }
    
    private func performKeyCombo(keys: [String]) async throws -> ActionResult {
        let startTime = Date()
        
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms simulated verify
        
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        return ActionResult(success: true, latencyMs: latency)
    }
}

public enum ScrollDirection: String {
    case up
    case down
    case left
    case right
}

// Helper for printing to stderr
fileprivate var stderr = FileHandle.standardError

fileprivate extension FileHandle {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        self.write(data)
    }
}

fileprivate func print(_ items: Any..., to: inout FileHandle, separator: String = " ", terminator: String = "\n") {
    let output = items.map { "\($0)" }.joined(separator: separator) + terminator
    to.write(output)
}