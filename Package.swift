// swift-tools-version: 5.9
import PackageDescription

// ──────────────────────────────────────────────────────────────────
// Semantic Display Daemon — unified package manifest
//
// Targets produced by each agent (see GitHub Issues for authorship):
//   SDDCore        — core library: AX layer, world model, action executor, logging
//   SDD            — daemon binary: fast brain, capture, slow brain router
//   SDDGRPCServer  — gRPC control API server (port 7800, all 4 RPCs)
//   SDDCLI         — CLI client: sdd click/type/scroll/stream/status/log
//   SDDTests       — unit tests (AXObserver, ActionExecutor, FastBrain, ScreenCapture)
//   SDDWorldModel  — world model actor tests
//
// Separate packages (not in this manifest):
//   mcp-server/           — MCP wrapper over gRPC (Kimi issue-10)
//   Tests/EVALRunner/     — standalone EVAL harness (Minimax issue-8)
// ──────────────────────────────────────────────────────────────────

let package = Package(
    name: "SemanticDisplayDaemon",
    platforms: [
        .macOS(.v15)  // ScreenCaptureKit 2.0 + Swift 6 concurrency + stable AX APIs
    ],
    products: [
        .executable(name: "sdd-daemon", targets: ["SDD"]),
        .executable(name: "sdd-grpc",   targets: ["SDDGRPCServer"]),
        .executable(name: "sdd",        targets: ["SDDCLI"]),
        .library(name: "SDDCore",       targets: ["SDDCore"]),
    ],
    dependencies: [
        // grpc-swift-2.git is the canonical v2 repo (migrated from grpc-swift.git at 2.3.0)
        .package(url: "https://github.com/grpc/grpc-swift-2.git",            from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.6.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git",      from: "2.2.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git",          from: "1.25.0"),
    ],
    targets: [

        // MARK: - SDDCore (shared library)
        // AX layer, world model, action executor, logging
        // Used by both the daemon binary and test targets
        .target(
            name: "SDDCore",
            dependencies: [],
            path: "Sources/SDDCore",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),

        // MARK: - SDD daemon binary
        // Fast brain rule engine, ScreenCaptureKit capture, slow brain router
        // Depends on SDDCore for AX layer + action executor
        .executableTarget(
            name: "SDD",
            dependencies: ["SDDCore"],
            path: "Sources/SDD",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),

        // MARK: - SDDGRPCServer (gRPC control API)
        // Listens on 0.0.0.0:7800, plaintext HTTP/2
        // RPCs: GetElementTree, ExecuteAction, GetScreenshot, StreamWorldState
        .executableTarget(
            name: "SDDGRPCServer",
            dependencies: [
                "SDDCore",
                .product(name: "GRPCCore",              package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf",          package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf",         package: "swift-protobuf"),
            ],
            path: "Sources/SDDGRPCServer"
        ),

        // MARK: - SDDCLI (command-line client)
        // sdd click <id>, sdd type <id> <text>, sdd scroll <dir>,
        // sdd stream, sdd status, sdd log tail
        .executableTarget(
            name: "SDDCLI",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/SDDCLI"
        ),

        // MARK: - Tests
        .testTarget(
            name: "SDDTests",
            dependencies: ["SDDCore"],
            path: "Tests/SDDTests"
        ),
        .testTarget(
            name: "SDDWorldModelTests",
            dependencies: ["SDDCore"],
            path: "Tests/SDD"
        ),
    ]
)
