// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FLXBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FLXBridge", targets: ["FLXBridgeApp"]),
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
    ],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "FLXBridgeApp", dependencies: ["BridgeCore"]),
        .executableTarget(name: "BridgeChecks", dependencies: ["BridgeCore"]),
    ]
)
