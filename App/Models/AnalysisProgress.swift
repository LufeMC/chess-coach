import Foundation

/// What the post-game pass is doing right now.
///
/// Deliberately a plain value: the UI binds to a stream of these, so it must be
/// cheap to send and safe to drop. `ply`/`total` are half-move counts, not
/// percentages, because "ply 34 of 71" is a better progress label for a chess
/// player than "48%".
struct AnalysisProgress: Sendable, Equatable {

    enum Stage: String, Sendable, Equatable {
        /// Queued, not started.
        case queued
        /// Walking every ply at the base MultiPV.
        case evaluating
        /// Re-searching the flagged positions for coaching lines.
        case enriching
        /// Running detectors and picking moments. No engine involved.
        case selecting
        /// Writing moments, classifications and accuracy.
        case writing
        /// Stopped cleanly on a ply boundary; will resume from here.
        case paused
        case finished
        case failed
    }

    var gameID: UUID
    var stage: Stage
    /// Plies whose evaluation is complete.
    var ply: Int
    /// Positions to evaluate: one per move, plus the final position.
    var total: Int
    /// Set when `stage == .failed`.
    var failureReason: String?

    init(
        gameID: UUID,
        stage: Stage,
        ply: Int = 0,
        total: Int = 0,
        failureReason: String? = nil
    ) {
        self.gameID = gameID
        self.stage = stage
        self.ply = ply
        self.total = total
        self.failureReason = failureReason
    }

    /// 0...1, saturating. `nil` before the ply count is known.
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(ply) / Double(total), 0), 1)
    }

    var isTerminal: Bool {
        stage == .finished || stage == .failed
    }
}
