import ArgumentParser
import Foundation
import SDDCore

struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click on an element by label"
    )
    
    @Option(name: .long, help: "Element label to click")
    var label: String?
    
    @Option(name: .long, help: "Element ID to click")
    var id: String?
    
    @Flag(name: .long, help: "Use coordinate fallback (canvas region)")
    var useCoordinates: Bool = false
    
    func validate() throws {
        if label == nil && id == nil {
            throw ValidationError("Must specify either --label or --id")
        }
    }
    
    func run() async throws {
        // Initialize logger
        try await ActionLogger.shared.initialize()
        
        let executor = SDDExecutor.shared
        let path: ActionExecutionPath = useCoordinates ? .canvasRegion : .accessibility
        
        let result = await executor.click(
            elementId: id,
            elementLabel: label,
            element: nil,
            path: path
        )
        
        if result.success {
            print("Click executed successfully (\(result.latencyMs)ms)")
        } else {
            print("Click failed: \(result.error ?? "unknown error")")
            throw ExitCode.failure
        }
    }
}