// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwingReplayCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwingReplayCore",
            targets: ["SwingReplayCore"]
        )
    ],
    targets: [
        .target(
            name: "SwingReplayCore"
        ),
        .testTarget(
            name: "SwingReplayCoreTests",
            dependencies: ["SwingReplayCore"]
        )
    ]
)
