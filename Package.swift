// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexMonitor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "CodexMonitor", targets: ["CodexMonitor"]),
        .executable(name: "CodexMonitorHook", targets: ["CodexMonitorHook"]),
    ],
    targets: [
        .target(name: "Reorderable", path: "Vendor/Reorderable", exclude: ["LICENSE"]),
        .target(name: "CodexMonitorHookSupport"),
        .executableTarget(
            name: "CodexMonitorHook",
            dependencies: ["CodexMonitorHookSupport"]
        ),
        .executableTarget(
            name: "CodexMonitor",
            dependencies: ["Reorderable", "CodexMonitorHookSupport"],
            resources: [.copy("Resources/CatFrames")]
        ),
        .testTarget(
            name: "CodexMonitorHookSupportTests",
            dependencies: ["CodexMonitorHookSupport"]
        ),
        .testTarget(name: "CodexMonitorTests", dependencies: ["CodexMonitor"]),
    ]
)
