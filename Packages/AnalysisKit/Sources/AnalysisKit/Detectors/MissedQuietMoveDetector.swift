//
//  MissedQuietMoveDetector.swift
//  AnalysisKit
//

import ChessKit

/// Finds the specific bias where a player reaches for a forcing move because the
/// right answer was quiet.
///
/// It only fires when both halves are true: the engine wanted something quiet
/// **and** the player played a check, capture or promotion. That pairing is the
/// signature of "I looked at checks and captures and stopped there", which is a
/// different lesson from simply missing a good move.
public struct MissedQuietMoveDetector: Detector, Sendable {
    public let id = DetectorID.missedQuietMove

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard context.judgment >= .inaccuracy else { return [] }
        guard context.playedMoveIsForcing else { return [] }
        guard context.bestMoveIsQuiet, let best = context.bestLineSteps.first else { return [] }

        let subtype = classify(context, best: best)

        return [
            Finding(
                detector: id,
                subtype: subtype,
                squares: [best.move.start, best.move.end],
                flags: [.bestMoveQuiet, .playedMoveForcing],
                magnitude: context.deltaEP,
                detail: "Quiet \(best.uci) was better than forcing \(context.playedUCI)"
            )
        ]
    }

    /// Retreat is checked before prophylaxis because it is the more visible
    /// lesson: "the move went backwards" is something a player can be taught to
    /// look for, whereas prophylaxis is a subtler frame laid on top of it.
    private func classify(_ context: MoveContext, best: ReplayStep) -> FindingSubtype {
        let startRank = best.move.start.relativeRank(for: context.mover)
        let endRank = best.move.end.relativeRank(for: context.mover)
        if endRank < startRank { return .retreat }
        if defusesThreat(context, best: best) { return .prophylactic }
        return .improvement
    }

    /// The quiet move answers the opponent's null-move threat: after it, the
    /// threatened move is either illegal or no longer wins anything.
    private func defusesThreat(_ context: MoveContext, best: ReplayStep) -> Bool {
        guard let threat = context.threatProbe?.bestMove else { return false }
        guard let probe = NullMove.probePosition(for: best.positionAfter) else { return false }
        guard let applied = LineReplay.apply(uci: threat, to: probe) else { return true }
        return SEE.staticExchange(position: probe, move: applied.move) <= 0
    }
}
