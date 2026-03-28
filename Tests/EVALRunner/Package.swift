// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EVALRunner",
    platforms: [.macOS(.v15)],
    dependencies: [
        // SDDCore provides LearnedRule, LearnedRulesStore, TaskIntentType
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "EVALRunner",
            dependencies: [
                .product(name: "SDDCore", package: "SemanticDisplayDaemon"),
            ],
            path: "Sources"
        )
    ]
)
