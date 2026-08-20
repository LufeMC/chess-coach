//
//  CalibrationScoring.swift
//  ChessCoach
//

import ChessKit
import TrainingCore

/// Turns a finished calibration game into the result the combiner is told about.
///
/// ## Why this is not just `userWon`
///
/// Calibration measures *the user*. Almost always the game result is the right
/// evidence, and this returns it untouched. The exception is the fifty-move
/// draw, which is not a result either player achieved — it is a result that
/// happened because nobody made progress for fifty moves.
///
/// That matters here and almost nowhere else. The calibration opponent is
/// Stockfish weakened to roughly the user's own level, and converting a won
/// endgame is exactly the technique a weakened engine fumbles. A user reduced to
/// a bare king against king-and-rook, who survives fifty moves because the
/// opponent cannot mate with a rook, is handed a draw against an 1100 — a
/// result worth real rating points, from a position that was lost beyond
/// recovery. Those points then seed the starting rung and the opponent ladder
/// for every screen in the app.
///
/// ## The asymmetry is deliberate
///
/// A hopeless position rescued by the fifty-move rule is downgraded to a loss.
/// A *winning* position thrown away by the same rule is **left as a draw**, not
/// promoted to a win — because failing to convert an extra rook is a genuine
/// weakness of the user's, and it is one the measurement should keep seeing.
///
/// So this only ever removes credit the user did not earn. It never invents any.
enum CalibrationScoring {

    /// Material values, in pawns. The king is worth nothing here: both sides
    /// always have exactly one, so it cancels.
    static func value(of kind: Piece.Kind) -> Int {
        switch kind {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }

    /// A side's material, in pawns.
    static func material(_ color: Piece.Color, in position: Position) -> Int {
        position.pieces
            .filter { $0.color == color }
            .reduce(0) { $0 + value(of: $1.kind) }
    }

    /// The deficit past which a position is beyond saving by play.
    ///
    /// A whole rook. Below this, a draw is a plausible defensive result and the
    /// user may well have earned it; at or beyond it, against an opponent of
    /// their own strength, the draw is the opponent's failure rather than the
    /// user's achievement.
    static let decisiveDeficit = 5

    /// The outcome the ladder is told about.
    ///
    /// - Parameters:
    ///   - outcome: what the game actually ended as.
    ///   - finalPosition: the position it ended in. `nil` leaves the result
    ///     untouched — an unknown position is not evidence of anything.
    ///   - userColor: which side the user played.
    static func measuredOutcome(
        for outcome: GameSession.Outcome,
        finalPosition: Position?,
        userColor: Piece.Color
    ) -> GameOutcome {
        let played: GameOutcome =
            switch outcome.userWon {
            case .some(true): .win
            case .some(false): .loss
            case nil: .draw
            }

        // Only the fifty-move rule. Stalemate and perpetual check are real
        // defensive resources a player *earns* from a lost position, and
        // downgrading those would punish exactly the skill worth rewarding.
        // Fifty moves without a capture or a pawn move is the one draw nobody
        // can claim to have played for.
        guard played == .draw,
            outcome.termination == Board.State.DrawReason.fiftyMoves.rawValue,
            let finalPosition
        else { return played }

        let opponentColor: Piece.Color = userColor == .white ? .black : .white
        let deficit = material(opponentColor, in: finalPosition)
            - material(userColor, in: finalPosition)

        return deficit >= decisiveDeficit ? .loss : played
    }
}
