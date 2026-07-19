// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lifsaver",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LifsaverKit"),
        .executableTarget(
            name: "Lifsaver",
            dependencies: ["LifsaverKit"]
        ),
        .testTarget(
            name: "LifsaverKitTests",
            dependencies: ["LifsaverKit"]
        ),
    ]
)
