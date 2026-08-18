// swift-tools-version: 6.0

import PackageDescription

// TrainingCore is the coaching brain: spaced repetition, card policy, ratings,
// the curriculum ladder, and weekly-focus selection.
//
// It deliberately has NO dependencies — not even ChessKit. Everything it needs
// arrives as plain value types (a FEN string, a theme name, an expected-points
// delta), so every rule in here is exercisable from literals in a unit test
// with no database, no engine, and no board. The app layer does the wiring.
//
// The practical consequence: where this package needs a domain vocabulary that
// lives elsewhere (cause tags, puzzle themes), it models it as a `String`-backed
// value rather than importing the owning module. That also matches how the
// Database package stores those columns, so the bridge is a plain `String`.
let package = Package(
    name: "TrainingCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "TrainingCore", targets: ["TrainingCore"])
    ],
    targets: [
        .target(
            name: "TrainingCore",
            path: "Sources/TrainingCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TrainingCoreTests",
            dependencies: ["TrainingCore"],
            path: "Tests/TrainingCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
