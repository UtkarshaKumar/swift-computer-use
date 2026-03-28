// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EVALRunner",
    targets: [
        .executableTarget(
            name: "EVALRunner",
            dependencies: [],
            path: "Sources"
        )
    ]
)