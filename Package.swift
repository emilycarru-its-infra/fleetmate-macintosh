// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FleetMate",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "fleetmate", targets: ["FleetMate"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/onevcat/Rainbow.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/Kitura/BlueSocket.git", from: "2.0.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "FleetMate",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Socket", package: "BlueSocket"),
                .product(name: "Alamofire", package: "Alamofire"),
            ],
            path: "Sources/FleetMate"
        ),
        .testTarget(
            name: "FleetMateTests",
            dependencies: ["FleetMate"],
            path: "Tests/FleetMateTests"
        ),
    ]
)
