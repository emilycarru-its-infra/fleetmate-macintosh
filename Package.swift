// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FleetMate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FleetMateCore", targets: ["FleetMateCore"]),
        .executable(name: "fleetmate", targets: ["FleetMate"]),
        .executable(name: "FleetMateApp", targets: ["FleetMateApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/onevcat/Rainbow.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/Kitura/BlueSocket.git", from: "2.0.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        // Shared library with services, models, and config
        .target(
            name: "FleetMateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Alamofire", package: "Alamofire"),
            ],
            path: "Sources/FleetMateCore"
        ),
        // CLI executable
        .executableTarget(
            name: "FleetMate",
            dependencies: [
                "FleetMateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "Socket", package: "BlueSocket"),
            ],
            path: "Sources/FleetMate"
        ),
        // SwiftUI App
        .executableTarget(
            name: "FleetMateApp",
            dependencies: [
                "FleetMateCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/FleetMateApp"
        ),
    ]
)
