// swift-tools-version: 6.0

import PackageDescription

// AnalysisKit is the pure analysis layer: value types in, value types out.
// It deliberately depends only on ChessKit (board/rules) and EngineKit (score
// and PV value types) — no database, no UI, no I/O — so every detector can be
// exercised from a FEN plus a canned engine result in a unit test.
let package = Package(
    name: "AnalysisKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "AnalysisKit", targets: ["AnalysisKit"])
    ],
    dependencies: [
        .package(path: "../ChessKit"),
        .package(path: "../EngineKit")
    ],
    targets: [
        .target(
            name: "AnalysisKit",
            dependencies: [
                .product(name: "ChessKit", package: "ChessKit"),
                .product(name: "EngineKit", package: "EngineKit")
            ],
            path: "Sources/AnalysisKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AnalysisKitTests",
            dependencies: ["AnalysisKit"],
            path: "Tests/AnalysisKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
