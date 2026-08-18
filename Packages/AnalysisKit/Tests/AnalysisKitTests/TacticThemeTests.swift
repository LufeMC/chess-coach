//
//  TacticThemeTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Tactic theme classifier")
struct TacticThemeTests {

    private func classify(_ fen: String, _ pv: [String], score: UCIScore? = nil) throws -> TacticTheme {
        let position = try #require(Position(fen: fen))
        return TacticThemeClassifier.classify(pv: pv, from: position, score: score)
    }

    @Test("A knight hitting king and rook is a fork")
    func fork() throws {
        // Nb5-c7+ forks the king on e8 and the rook on a8.
        let theme = try classify("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1", ["b5c7"])
        #expect(theme == .fork)
    }

    @Test("A bishop lining up on a knight in front of the king is a pin")
    func pin() throws {
        // Bd1-a4 lines up a4-b5-c6-e8: the knight cannot move.
        let theme = try classify("4k3/8/2n5/8/8/8/8/3BK3 w - - 0 1", ["d1a4"])
        #expect(theme == .pin)
    }

    @Test("A rook hitting a queen with a rook behind it is a skewer")
    func skewer() throws {
        // Ra1-b1 attacks the queen on b4 with the rook on b8 behind it.
        let theme = try classify("1r2k3/8/8/8/1q6/8/8/R5K1 w - - 0 1", ["a1b1"])
        #expect(theme == .skewer)
    }

    @Test("A rook mate on the eighth against a pawn wall is a back-rank mate")
    func backRank() throws {
        let theme = try classify("6k1/5ppp/8/8/8/8/6PP/R5K1 w - - 0 1", ["a1a8"])
        #expect(theme == .backRankMate)
    }

    @Test("A mate away from the back rank is a plain mate threat")
    func mateThreat() throws {
        // Scholar's mate: Qxf7# on the seventh, king not boxed by its own pawns
        // on the first rank.
        let theme = try classify(
            "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4",
            ["h5f7"]
        )
        #expect(theme == .mateThreat)
    }

    @Test("Moving a blocker out of a bishop's line is a discovered attack")
    func discoveredAttack() throws {
        // The knight on d4 stands on the b2 bishop's diagonal; Nb5 unmasks it
        // onto the rook on g7.
        let theme = try classify("7k/6r1/8/8/3N4/8/1B6/K7 w - - 0 1", ["d4b5"])
        #expect(theme == .discoveredAttack)
    }

    @Test("Taking the piece that guards another is removal of the defender")
    func removalOfDefender() throws {
        // Bxd7+ removes the knight guarding b6; after Kxd7 the bishop drops to
        // the rook on b1.
        let theme = try classify("4k3/3n4/1b6/8/6B1/8/8/1R2K3 w - - 0 1", ["g4d7", "e8d7"])
        #expect(theme == .removalOfDefender)
    }

    @Test("A bishop with only a losing square is trapped")
    func trappedPiece() throws {
        // b2-b4 attacks the a5 bishop, whose own b6 pawn blocks the only retreat;
        // Bxb4 axb4 just loses the piece.
        let theme = try classify("4k3/8/1p6/b7/8/P7/1P6/4K3 w - - 0 1", ["b2b4"])
        #expect(theme == .trappedPiece)
    }

    @Test("A line with no recognised motif falls back to unknown")
    func unknown() throws {
        let theme = try classify("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", ["e2e4"])
        #expect(theme == .unknownTactic)
    }

    @Test("An empty variation classifies as unknown rather than crashing")
    func emptyLine() throws {
        let theme = try classify("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", [])
        #expect(theme == .unknownTactic)
    }

    /// Mate outranks everything: the fork in the mating net is not the lesson.
    @Test("A mate score wins over other motifs")
    func mateTakesPriority() throws {
        let theme = try classify("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1", ["b5c7"], score: .mate(2))
        #expect(theme == .mateThreat)
    }
}
