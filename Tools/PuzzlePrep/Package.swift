// swift-tools-version: 6.0
import PackageDescription

// PuzzlePrep is a DEV-MACHINE-ONLY tool. It never ships inside the app: it runs
// once per Lichess puzzle-dump refresh to bake App/Resources/puzzles.sqlite,
// which is the artifact the app actually reads. That is why it targets macOS
// rather than iOS, and why it is free to shell out to `zstd`.
let package = Package(
    name: "PuzzlePrep",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "PuzzlePrep",
            path: "Sources/PuzzlePrep",
            // The system SQLite that ships with macOS. Deliberately NOT a
            // third-party SQLite package: this tool must stay dependency-free
            // so a fresh checkout can rebuild the DB with nothing but Xcode.
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
