import AnalysisKit
import Foundation

/// The verdict on one played move.
///
/// `winPctBefore`/`winPctAfter` are **mover-relative**: both are the win
/// percentage for the player who made this move. That is the only pairing the
/// accuracy curve accepts (see `EvalMath.accuracy`), and it makes the two columns
/// comparable across colours without a per-row perspective flag. A white-relative
/// eval graph is one flip away: odd plies are already white's.
struct AnalyzedMove: Sendable, Equatable {
    /// Primary key of the `gameMoves` row this updates.
    var id: UUID
    var ply: Int
    /// `nil` for the opponent's moves — they are evaluated, never judged.
    var classification: String?
    var winPctBefore: Double?
    var winPctAfter: Double?
    /// Lichess move accuracy, user moves only. Feeds the game accuracy.
    var accuracy: Double?
}

/// Everything one analysis pass produced, before any of it is written.
///
/// Kept as a value so the whole pipeline — replay, detection, tagging, scoring —
/// can be exercised from canned engine output with no database and no engine.
struct AnalyzedGame: Sendable {
    var moves: [AnalyzedMove]
    var moments: [AnalysisKit.Moment]
    /// `nil` when the user made no moves (an immediate resignation).
    var userAccuracy: Double?
}

/// The vocabulary written to `gameMoves.classification`.
///
/// Five values, not four: Lichess's three error classes plus a split of the
/// remainder into "you found the engine's move" and "fine, but not the move".
/// The distinction is what lets the review screen praise something without
/// implying that every non-error move was best.
enum MoveClassification: String, Sendable, CaseIterable {
    case best
    case good
    case inaccuracy
    case mistake
    case blunder

    /// Maps a judgment plus "did they find it" onto the stored string.
    ///
    /// Pure and total, so the mapping can be tested without an engine.
    static func classify(judgment: Judgment, playedBestMove: Bool) -> MoveClassification {
        switch judgment {
        case .blunder: .blunder
        case .mistake: .mistake
        case .inaccuracy: .inaccuracy
        case .ok: playedBestMove ? .best : .good
        }
    }
}
