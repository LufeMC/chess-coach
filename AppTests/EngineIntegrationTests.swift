import AnalysisKit
import ChessKit
import Database
import EngineKit
import Foundation
import Testing

@testable import ChessCoach

// MARK: - Engine-backed integration test
//
// The only test here that boots Stockfish. Everything else in this suite is pure
// and runs in milliseconds; this one exists because the pure tests cannot catch
// the failure that actually matters — a perspective conversion that is wrong
// against *real* engine output rather than against a fixture written by the same
// person who wrote the conversion.
//
// Kept to one short game at a small node budget so it stays well inside a few
// seconds. It is `.serialized` and tagged so it can be excluded from a fast run.

@Suite("Engine integration", .serialized)
struct EngineIntegrationTests {

    /// The Elephant Trap. White's 6. Nxd5 drops a piece to 6... Nxd5 7. Bxd8 Bb4+.
    /// Twelve plies, and the blunder is White's sixth move — ply 11.
    static let elephantTrap = [
        "d2d4", "d7d5", "c2c4", "e7e6", "b1c3", "g8f6",
        "c1g5", "b8d7", "c4d5", "e6d5", "c3d5", "f6d5"
    ]

    static let networks = URL(fileURLWithPath: "/Users/luis/Personal Projects/chess/App/Resources/Networks")

    /// Small enough to stay fast, large enough that the engine sees a two-move
    /// tactic. The app's own budget is calibrated per device and is far larger.
    static let nodeBudget = 200_000

    @Test("A real engine pass finds and classifies a real blunder")
    func findsTheElephantTrap() async throws {
        let big = Self.networks.appending(path: "nn-1c0000000000.nnue")
        let small = Self.networks.appending(path: "nn-37f18f62d772.nnue")
        try #require(FileManager.default.fileExists(atPath: big.path))
        try #require(FileManager.default.fileExists(atPath: small.path))

        let engine = StockfishEngine.shared
        try await engine.start(bigNet: big, smallNet: small)
        await engine.setOption(.threads, 2)
        await engine.setOption(.hash, 64)
        await engine.setOption(.multiPV, 2)
        await engine.isReady()
        await engine.newGame()

        let uci = Self.elephantTrap
        let replay = AnalysisPipeline.replay(uci: uci)
        #expect(replay.moves.count == uci.count)

        // This is phase 1 of `AnalysisService`, inlined: one search per position,
        // MultiPV 2, `n + 1` of them.
        let started = Date()
        var evaluations: [AnalysisPipeline.PositionEval] = []
        for index in 0..<replay.positions.count {
            if let terminal = replay.terminalScores[index] {
                evaluations.append(.init(ply: index + 1, terminalScore: terminal))
                continue
            }
            let result = try await engine.search(
                .startPosition(moves: Array(uci.prefix(index))),
                limit: .nodes(Self.nodeBudget)
            )
            evaluations.append(.init(ply: index + 1, result: result))
        }
        let elapsed = Date().timeIntervalSince(started)

        let gameID = UUID()
        let moveRows = uci.enumerated().map { index, text in
            GameMoveRow(gameID: gameID, ply: index + 1, san: text, uci: text, thinkTimeMs: 8_000)
        }

        let analyzed = AnalysisPipeline.analyze(
            replay: replay,
            evaluations: evaluations,
            moveRows: moveRows,
            userColor: .white,
            timeControl: TimeControl(baseSeconds: 600, incrementSeconds: 5),
            userFlagged: false,
            enrichments: [:],
            policy: MomentPolicy()
        )

        // Ply 11 (index 10) is `c3d5`, the move that drops the knight.
        let blunder = try #require(analyzed.moves.first { $0.ply == 11 })
        #expect(blunder.classification == MoveClassification.blunder.rawValue)

        // The sign test: White's own win% must fall across White's own blunder.
        let before = try #require(blunder.winPctBefore)
        let after = try #require(blunder.winPctAfter)
        #expect(before > after)

        // Black's replies are evaluated but never judged.
        #expect(analyzed.moves.filter { $0.ply % 2 == 0 }.allSatisfy { $0.classification == nil })
        #expect(analyzed.moves.filter { $0.ply % 2 == 0 }.allSatisfy { $0.winPctBefore != nil })

        // The opening moves are book; none of them should read as an error.
        let opening = analyzed.moves.filter { $0.ply <= 6 && $0.ply % 2 == 1 }
        #expect(
            opening.allSatisfy {
                $0.classification == MoveClassification.best.rawValue
                    || $0.classification == MoveClassification.good.rawValue
            }
        )

        let moment = try #require(analyzed.moments.first { $0.ply == 11 })
        #expect(moment.playedUCI == "c3d5")
        #expect(moment.judgment == .blunder)
        #expect(moment.deltaEP > 0.30)

        let accuracy = try #require(analyzed.userAccuracy)
        #expect(accuracy > 0 && accuracy < 100)

        // A real pass runs at a far higher node budget, but 13 positions taking
        // more than a few seconds here would mean something is badly wrong.
        #expect(elapsed < 25)
        print("Engine pass: \(replay.positions.count) positions in \(String(format: "%.2f", elapsed))s")
        print("Blunder ply 11: \(before) -> \(after) win%, accuracy \(accuracy)")

        await engine.stop()
    }
}
