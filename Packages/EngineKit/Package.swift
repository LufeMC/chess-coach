// swift-tools-version: 6.0
import PackageDescription

// Stockfish sources compiled into the app process. `main.cpp` is excluded — the
// UCI loop is driven by SFBridge instead of a process entry point.
let stockfishSources = [
    "benchmark.cpp",
    "bitboard.cpp",
    "engine.cpp",
    "evaluate.cpp",
    "memory.cpp",
    "misc.cpp",
    "movegen.cpp",
    "movepick.cpp",
    "position.cpp",
    "score.cpp",
    "search.cpp",
    "thread.cpp",
    "timeman.cpp",
    "tt.cpp",
    "tune.cpp",
    "uci.cpp",
    "ucioption.cpp",
    "nnue/features/half_ka_v2_hm.cpp",
    "nnue/network.cpp",
    "nnue/nnue_accumulator.cpp",
    "nnue/nnue_misc.cpp",
    "syzygy/tbprobe.cpp",
].map { "Stockfish/src/\($0)" }

// armv8.2+dotprod is a no-op on macOS and the arm64 simulator (both already
// enable it) but is REQUIRED on iOS device targets, where clang's default
// baseline omits dotprod. Without it the NNUE int8 path falls back to scalar
// code and loses a large multiple of NPS.
let armFlags: [String] = ["-march=armv8.2-a+dotprod", "-O3", "-fno-strict-aliasing"]

let package = Package(
    name: "EngineKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EngineKit", targets: ["EngineKit"])
    ],
    targets: [
        .target(
            name: "CStockfish",
            path: "Sources/CStockfish",
            sources: ["SFBridge.mm"] + stockfishSources,
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("Stockfish/src"),
                .define("NDEBUG"),
                .define("IS_64BIT"),
                .define("USE_POPCNT"),
                .define("USE_NEON", to: "8"),
                .define("USE_NEON_DOTPROD"),
                // Nets are loaded from disk via setoption EvalFile/EvalFileSmall.
                // Embedding them would add ~73MB to the binary.
                .define("NNUE_EMBEDDING_OFF"),
                .unsafeFlags(armFlags),
            ]
        ),
        .target(
            name: "EngineKit",
            dependencies: ["CStockfish"],
            path: "Sources/EngineKit"
        ),
        .executableTarget(
            name: "enginediag",
            dependencies: ["EngineKit"],
            path: "Sources/enginediag"
        ),
        .testTarget(
            name: "EngineKitTests",
            dependencies: ["EngineKit"],
            path: "Tests/EngineKitTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
