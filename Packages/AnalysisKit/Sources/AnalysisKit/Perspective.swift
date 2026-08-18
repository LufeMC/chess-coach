//
//  Perspective.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Converts engine scores between the three perspectives this app cares about.
///
/// UCI scores are **side-to-move relative**: `+50` means "whoever is to move in
/// the position I searched is half a pawn better". Three consequences drive
/// every sign bug in analysis code:
///
/// * The score of the position *after* a move belongs to the **opponent** of the
///   player who made that move. To measure what a move cost its mover you must
///   negate it first.
/// * A graph or a "white is +1.2" label wants a **fixed (white) perspective**,
///   which flips whenever it is Black to move.
/// * Expected points are complementary rather than negated: `EP_them = 1 - EP_us`
///   (valid because the win% curve is symmetric — see ``EvalMath/winPercent(cp:)``).
///
/// Everything here is a one-line negation, and that is the point: the negation
/// happens in exactly one tested place instead of being re-derived at forty call
/// sites.
public enum Perspective {

    /// Converts a side-to-move relative score into a fixed white-relative score.
    ///
    /// - parameter score: The engine's score for the searched position.
    /// - parameter sideToMove: Whose turn it is in the searched position.
    public static func whiteRelative(_ score: UCIScore, sideToMove: Piece.Color) -> UCIScore {
        sideToMove == .white ? score : score.negated
    }

    /// Converts a fixed white-relative score back into a side-to-move relative
    /// score. Exact inverse of ``whiteRelative(_:sideToMove:)``.
    public static func sideToMoveRelative(_ whiteScore: UCIScore, sideToMove: Piece.Color) -> UCIScore {
        sideToMove == .white ? whiteScore : whiteScore.negated
    }

    /// Converts a side-to-move relative score into `viewer`'s perspective.
    public static func relative(_ score: UCIScore, sideToMove: Piece.Color, to viewer: Piece.Color) -> UCIScore {
        sideToMove == viewer ? score : score.negated
    }

    /// The score of the position *after* a move, expressed from the mover's
    /// perspective.
    ///
    /// The engine searched the position with the **opponent** to move, so its
    /// score is the opponent's. This is the single most common sign error in
    /// game-review code; it is written down once here.
    public static func moverRelativeAfterMove(_ scoreAfterMove: UCIScore) -> UCIScore {
        scoreAfterMove.negated
    }
}
