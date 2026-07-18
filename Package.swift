// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lifsaver",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LifsaverCore"),
        .executableTarget(
            name: "LifsaverApp",
            dependencies: ["LifsaverCore"]
        ),
        .testTarget(
            name: "LifsaverCoreTests",
            dependencies: ["LifsaverCore"]
        ),
    ]
)
