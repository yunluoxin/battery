// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryGUI",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BatteryCore",
            path: "Sources/BatteryCore"
        ),
        .executableTarget(
            name: "battery-gui-helper",
            dependencies: ["BatteryCore"],
            path: "Sources/Helper"
        ),
        .executableTarget(
            name: "BatteryGUI",
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
