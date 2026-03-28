// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SDD",
    platforms: [
        .macOS(.v14) // ScreenCaptureKit is 12.3+, but let's go with 14 for better Swift support
    ],
    products: [
        .library(name: "SDD", targets: ["SDD"]),
        .executable(name: "sdd", targets: ["SDDApp"])
    ],
    dependencies: [
        // Add dependencies if needed later (e.g., gRPC)
    ],
    targets: [
        .target(
            name: "SDD",
            dependencies: [],
            path: "Sources/SDD"
        ),
        .executableTarget(
            name: "SDDApp",
            dependencies: ["SDD"],
            path: "Sources/SDDApp"
        ),
        .testTarget(
            name: "SDDTests",
            dependencies: ["SDD"],
            path: "Tests/SDDTests"
        )
    ]
)
