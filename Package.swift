// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Boty",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Boty"),
        .testTarget(name: "BotyTests", dependencies: ["Boty"]),
    ]
)
