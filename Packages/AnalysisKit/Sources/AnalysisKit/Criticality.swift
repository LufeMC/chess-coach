//
//  Criticality.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Whether a position was a real decision point, and by how much.
public struct CriticalityResult: Sendable, Equatable, Codable {
    /// The position genuinely branches: one move is much better than the rest,
    /// and it is not better for a trivial reason.
    public let isCritical: Bool
    /// `EP(best) - EP(second best)`, both from the side to move's perspective.
    public let gap: Double
    /// Which filter suppressed criticality, if any. Kept for explainability —
    /// "why wasn't this a key moment?" is a question the UI will ask.
    public let suppressedBy: Suppression?

    public enum Suppression: String, Sendable, Codable {
        case alreadyDecided
        case forcedRecapture
        case freeCapture
        case noAlternative
    }
}

/// Identifies positions where the choice of move actually mattered.
///
/// The gap test alone is far too generous: recaptures, free captures and
/// completely won positions all show a huge gap between the best move and the
/// second best without asking anything of the player. Those three filters are
/// what turn "the engine prefers one move" into "the player had to find
/// something".
public enum Criticality {

    /// Minimum expected-points gap between best and second-best for a position
    /// to count as a decision point.
    public static let gapThreshold = 0.10
    /// Centipawn magnitude beyond which the game is decided and a further
    /// mistake teaches nothing.
    public static let decidedThreshold = 600

    /// - parameter best: MultiPV rank 1 for the position.
    /// - parameter secondBest: MultiPV rank 2, if the search produced one.
    /// - parameter board: The position, used for the SEE-based filters.
    /// - parameter lastCaptureSquare: The square the opponent captured on with
    ///   their previous move, if any. Required for the forced-recapture filter;
    ///   omitting it simply disables that filter.
    public static func isCritical(
        best: UCIInfo,
        secondBest: UCIInfo?,
        board: Board,
        lastCaptureSquare: Square? = nil
    ) -> Bool {
        evaluate(best: best, secondBest: secondBest, board: board, lastCaptureSquare: lastCaptureSquare).isCritical
    }

    /// Full result, including the gap and the reason criticality was suppressed.
    public static func evaluate(
        best: UCIInfo,
        secondBest: UCIInfo?,
        board: Board,
        lastCaptureSquare: Square? = nil
    ) -> CriticalityResult {
        guard let secondBest else {
            // Only one move was searched: either it is forced, or the caller did
            // not request MultiPV. Either way the player had no choice to get
            // wrong, so this is not a teachable decision point.
            return CriticalityResult(isCritical: false, gap: 0, suppressedBy: .noAlternative)
        }

        let gap = EvalMath.expectedPoints(score: best.score) - EvalMath.expectedPoints(score: secondBest.score)
        guard gap >= gapThreshold else {
            return CriticalityResult(isCritical: false, gap: gap, suppressedBy: nil)
        }

        if abs(best.score.centipawnValue()) >= decidedThreshold {
            return CriticalityResult(isCritical: false, gap: gap, suppressedBy: .alreadyDecided)
        }

        let position = board.position
        let bestMove = best.pv.first.flatMap { LineReplay.apply(uci: $0, to: position)?.move }

        if let bestMove {
            if isFreeCapture(bestMove, in: position) {
                return CriticalityResult(isCritical: false, gap: gap, suppressedBy: .freeCapture)
            }
            if let lastCaptureSquare, isForcedRecapture(bestMove, on: lastCaptureSquare, in: position) {
                return CriticalityResult(isCritical: false, gap: gap, suppressedBy: .forcedRecapture)
            }
        }

        return CriticalityResult(isCritical: true, gap: gap, suppressedBy: nil)
    }

    // MARK: Filters

    /// Grabbing a piece nobody defends is not a decision.
    static func isFreeCapture(_ move: Move, in position: Position) -> Bool {
        guard let see = SEE.seeOfCapture(position: position, move: move) else { return false }
        return see > 0
    }

    /// Taking back on the square the opponent just captured on, when nothing else
    /// holds material, is not a decision either.
    ///
    /// "Only non-losing move by SEE" is measured with ``SEE/staticExchange(position:move:)``
    /// over every legal move, so a quiet move that hangs a piece counts as losing
    /// just as a bad capture does.
    static func isForcedRecapture(_ move: Move, on square: Square, in position: Position) -> Bool {
        guard move.end == square, case .capture = move.result else { return false }
        let nonLosing = PositionUtilities.legalMoves(in: position).filter {
            SEE.staticExchange(position: position, move: $0) >= 0
        }
        return nonLosing.count == 1
    }
}
