import Foundation
import MCP
import Logging

/// MCP Server implementation for the Semantic Display Daemon
public actor SDDMCPServer {
    private let server: Server
    private let grpcClient: SDDGRPCClient
    private let logger: Logger
    private var isRunning: Bool = false
    
    public init(grpcClient: SDDGRPCClient, logger: Logger = Logger(label: "SDDMCPServer")) {
        self.grpcClient = grpcClient
        self.logger = logger
        
        // Create the MCP server with capabilities
        self.server = Server(
            name: "sdd",
            version: "0.1.0",
            capabilities: .init(
                logging: .init(),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true)
            )
        )
        
        logger.info("Initialized SDD MCP Server (name=sdd, version=0.1.0)")
    }
    
    /// Register all MCP handlers
    private func registerHandlers() async {
        // MARK: - Tool Handlers
        
        // List available tools
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            self?.logger.debug("Listing available tools")
            
            let tools: [Tool] = [
                Tool(
                    name: "get_world_state",
                    description: "Get the current semantic world state of the screen including all UI elements",
                    inputSchema: .object([:])
                ),
                Tool(
                    name: "click_element",
                    description: "Click a UI element by its label",
                    inputSchema: .object([
                        "properties": .object([
                            "label": .object([
                                "type": .string("string"),
                                "description": .string("The label/text of the element to click")
                            ])
                        ]),
                        "required": .array([.string("label")])
                    ])
                ),
                Tool(
                    name: "type_text",
                    description: "Type text into a field",
                    inputSchema: .object([
                        "properties": .object([
                            "field": .object([
                                "type": .string("string"),
                                "description": .string("The label or identifier of the field")
                            ]),
                            "value": .object([
                                "type": .string("string"),
                                "description": .string("The text to type")
                            ])
                        ]),
                        "required": .array([.string("field"), .string("value")])
                    ])
                ),
                Tool(
                    name: "scroll",
                    description: "Scroll in a direction",
                    inputSchema: .object([
                        "properties": .object([
                            "direction": .object([
                                "type": .string("string"),
                                "description": .string("Direction to scroll: up, down, left, right")
                            ]),
                            "amount": .object([
                                "type": .string("integer"),
                                "description": .string("Amount to scroll in pixels")
                            ])
                        ]),
                        "required": .array([.string("direction"), .string("amount")])
                    ])
                ),
                Tool(
                    name: "get_screenshot",
                    description: "Get a screenshot of the screen or a specific region",
                    inputSchema: .object([
                        "properties": .object([
                            "region": .object([
                                "type": .string("string"),
                                "description": .string("Optional region identifier (e.g., 'active_window', 'full_screen', or element ID)")
                            ])
                        ])
                    ])
                )
            ]
            
            return .init(tools: tools)
        }
        
        // Handle tool calls
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return .init(content: [.text("Server not available")], isError: true)
            }
            
            await self.logger.info("Tool called: \(params.name)")
            
            do {
                switch params.name {
                case "get_world_state":
                    return try await self.handleGetWorldState()
                    
                case "click_element":
                    guard let label = params.arguments?["label"]?.stringValue else {
                        return .init(content: [.text("Missing required parameter: label")], isError: true)
                    }
                    return try await self.handleClickElement(label: label)
                    
                case "type_text":
                    guard let field = params.arguments?["field"]?.stringValue,
                          let value = params.arguments?["value"]?.stringValue else {
                        return .init(content: [.text("Missing required parameters: field and/or value")], isError: true)
                    }
                    return try await self.handleTypeText(field: field, value: value)
                    
                case "scroll":
                    guard let direction = params.arguments?["direction"]?.stringValue,
                          let amount = params.arguments?["amount"]?.intValue else {
                        return .init(content: [.text("Missing required parameters: direction and/or amount")], isError: true)
                    }
                    return try await self.handleScroll(direction: direction, amount: amount)
                    
                case "get_screenshot":
                    let region = params.arguments?["region"]?.stringValue
                    return try await self.handleGetScreenshot(region: region)
                    
                default:
                    return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
                }
            } catch {
                await self.logger.error("Tool execution failed: \(error)")
                return .init(content: [.text("Error: \(error.localizedDescription)")], isError: true)
            }
        }
        
        // MARK: - Resource Handlers
        
        // List available resources
        await server.withMethodHandler(ListResources.self) { [weak self] _ in
            self?.logger.debug("Listing available resources")
            
            let resources: [Resource] = [
                Resource(
                    name: "World Model Stream",
                    uri: "world_model_stream",
                    description: "Server-Sent Events stream of WorldModelDiffs representing real-time UI changes",
                    mimeType: "text/event-stream"
                )
            ]
            
            return .init(resources: resources)
        }
        
        // Read resource
        await server.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.invalidParams("Server not available")
            }
            
            await self.logger.info("Reading resource: \(params.uri)")
            
            switch params.uri {
            case "world_model_stream":
                // Return initial content with subscription info
                let content = """
                # World Model Stream
                
                This resource provides a Server-Sent Events (SSE) stream of WorldModelDiff objects.
                Subscribe to receive real-time updates about UI changes on the screen.
                
                Each event contains a JSON-encoded WorldModelDiff with:
                - timestamp: Unix timestamp of the change
                - added: Array of new UI elements
                - removed: Array of removed element IDs
                - modified: Array of modified UI elements
                """
                
                return .init(contents: [.text(content, uri: params.uri, mimeType: "text/markdown")])
                
            default:
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
        }
        
        // Subscribe to resource - using ResourceSubscribe
        await server.withMethodHandler(ResourceSubscribe.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.invalidParams("Server not available")
            }
            
            await self.logger.info("Subscribing to resource: \(params.uri)")
            
            if params.uri == "world_model_stream" {
                // Start streaming world model diffs
                Task {
                    await self.startWorldModelStream()
                }
                return .init()
            }
            
            throw MCPError.invalidParams("Cannot subscribe to resource: \(params.uri)")
        }
    }
    
    // MARK: - Tool Handlers
    
    private func handleGetWorldState() async throws -> CallTool.Result {
        logger.debug("Executing get_world_state")
        
        let worldModel = try await grpcClient.getWorldState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(worldModel)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        
        return .init(content: [.text(jsonString)], isError: false)
    }
    
    private func handleClickElement(label: String) async throws -> CallTool.Result {
        logger.debug("Executing click_element for: \(label)")
        
        let response = try await grpcClient.clickElement(label: label)
        let message = response.success 
            ? "Successfully clicked element '\(label)'"
            : "Failed to click element '\(label)': \(response.message ?? "Unknown error")"
        
        return .init(content: [.text(message)], isError: !response.success)
    }
    
    private func handleTypeText(field: String, value: String) async throws -> CallTool.Result {
        logger.debug("Executing type_text for field: \(field)")
        
        let response = try await grpcClient.typeText(field: field, value: value)
        let message = response.success
            ? "Successfully typed '\(value)' into field '\(field)'"
            : "Failed to type into field '\(field)': \(response.message ?? "Unknown error")"
        
        return .init(content: [.text(message)], isError: !response.success)
    }
    
    private func handleScroll(direction: String, amount: Int) async throws -> CallTool.Result {
        logger.debug("Executing scroll: \(direction) by \(amount)")
        
        let response = try await grpcClient.scroll(direction: direction, amount: amount)
        let message = response.success
            ? "Successfully scrolled \(direction) by \(amount) pixels"
            : "Failed to scroll: \(response.message ?? "Unknown error")"
        
        return .init(content: [.text(message)], isError: !response.success)
    }
    
    private func handleGetScreenshot(region: String?) async throws -> CallTool.Result {
        if let region = region {
            logger.debug("Executing get_screenshot for region: \(region)")
        } else {
            logger.debug("Executing get_screenshot")
        }
        
        let response = try await grpcClient.getScreenshot(region: region)
        
        if response.success, let data = response.data {
            // Return as image content
            return .init(content: [.image(data: data, mimeType: response.mimeType ?? "image/png")], isError: false)
        } else {
            let message = response.message ?? "Failed to capture screenshot"
            return .init(content: [.text(message)], isError: true)
        }
    }
    
    // MARK: - World Model Streaming
    
    private func startWorldModelStream() async {
        logger.info("Starting world model stream")
        
        let stream = await grpcClient.streamWorldModel()
        
        for await diff in stream {
            do {
                let encoder = JSONEncoder()
                let jsonData = try encoder.encode(diff)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                
                // Create SSE formatted message
                let sseMessage = "data: \(jsonString)\n\n"
                
                // In a real implementation, this would be sent via the transport
                // For HTTP transport with SSE, we'd write to the response stream
                logger.debug("World model diff: \(sseMessage.prefix(100))...")
                
                // Notify subscribers via MCP notification
                let notification = ResourceUpdatedNotification.message(
                    .init(uri: "world_model_stream")
                )
                try? await server.notify(notification)
                
            } catch {
                logger.error("Failed to encode world model diff: \(error)")
            }
        }
    }
    
    // MARK: - Server Lifecycle
    
    /// Start the MCP server on the specified transport
    public func start(transport: Transport) async throws {
        guard !isRunning else {
            logger.warning("Server is already running")
            return
        }
        
        logger.info("Starting SDD MCP Server")
        
        // Register all handlers
        await registerHandlers()
        
        // Start the server with initialization hook
        try await server.start(transport: transport) { [weak self] clientInfo, _ in
            self?.logger.info("Client connected: \(clientInfo.name) v\(clientInfo.version)")
        }
        
        isRunning = true
        logger.info("SDD MCP Server started successfully")
    }
    
    /// Stop the MCP server
    public func stop() async {
        guard isRunning else { return }
        
        logger.info("Stopping SDD MCP Server")
        await server.stop()
        isRunning = false
        
        // Close gRPC connection
        await grpcClient.close()
        
        logger.info("SDD MCP Server stopped")
    }
}
