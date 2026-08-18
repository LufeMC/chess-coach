// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Database",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Database", targets: ["Database"])
    ],
    dependencies: [
        // Point-Free's SQLiteData: GRDB underneath, `@Table` macros for the
        // record types, and a CloudKit `SyncEngine` we switch on in a later
        // milestone. Pinned to 1.x — the sync engine's record format is only
        // stable within a major version.
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.10.0")
    ],
    targets: [
        .target(
            name: "Database",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data")
            ],
            path: "Sources/Database"
        ),
        .testTarget(
            name: "DatabaseTests",
            dependencies: ["Database"],
            path: "Tests/DatabaseTests"
        ),
    ]
)
