// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryKeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BatteryCore",
            path: "Sources/BatteryCore"
        ),
        .executableTarget(
            name: "battery-keeper-helper",
            dependencies: ["BatteryCore"],
            path: "Sources/Helper"
        ),
        .executableTarget(
            name: "BatteryKeeper",
            dependencies: ["BatteryCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "BatteryCoreTests",
            dependencies: ["BatteryCore"],
            path: "Tests/BatteryCoreTests"
        ),
    ]
)
