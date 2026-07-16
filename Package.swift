// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexMonitor",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "CodexMonitor", targets: ["CodexMonitor"])],
    targets: [
        .target(name: "Reorderable", path: "Vendor/Reorderable", exclude: ["LICENSE"]),
        .executableTarget(
            name: "CodexMonitor",
            dependencies: ["Reorderable"]
        )
    ]
)
