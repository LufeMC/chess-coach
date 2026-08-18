//
//  PuzzleMinerTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Puzzle miner")
struct PuzzleMinerTests {

    /// Ra1-b1 skewers the queen on b4 to the rook on b8; after the queen moves,
    /// Rxb8 wins the exchange. Three plies: winner, loser, winner.
    private let skewer = "1r2k3/8/8/8/1q6/8/8/R5K1 w - - 0 1"

    private struct Step {
        let uci: String
        let best: UCIScore
        let second: UCIScore?
    }

    /// Walks a line forward, building one node per position.
    private func nodes(from fen: String, steps: [Step]) throws -> [PuzzleMiner.Node] {
        var position = try Fixture.position(fen)
        var result: [PuzzleMiner.Node] = []
        for step in steps {
            result.append(
                PuzzleMiner.Node(
                    fen: position.fen,
                    best: UCIInfo(multipv: 1, score: step.best, pv: [step.uci]),
                    second: step.second.map { UCIInfo(multipv: 2, score: $0, pv: []) }
                )
            )
            guard let applied = LineReplay.apply(uci: step.uci, to: position) else {
                throw FixtureError.illegalMove(step.uci)
            }
            position = applied.position
        }
        return result
    }

    private func winningLine(secondAtStart: UCIScore? = .centipawns(-200)) throws -> [PuzzleMiner.Node] {
        try nodes(
            from: skewer,
            steps: [
                Step(uci: "a1b1", best: .centipawns(500), second: secondAtStart),
                Step(uci: "b4c4", best: .centipawns(-500), second: .centipawns(-600)),
                Step(uci: "b1b8", best: .centipawns(600), second: .centipawns(-200))
            ]
        )
    }

    @Test("A big swing with a forced follow-up becomes a puzzle")
    func mines() throws {
        let candidate = try #require(
            PuzzleMiner.mine(scoreBeforeError: .centipawns(0), line: try winningLine())
        )
        #expect(candidate.fen == skewer)
        #expect(candidate.solution == ["a1b1", "b4c4", "b1b8"])
        #expect(candidate.winner == .white)
        #expect(candidate.solution.count % 2 == 1)
    }

    @Test("A position that was already winning triggers nothing")
    func triggerNeedsAJump() throws {
        // The loser was already lost before the move, so there is no blunder.
        #expect(PuzzleMiner.mine(scoreBeforeError: .centipawns(-450), line: try winningLine()) == nil)
    }

    @Test("A small evaluation does not trigger")
    func triggerNeedsSize() throws {
        let line = try nodes(
            from: skewer,
            steps: [
                Step(uci: "a1b1", best: .centipawns(150), second: .centipawns(-600)),
                Step(uci: "b4c4", best: .centipawns(-150), second: nil),
                Step(uci: "b1b8", best: .centipawns(150), second: .centipawns(-600))
            ]
        )
        #expect(PuzzleMiner.mine(scoreBeforeError: .centipawns(-100), line: line) == nil)
    }

    @Test("Mate appearing is always a trigger")
    func mateTrigger() {
        #expect(PuzzleMiner.passesTrigger(before: .centipawns(-50), after: .mate(3)))
        // Already mating before the move: nothing new was blundered.
        #expect(PuzzleMiner.passesTrigger(before: .mate(5), after: .mate(3)) == false)
    }

    /// Two equally good answers make a puzzle that marks correct solvers wrong.
    @Test("An ambiguous solution is discarded")
    func ambiguous() throws {
        let line = try winningLine(secondAtStart: .centipawns(450))
        #expect(PuzzleMiner.mine(scoreBeforeError: .centipawns(0), line: line) == nil)
    }

    @Test("An unverifiable node is kept but flagged for a deeper search")
    func unverified() throws {
        let candidate = try #require(
            PuzzleMiner.mine(scoreBeforeError: .centipawns(0), line: try winningLine(secondAtStart: nil))
        )
        #expect(candidate.needsDeeperValidation)
    }

    @Test("An even-length line is trimmed back to the winner's move")
    func evenLengthTrimmed() throws {
        let line = try nodes(
            from: skewer,
            steps: [
                Step(uci: "a1b1", best: .centipawns(500), second: .centipawns(-200)),
                Step(uci: "b4c4", best: .centipawns(-500), second: .centipawns(-600)),
                Step(uci: "b1b8", best: .centipawns(600), second: .centipawns(-200)),
                Step(uci: "e8e7", best: .centipawns(-600), second: .centipawns(-700))
            ]
        )
        let candidate = try #require(PuzzleMiner.mine(scoreBeforeError: .centipawns(0), line: line))
        #expect(candidate.solution == ["a1b1", "b4c4", "b1b8"])
    }

    @Test("One-move solutions are not puzzles")
    func oneMoveDiscarded() throws {
        let line = try nodes(
            from: "6k1/5ppp/8/8/8/8/6PP/R5K1 w - - 0 1",
            steps: [Step(uci: "a1a8", best: .mate(1), second: .centipawns(0))]
        )
        #expect(PuzzleMiner.mine(scoreBeforeError: .centipawns(0), line: line) == nil)
    }

    /// A move the player had no choice about teaches nothing, so it comes off the
    /// end of the solution.
    @Test("Trailing forced moves are stripped")
    func stripsOnlyMoves() throws {
        // White's only legal move in this position is the a7-a8 promotion.
        let forced = "7k/P7/8/8/8/8/5q2/7K w - - 0 1"
        let position = try Fixture.position(forced)
        #expect(PositionUtilities.legalMovePairs(in: position).count == 1)

        let line = [
            PuzzleMiner.Node(fen: skewer, best: UCIInfo(pv: ["a1b1"])),
            PuzzleMiner.Node(fen: forced, best: UCIInfo(pv: ["a7a8"]))
        ]
        #expect(PuzzleMiner.stripTrailingOnlyMoves(["a1b1", "a7a8"], line: line) == ["a1b1"])
    }

    @Test("A line that never resolves is flagged for deeper validation")
    func unresolvedLine() throws {
        let line = try nodes(
            from: skewer,
            steps: [
                Step(uci: "a1b1", best: .centipawns(500), second: .centipawns(-200)),
                Step(uci: "b4c4", best: .centipawns(-500), second: .centipawns(-600)),
                Step(uci: "b1b8", best: .centipawns(300), second: .centipawns(-500))
            ]
        )
        let candidate = try #require(PuzzleMiner.mine(scoreBeforeError: .centipawns(0), line: line))
        #expect(candidate.needsDeeperValidation)
    }
}
