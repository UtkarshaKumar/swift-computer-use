// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SDD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SDD",
            targets: ["SDD"]
        ),
    ],
    targets: [
        .target(
            name: "SDD",
            path: "Sources/SDD"
        ),
        .testTarget(
            name: "SDDTests",
            dependencies: ["SDD"],
            path: "Tests/SDD"
        ),
    ]
)
