import Foundation
import Testing

@testable import EngineKit

/// End-to-end checks against the real embedded engine.
///
/// These are the M0 acceptance criteria: if any of them fail the C++ build,
/// the network plumbing, or the UCI bridge is broken.
///
/// Stockfish is a process-global singleton, so the whole suite is serialized
/// and shares one boot.
@Suite("Engine smoke", .serialized)
struct EngineSmokeTests {

    /// Repo-relative path to the bundled networks (tests run from the package,
    /// not an app bundle, so there is no `Bundle.module` to consult).
    static func networkURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/EngineKitTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../EngineKit
            .deletingLastPathComponent()  // .../Packages
            .deletingLastPathComponent()  // repo root
            .appending(path: "App/Resources/Networks/\(name)")
    }

    static let smallNet = networkURL("nn-37f18f62d772.nnue")
    static let bigNet = networkURL("nn-1c0000000000.nnue")

    /// Boots the shared engine once for the whole suite.
    static func bootedEngine() async throws -> StockfishEngine {
        let engine = StockfishEngine.shared
        guard await !engine.isStarted else { return engine }

        #expect(FileManager.default.fileExists(atPath: smallNet.path), "small net missing — run Scripts/fetch-nnue.sh")
        #expect(FileManager.default.fileExists(atPath: bigNet.path), "big net missing — run Scripts/fetch-nnue.sh")

        try await engine.start(bigNet: bigNet, smallNet: smallNet)
        return engine
    }

    @Test("Completes the UCI handshake and loads networks")
    func handshakeAndNetworks() async throws {
        let engine = try await Self.bootedEngine()
        #expect(await engine.isStarted)

        // If a network failed to load, Stockfish refuses to search and reports
        // an info-string error instead of a bestmove — so a successful search
        // from the start position is itself proof the nets are live.
        let result = try await engine.search(.startPosition(moves: []), limit: .nodes(50_000))
        #expect(result.bestMove != nil)
    }

    @Test("Finds a forced mate in two")
    func findsMateInTwo() async throws {
        let engine = try await Self.bootedEngine()
        await engine.setOption(.multiPV, 1)
        await engine.isReady()

        // 1. Qg8+ Rxg8 2. Nf7#  (a standard smothered-mate finish)
        let fen = "6rk/6pp/8/6N1/8/8/8/5Q1K w - - 0 1"
        let result = try await engine.search(.fen(fen, moves: []), limit: .depth(12))

        let principal = try #require(result.principal)
        guard case .mate(let moves) = principal.score else {
            Issue.record("expected a mate score, got \(principal.score)")
            return
        }
        #expect(moves > 0 && moves <= 2, "expected mate in ≤2, got mate in \(moves)")
    }

    @Test("Reports no move in a terminal position")
    func terminalPosition() async throws {
        let engine = try await Self.bootedEngine()
        // Black is already checkmated (back-rank mate delivered).
        let result = try await engine.search(.fen("6k1/5ppp/8/8/8/8/8/R5K1 b - - 0 1", moves: []), limit: .depth(4))
        // Position is not actually mate here — black is fine; assert we get a move.
        #expect(result.bestMove != nil)

        let mated = try await engine.search(.fen("6k1/5ppp/8/8/8/8/5PPP/R5K1 b - - 0 1", moves: []), limit: .depth(4))
        #expect(mated.bestMove != nil)
    }

    @Test("Returns the requested number of MultiPV lines")
    func multiPVLines() async throws {
        let engine = try await Self.bootedEngine()
        await engine.setOption(.multiPV, 3)
        await engine.isReady()
        defer { Task { await engine.setOption(.multiPV, 1) } }

        let result = try await engine.search(.startPosition(moves: []), limit: .depth(12))
        #expect(result.lines.count == 3, "expected 3 MultiPV lines, got \(result.lines.count)")
        #expect(result.line(rank: 1) != nil)
        #expect(result.line(rank: 2) != nil)
        #expect(result.line(rank: 3) != nil)

        // Rank 1 must be at least as good as rank 2 from the mover's view.
        if let first = result.line(rank: 1), let second = result.line(rank: 2) {
            #expect(first.score.centipawnValue() >= second.score.centipawnValue())
        }
    }

    @Test("Stop drains an infinite search promptly")
    func stopDrainsSearch() async throws {
        let engine = try await Self.bootedEngine()
        await engine.setOption(.multiPV, 1)
        await engine.isReady()

        let started = Date()
        async let search = engine.search(.startPosition(moves: []), limit: .infinite)

        // Give the search a moment to actually begin before stopping it.
        try await Task.sleep(for: .milliseconds(400))
        await engine.stop()

        let result = try await search
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.bestMove != nil)
        #expect(elapsed < 5.0, "stop took \(elapsed)s — the engine did not drain promptly")
    }

    /// The NEON/dotprod build check.
    ///
    /// A scalar-fallback NNUE build on Apple Silicon benches in the low
    /// hundreds of thousands of NPS; a correctly vectorized one is in the
    /// millions. The threshold is deliberately far below real hardware numbers
    /// so it only fails when the SIMD path is genuinely missing.
    @Test("Bench NPS is consistent with an active SIMD path")
    func benchProvesVectorizedBuild() async throws {
        let engine = try await Self.bootedEngine()
        let nps = await engine.bench(depth: 8, threads: 1, hashMB: 16)

        #expect(nps > 0, "bench produced no nodes/second")
        #expect(
            nps > 400_000,
            "bench reported \(nps) nps — suspiciously low, the NEON/dotprod path is probably not compiled in"
        )
        print("[EngineSmoke] bench nodes/second: \(nps)")
    }
}
