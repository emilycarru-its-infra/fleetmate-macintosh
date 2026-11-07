// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TicketsMate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TicketsMateCore", targets: ["TicketsMateCore"]),
        .executable(name: "TicketsMate", targets: ["TicketsMate"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        // TeamDynamix client, settings, sign-in and ticket models.
        .target(
            name: "TicketsMateCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Alamofire", package: "Alamofire"),
            ],
            path: "Sources/TicketsMateCore"
        ),
        // The SwiftUI app. The same binary runs the background inbox helper.
        .executableTarget(
            name: "TicketsMate",
            dependencies: [
                "TicketsMateCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/TicketsMate",
            exclude: ["Info.plist", "TicketsMate.entitlements", "Assets"]
        ),
        .testTarget(
            name: "TicketsMateTests",
            dependencies: ["TicketsMateCore"],
            path: "Tests/TicketsMateTests"
        ),
    ]
)
