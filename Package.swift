// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SemanticDisplayDaemon",
    platforms: [
        .macOS(.v13)  // ScreenCaptureKit requires macOS 12.3+; 13 for stable AX APIs
    ],
    products: [
        .executable(name: "sdd", targets: ["SDD"]),
        .library(name: "SDDCore", targets: ["SDDCore"]),
    ],
    targets: [
        // MARK: - Daemon binary
        .executableTarget(
            name: "SDD",
            dependencies: ["SDDCore"],
            path: "Sources/SDD"
        ),

        // MARK: - Core library (AX layer, world model, action executor)
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

        // MARK: - Tests
        .testTarget(
            name: "SDDTests",
            dependencies: ["SDDCore"],
            path: "Tests/SDDTests"
        ),
    ]
)
