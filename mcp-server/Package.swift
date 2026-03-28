// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SDDMCP",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "SDDMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
    ]
)
