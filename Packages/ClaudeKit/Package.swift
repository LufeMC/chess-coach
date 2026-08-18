// swift-tools-version: 6.0

import PackageDescription

// ClaudeKit is the app's entire relationship with the Anthropic Messages API:
// a hand-rolled URLSession client, the coaching request/response contract, and
// the verification layer that refuses to show the student a move the engine
// never produced.
//
// There is deliberately no third-party HTTP or SDK dependency. The community
// Swift SDKs lag the API (no `output_config`, no `stop_details`, no cache
// breakpoints on system blocks), and the surface we need is one endpoint.
//
// ChessKit is a dependency because verification is not string matching: to
// prove a quoted SAN matches its UCI we have to replay the line on a real
// board.
let package = Package(
    name: "ClaudeKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "ClaudeKit", targets: ["ClaudeKit"])
    ],
    dependencies: [
        .package(path: "../ChessKit")
    ],
    targets: [
        .target(
            name: "ClaudeKit",
            dependencies: [
                .product(name: "ChessKit", package: "ChessKit")
            ],
            path: "Sources/ClaudeKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ClaudeKitTests",
            dependencies: ["ClaudeKit"],
            path: "Tests/ClaudeKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
