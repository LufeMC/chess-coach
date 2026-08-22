//
//  IgnoredThreatDetector.swift
//  AnalysisKit
//

import ChessKit

/// Finds moves that walked past something the opponent was already threatening.
///
/// The evidence is a **null-move probe**: give the opponent a free move in the
/// position before the player moved and see what the engine does with it. If the
/// free move is worth something and the opponent then plays exactly that move for
/// real, the threat was real and the player did not see it.
///
/// Requiring the two moves to match is what separates "a threat existed" from
/// "the player ignored a threat" — a threat the opponent themselves passed up was
/// not the reason the move failed.
public struct IgnoredThreatDetector: Detector, Sendable {
    public let id = DetectorID.ignoredThreat

    /// Expected points the free move must win for the threat to count.
    ///
    /// The number this is compared against is a difference between two searches
    /// of different sizes: the probe runs at half the node budget under the
    /// MultiPV-3 enrichment lease, while `evalBefore` is the full-budget
    /// MultiPV-2 score from the main pass. That is a coarse quantity — good
    /// enough as a gate, and only because the detector has already required the
    /// opponent to play the probe's move for real, which is what actually
    /// establishes the threat. It is not good enough to show anyone, which is
    /// why ``MomentExplainer`` prints the threatened square and the move rather
    /// than this figure, and why `magnitude` below is for ranking only.
    public static let threatThreshold = 0.10

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard let probe = context.threatProbe, let threatMove = probe.bestMove else { return [] }
        guard let actualReply = context.refutationLine?.pv.first ?? context.refutationMove?.lan else { return [] }
        guard threatMove == actualReply else { return [] }

        // Both sides of this subtraction are the opponent's expected points:
        // the probe is searched with the opponent to move, and the real
        // evaluation is mover-relative, so it is complemented rather than
        // negated. The two sides are not searched to the same budget — see
        // ``threatThreshold`` — so the difference ranks findings and is never
        // quoted back to the player.
        let opponentEPWithFreeMove = probe.expectedPoints
        let opponentEPNow = EvalMath.complement(ep: EvalMath.expectedPoints(score: context.evalBefore))
        let gain = opponentEPWithFreeMove - opponentEPNow
        guard gain >= Self.threatThreshold else { return [] }

        let subtype: FindingSubtype = isStanding(context, threatMove: threatMove) ? .standingThreat : .newThreat
        let targetSquare = LineReplay.apply(uci: threatMove, to: context.positionBefore)?.move.end

        var flags: Set<FindingFlag> = []
        if context.playedMoveIsForcing { flags.insert(.playedMoveForcing) }

        return [
            Finding(
                detector: id,
                subtype: subtype,
                squares: [targetSquare].compactMap { $0 },
                flags: flags,
                magnitude: gain,
                detail: "Opponent's threat \(threatMove) probes \(String(format: "%.2f", gain)) EP "
                    + "above the main search's score"
            )
        ]
    }

    /// A threat is *standing* when the same idea was already on the board one
    /// opponent move earlier — the player has now ignored it twice, which is a
    /// different (and worse) habit than missing something brand new.
    private func isStanding(_ context: MoveContext, threatMove: String) -> Bool {
        guard let previous = context.previousThreatProbe else { return false }
        guard let previousThreat = previous.bestMove else { return false }
        return previousThreat == threatMove
    }
}
