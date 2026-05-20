import Foundation
import GRPC
import NIO
import Logging

/// gRPC client for communicating with the swift-computer-use
public actor SDDGRPCClient {
    private let channel: GRPCChannel
    private let logger: Logger
    private var isConnected: Bool = false
    
    public init(host: String = "localhost", port: Int = 7800, logger: Logger = Logger(label: "SDDGRPCClient")) throws {
        self.logger = logger
        
        // Configure the gRPC channel
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        let configuration = ClientConnection.Configuration(
            target: .hostAndPort(host, port),
            eventLoopGroup: group
        )
        
        self.channel = ClientConnection(configuration: configuration)
        self.logger.info("Initialized gRPC client for \(host):\(port)")
    }
    
    /// Check if connected to the gRPC server
    public func checkConnection() async -> Bool {
        // Simple connectivity check
        return true // Assume connected for now
    }
    
    /// Get the current world state from the daemon
    public func getWorldState() async throws -> WorldModel {
        logger.debug("Fetching world state from gRPC server")
        
        // For now, return a mock world state
        // In production, this would make a gRPC call to the daemon
        return WorldModel(
            timestamp: Date().timeIntervalSince1970,
            elements: [
                UIElement(
                    id: "element-1",
                    role: "button",
                    label: "Submit",
                    enabled: true,
                    focused: false,
                    app: "TestApp"
                ),
                UIElement(
                    id: "element-2",
                    role: "textField",
                    label: "Username",
                    enabled: true,
                    focused: true,
                    app: "TestApp"
                )
            ],
            activeApp: "TestApp",
            focusedElement: "element-2"
        )
    }
    
    /// Click an element by label
    public func clickElement(label: String) async throws -> ActionResponse {
        logger.info("Clicking element with label: \(label)")
        
        // In production, this would make a gRPC call to the daemon
        return ActionResponse(success: true, message: "Clicked element '\(label)'")
    }
    
    /// Type text into a field
    public func typeText(field: String, value: String) async throws -> ActionResponse {
        logger.info("Typing into field: \(field)")
        
        // In production, this would make a gRPC call to the daemon
        return ActionResponse(success: true, message: "Typed '\(value)' into field '\(field)'")
    }
    
    /// Scroll in a direction
    public func scroll(direction: String, amount: Int) async throws -> ActionResponse {
        logger.info("Scrolling \(direction) by \(amount)")
        
        // In production, this would make a gRPC call to the daemon
        return ActionResponse(success: true, message: "Scrolled \(direction) by \(amount)")
    }
    
    /// Get a screenshot
    public func getScreenshot(region: String?) async throws -> ScreenshotResponse {
        if let region = region {
            logger.info("Getting screenshot for region: \(region)")
        } else {
            logger.info("Getting screenshot")
        }
        
        // In production, this would make a gRPC call to the daemon
        // Return a mock response
        return ScreenshotResponse(
            success: true,
            data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            mimeType: "image/png",
            message: "Screenshot captured"
        )
    }
    
    /// Stream world model diffs
    public func streamWorldModel() -> AsyncStream<WorldModelDiff> {
        logger.info("Starting world model stream")
        
        return AsyncStream { continuation in
            // In production, this would subscribe to a gRPC streaming endpoint
            // For now, yield mock diffs periodically
            Task {
                var iteration = 0
                while !Task.isCancelled {
                    let diff = WorldModelDiff(
                        timestamp: Date().timeIntervalSince1970,
                        added: [],
                        removed: [],
                        modified: [
                            UIElement(
                                id: "element-\(iteration)",
                                role: "button",
                                label: "Button \(iteration)",
                                enabled: true,
                                app: "TestApp"
                            )
                        ]
                    )
                    continuation.yield(diff)
                    iteration += 1
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
                continuation.finish()
            }
        }
    }
    
    /// Close the gRPC connection
    public func close() async {
        logger.info("Closing gRPC connection")
        try? await channel.close()
    }
}
