//
//  PawnEndgameReasonTests.swift
//  ChessCoachTests
//

import ChessKit
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// A king-and-pawn ending has to be able to say what its answer achieves.
///
/// The reported case: a puzzle whose solution was a winning king march came
/// back as "Missed — the king to g6. This puzzle was about a defensive move —
/// it holds the position rather than attacking." The move wins by force; the
/// sentence says it does not attack. The theme tag was never the intended
/// source — `PuzzleReason.clause` is tried first and the tag is only the
/// fallback — but the clause could not fire, because the material bar for
/// naming a win was a knight and there is no knight in a pawn ending. Every
/// pawn ending therefore fell through to whatever noun Lichess had tagged.
@Suite("Pawn endgame explanations")
struct PawnEndgameReasonTests {

    /// White Kb3, Pg3, Ph4 against Black Kh6, Ph5, Pf6, Black to move.
    ///
    /// Read off the reported screenshot and corroborated against the engine:
    /// Kg6 is the only move that wins, and f5, Kg7 and Kh7 all draw, which is
    /// the shape a real puzzle with a unique solution has.
    static let fen = "8/8/5p1k/7p/7P/1K4P1/8/8 b - - 0 1"

    /// The engine's line after Kg6, as the continuation the corpus would carry:
    /// White replies, and Black's king walks to g4 and takes on g3.
    static let continuationAfterKg6 = ["b3c4", "g6f5", "c4d5", "f5g4", "d5e6", "g4g3"]

    @Test("A king march that wins a pawn says so, instead of falling back to the tag")
    func kingMarchIsExplained() throws {
        let position = try #require(Position(fen: Self.fen))
        let clause = PuzzleReason.clause(
            forAnswer: "h6g6",
            in: position,
            continuation: Self.continuationAfterKg6
        )

        let reason = try #require(
            clause,
            """
            A pawn ending produced no explanation at all, so the banner falls back to the puzzle's \
            theme noun — which is how a winning king march came to be described as a defensive move.
            """
        )
        #expect(reason.contains("pawn"), "the line wins a pawn and the sentence should say so")
    }

    @Test("The banner sentence describes the move rather than naming a theme")
    func bannerPrefersTheBoard() throws {
        let position = try #require(Position(fen: Self.fen))
        let message = PuzzleConcept.verdictMessage(
            solved: false,
            theme: ThemeTag(rawValue: "defensiveMove"),
            answer: "h6g6",
            position: position,
            continuation: Self.continuationAfterKg6
        )

        #expect(message.hasPrefix("Missed — the king to g6"))
        #expect(
            !message.contains("holds the position rather than attacking"),
            "the theme gloss contradicts the line: Kg6 wins by force"
        )
    }

    /// The bar is only lowered where a pawn is the material in question. A
    /// middlegame tactic that happens to end a pawn up must not start
    /// announcing it.
    @Test("A pawn is still not worth naming while pieces are on the board")
    func pieceEndgamesKeepTheHigherBar() throws {
        // Same idea, but with rooks on: kings, pawns and a rook each.
        let position = try #require(Position(fen: "8/8/5p1k/7p/7P/1K4P1/r7/R7 b - - 0 1"))
        let clause = PuzzleReason.clause(
            forAnswer: "h6g6",
            in: position,
            continuation: Self.continuationAfterKg6
        )
        if let clause {
            #expect(
                !clause.contains("you win the pawn"),
                "with rooks on the board a single pawn is not the headline"
            )
        }
    }
}
