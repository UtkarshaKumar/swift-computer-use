// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SemanticDisplayDaemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SDDCore", targets: ["SDDCore"]),
        .executable(name: "sdd", targets: ["SDDCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "SDDCore",
            dependencies: []
        ),
        .executableTarget(
            name: "SDDCLI",
            dependencies: [
                "SDDCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),

    ]
)