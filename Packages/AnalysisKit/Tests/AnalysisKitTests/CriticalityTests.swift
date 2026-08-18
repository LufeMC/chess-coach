//
//  CriticalityTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Criticality")
struct CriticalityTests {

    private func evaluate(
        fen: String,
        bestPV: [String],
        bestScore: UCIScore,
        secondScore: UCIScore?,
        lastCaptureSquare: Square? = nil
    ) throws -> CriticalityResult {
        let position = try Fixture.position(fen)
        let best = UCIInfo(multipv: 1, score: bestScore, pv: bestPV)
        let second = secondScore.map { UCIInfo(multipv: 2, score: $0, pv: []) }
        return Criticality.evaluate(
            best: best,
            secondBest: second,
            board: Board(position: position),
            lastCaptureSquare: lastCaptureSquare
        )
    }

    /// A quiet position where the best move is a knight development and the
    /// runner-up is nearly as good.
    private let quietFEN = "rnbqkb1r/pppp1ppp/5n2/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"

    @Test("A small gap is not a decision point")
    func smallGap() throws {
        let result = try evaluate(
            fen: quietFEN,
            bestPV: ["b1c3"],
            bestScore: .centipawns(30),
            secondScore: .centipawns(20)
        )
        #expect(result.isCritical == false)
        #expect(result.gap < Criticality.gapThreshold)
        #expect(result.suppressedBy == nil)
    }

    @Test("A large gap on a quiet move is a decision point")
    func largeGap() throws {
        let result = try evaluate(
            fen: quietFEN,
            bestPV: ["b1c3"],
            bestScore: .centipawns(120),
            secondScore: .centipawns(-160)
        )
        #expect(result.isCritical)
        #expect(result.gap >= Criticality.gapThreshold)
    }

    @Test("A decided game suppresses criticality")
    func alreadyDecided() throws {
        let result = try evaluate(
            fen: quietFEN,
            bestPV: ["b1c3"],
            bestScore: .centipawns(900),
            secondScore: .centipawns(100)
        )
        #expect(result.isCritical == false)
        #expect(result.suppressedBy == .alreadyDecided)
    }

    @Test("Mate scores count as decided")
    func mateIsDecided() throws {
        let result = try evaluate(
            fen: quietFEN,
            bestPV: ["b1c3"],
            bestScore: .mate(4),
            secondScore: .centipawns(50)
        )
        #expect(result.suppressedBy == .alreadyDecided)
    }

    @Test("Grabbing a free piece is not a decision")
    func freeCapture() throws {
        let result = try evaluate(
            fen: "4k3/8/8/3n4/8/8/8/3RK3 w - - 0 1",
            bestPV: ["d1d5"],
            bestScore: .centipawns(320),
            secondScore: .centipawns(-100)
        )
        #expect(result.isCritical == false)
        #expect(result.suppressedBy == .freeCapture)
    }

    @Test("Taking back is not a decision")
    func forcedRecapture() throws {
        // Black has just captured on d5; Rxd5 is the only move that gets the
        // material back, and every other move scores far worse.
        let result = try evaluate(
            fen: "7k/8/8/3r4/8/8/8/3R3K w - - 0 1",
            bestPV: ["d1d5"],
            bestScore: .centipawns(100),
            secondScore: .centipawns(-400),
            lastCaptureSquare: .d5
        )
        #expect(result.isCritical == false)
        #expect(result.suppressedBy == .forcedRecapture)
    }

    @Test("Without a capture square the recapture filter stays off")
    func recaptureNeedsTheSquare() throws {
        let result = try evaluate(
            fen: "7k/8/8/3r4/8/8/8/3R3K w - - 0 1",
            bestPV: ["d1d5"],
            bestScore: .centipawns(100),
            secondScore: .centipawns(-400)
        )
        // Falls through to the free-capture filter instead.
        #expect(result.suppressedBy == .freeCapture)
    }

    @Test("A position with no alternative move is not a decision")
    func noSecondLine() throws {
        let result = try evaluate(
            fen: quietFEN,
            bestPV: ["b1c3"],
            bestScore: .centipawns(120),
            secondScore: nil
        )
        #expect(result.isCritical == false)
        #expect(result.suppressedBy == .noAlternative)
        #expect(result.gap == 0)
    }

    @Test("The convenience entry point agrees with the full result")
    func convenienceAPI() throws {
        let position = try Fixture.position(quietFEN)
        let best = UCIInfo(multipv: 1, score: .centipawns(120), pv: ["b1c3"])
        let second = UCIInfo(multipv: 2, score: .centipawns(-160), pv: ["f1c4"])
        #expect(Criticality.isCritical(best: best, secondBest: second, board: Board(position: position)))
    }
}

@Suite("Phase and think time")
struct PhaseTimeTests {

    @Test("Early moves are the opening")
    func opening() throws {
        let position = try Fixture.position(
            "rnbqkb1r/pppp1ppp/5n2/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"
        )
        #expect(Phase.classify(position: position, ply: 5) == .opening)
        #expect(Phase.classify(position: position, ply: 20) == .opening)
        #expect(Phase.classify(position: position, ply: 21) == .middlegame)
    }

    @Test("Thin material is an endgame whatever the move number")
    func endgame() throws {
        let position = try Fixture.position("8/5pk1/8/8/8/8/5PK1/2R1r3 w - - 0 30")
        #expect(Phase.classify(position: position, ply: 60) == .endgame)
        // Material wins over the ply test — a study is an endgame on move one.
        #expect(Phase.classify(position: position, ply: 3) == .endgame)
    }

    @Test("The endgame boundary is six pieces")
    func endgameBoundary() throws {
        // Four rooks and a bishop: five pieces, under the limit.
        let five = try Fixture.position("r3k2r/8/2b5/8/8/8/8/R3K2R w KQkq - 0 20")
        #expect(PositionUtilities.heavyAndMinorPieceCount(five) == 5)
        #expect(Phase.classify(position: five, ply: 40) == .endgame)

        let middlegame = try Fixture.position(
            "r1bq1rk1/pppp1ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQ1RK1 w - - 0 8"
        )
        #expect(PositionUtilities.heavyAndMinorPieceCount(middlegame) == 14)
        #expect(Phase.classify(position: middlegame, ply: 40) == .middlegame)
    }

    @Test("Think-time buckets use the larger of the floor and the budget share")
    func thinkBuckets() {
        // 5+0 blitz: budget is 300/45 ≈ 6.7s, so the fast floor of 4s wins.
        let blitz = TimeControl.blitz5plus0
        #expect(abs(blitz.perMoveBudgetSeconds - 300.0 / 45.0) < 1e-9)
        #expect(ThinkBucket.classify(thinkTimeMs: 3_000, control: blitz) == .fast)
        #expect(ThinkBucket.classify(thinkTimeMs: 10_000, control: blitz) == .normal)
        #expect(ThinkBucket.classify(thinkTimeMs: 50_000, control: blitz) == .long)

        // Classical 90+30: budget is (5400 + 1200)/45 ≈ 147s, so both boundaries
        // scale up well past their floors.
        let classical = TimeControl.classical
        #expect(ThinkBucket.classify(thinkTimeMs: 30_000, control: classical) == .fast)
        #expect(ThinkBucket.classify(thinkTimeMs: 100_000, control: classical) == .normal)
        #expect(ThinkBucket.classify(thinkTimeMs: 400_000, control: classical) == .long)
    }

    @Test("Without a time control the floors alone decide")
    func noTimeControl() {
        #expect(ThinkBucket.classify(thinkTimeMs: 3_999, control: nil) == .fast)
        #expect(ThinkBucket.classify(thinkTimeMs: 4_000, control: nil) == .normal)
        #expect(ThinkBucket.classify(thinkTimeMs: 45_000, control: nil) == .normal)
        #expect(ThinkBucket.classify(thinkTimeMs: 45_001, control: nil) == .long)
    }
}

@Suite("Null-move probe")
struct NullMoveTests {

    @Test("A probe flips the side to move and clears en passant")
    func probeFEN() throws {
        let position = try Fixture.position(
            "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2"
        )
        let fen = try #require(NullMove.probeFEN(for: position))
        #expect(fen == "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2")
        #expect(Position(fen: fen)?.sideToMove == .black)
    }

    @Test("Passing out of check is not allowed")
    func inCheck() throws {
        // Fool's mate position: Black's queen checks (mates) on h4.
        let position = try Fixture.position(
            "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"
        )
        #expect(PositionUtilities.isInCheck(position, color: .white))
        #expect(NullMove.probeFEN(for: position) == nil)
    }

    @Test("Black's pass advances the move number")
    func fullmoveAdvances() throws {
        let position = try Fixture.position("4k3/8/8/8/8/8/8/4K3 b - - 4 12")
        let fen = try #require(NullMove.probeFEN(for: position))
        #expect(fen.hasSuffix("w - - 0 13"))
    }
}
