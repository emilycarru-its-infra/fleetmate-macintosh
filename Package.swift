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
        // Apple School and Business Manager API client. Pinned to a revision
        // because asbmutil's date-stamped tags are not semantic versions.
        .package(url: "https://github.com/rodchristiansen/asbmutil.git", revision: "c079d4c4cf26b1e45bab8a1adf699b156e34f630"),
        // 1.12 added Metal shaders, which the Command Line Tools cannot compile.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", "1.11.2"..<"1.12.0"),
        // The Reporting tab is the ReportMate app's own dashboard. Pinned to a
        // commit on ReportMate's main; reportmate-sync.yml moves this revision
        // whenever ReportMate's main moves and FleetMate still builds and tests.
        .package(url: "https://github.com/reportmate/reportmate-app-swift.git", revision: "0f2f774ed86f441970e84f23aafba2c26d434941"),
    ],
    targets: [
        // Shared library with services, models, and config
        .target(
            name: "FleetMateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "ASBMUtilCore", package: "asbmutil"),
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
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ReportMateUI", package: "reportmate-app-swift"),
                .product(name: "ReportMateKit", package: "reportmate-app-swift"),
            ],
            path: "Sources/FleetMateApp"
        ),
        .testTarget(
            name: "FleetMateTests",
            dependencies: ["FleetMateCore"],
            path: "Tests/FleetMateTests"
        ),
    ]
)
