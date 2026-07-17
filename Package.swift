// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lifsaver",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "LifsaverCore"),
        .executableTarget(
            name: "lifsaver",
            dependencies: [
                "LifsaverCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "LifsaverApp",
            dependencies: ["LifsaverCore"]
        ),
        .testTarget(
            name: "LifsaverCoreTests",
            dependencies: ["LifsaverCore"]
        ),
        .testTarget(
            name: "LifsaverCLITests",
            dependencies: ["lifsaver"]
        ),
    ]
)
