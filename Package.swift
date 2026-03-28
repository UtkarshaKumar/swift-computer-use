// swift-tools-version:6.0
import PackageDescription

// grpc-swift-2.git is the canonical v2 repo (migrated from grpc-swift.git at 2.3.0).
// grpc-swift-nio-transport and grpc-swift-protobuf 2.x both reference grpc-swift-2.git;
// using grpc-swift.git (old URL) alongside them causes duplicate-target errors in SPM.
let package = Package(
    name: "SDD",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.6.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.2.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.25.0"),
    ],
    targets: [
        .executableTarget(
            name: "SDD",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources"
        )
    ]
)
