// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SturtBar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SturtBarCore", targets: ["SturtBarCore"]),
        .executable(name: "SturtBar", targets: ["SturtBar"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SturtBarCore"),
        .executableTarget(
            name: "SturtBar",
            dependencies: ["SturtBarCore"]),
        .testTarget(
            name: "SturtBarTests",
            dependencies: ["SturtBar", "SturtBarCore"],
            path: "Tests/SturtBarTests",
            resources: [.copy("Fixtures")]),
    ])
