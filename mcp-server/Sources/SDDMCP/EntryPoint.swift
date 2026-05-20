import Foundation
import MCP
import Logging
import ServiceLifecycle

// Entry point
@main
struct EntryPoint {
    static func main() async throws {
        // Configure logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }
        
        let logger = Logger(label: "SDDMCP")
        logger.info("Starting SDD MCP Server (swift-computer-use)")
        logger.info("Server info: name=sdd, version=0.1.0")
        logger.info("Listening on http://localhost:7801")
        logger.info("Connecting to gRPC server at localhost:7800")
        
        // Create gRPC client
        let grpcClient = try SDDGRPCClient(
            host: "localhost",
            port: 7800,
            logger: logger
        )
        
        // Check gRPC connection
        let isConnected = await grpcClient.checkConnection()
        if isConnected {
            logger.info("Successfully connected to gRPC server at localhost:7800")
        } else {
            logger.warning("Could not connect to gRPC server at localhost:7800 - server will retry on requests")
        }
        
        // Create MCP server
        let mcpServer = SDDMCPServer(grpcClient: grpcClient, logger: logger)
        
        // Create HTTP transport for MCP (SSE enabled for streaming)
        let transport = HTTPClientTransport(
            endpoint: URL(string: "http://localhost:7801")!,
            streaming: true  // Enable SSE for world_model_stream resource
        )
        
        // Create service for lifecycle management
        let service = SDDMCPService(server: mcpServer, transport: transport, logger: logger)
        
        // Create service group with signal handling
        let serviceGroup = ServiceGroup(
            services: [service],
            configuration: .init(
                gracefulShutdownSignals: [.sigterm, .sigint]
            ),
            logger: logger
        )
        
        // Run the service group
        logger.info("SDD MCP Server ready")
        try await serviceGroup.run()
    }
}

/// Service wrapper for lifecycle management
struct SDDMCPService: Service {
    let server: SDDMCPServer
    let transport: Transport
    let logger: Logger
    
    func run() async throws {
        // Start the MCP server
        try await server.start(transport: transport)
        
        // Keep running until cancelled
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
    
    func shutdown() async throws {
        logger.info("Shutting down SDD MCP Server")
        await server.stop()
    }
}
