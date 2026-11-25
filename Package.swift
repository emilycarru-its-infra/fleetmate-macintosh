// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FleetMate",
    platforms: [
        .macOS("27.0")
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
        .package(url: "https://github.com/rodchristiansen/asbmutil.git", revision: "ed65f6b486f5f4c1382f620c40e7bff2fa493284"),
        // 1.12 added Metal shaders, which the Command Line Tools cannot compile.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", "1.11.2"..<"1.12.0"),
        // The agent terminal: lane sidebar, terminals, status feed and dock.
        // Pinned to a commit on AgentsMate's main; agentsmate-sync.yml moves
        // this revision whenever AgentsMate's main moves and FleetMate still
        // builds and tests.
        .package(url: "https://github.com/focusedsystems/agentsmate.git", revision: "12a4763136154a180f85e64a6d00073f3af5df22"),
        // The Reporting tab is the ReportMate app's own dashboard. Pinned to a
        // commit on ReportMate's main; reportmate-sync.yml moves this revision
        // whenever ReportMate's main moves and FleetMate still builds and tests.
        .package(url: "https://github.com/reportmate/reportmate-app-swift.git", revision: "3ccb28d0830f3e85b258d9a6fb07a35dd80371b5"),
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
                .product(name: "AgentsMate", package: "agentsmate"),
                .product(name: "AgentsMateStatus", package: "agentsmate"),
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
