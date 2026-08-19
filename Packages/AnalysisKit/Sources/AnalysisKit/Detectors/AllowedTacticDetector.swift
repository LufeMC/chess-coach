//
//  AllowedTacticDetector.swift
//  AnalysisKit
//

import ChessKit

/// Finds moves that handed the opponent a tactic.
///
/// The size of what was allowed is measured as the move's own cost: the
/// opponent's evaluation after the move, compared with the position before it, is
/// exactly `deltaEP`. (Comparing the refutation's score with the evaluation of
/// the position it starts from would be circular — they are the same number.)
///
/// `.shallow` versus `.deep` is the coaching distinction that matters: a tactic
/// that lands in one or two plies should have been caught by a blunder check,
/// while one that needs three or more plies is a calculation failure.
public struct AllowedTacticDetector: Detector, Sendable {
    public let id = DetectorID.allowedTactic

    /// Expected points the opponent must gain.
    public static let gainThreshold = 0.15
    /// Plies within which a tactic counts as shallow.
    public static let shallowHorizon = 2

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard context.deltaEP >= Self.gainThreshold else { return [] }
        guard let first = context.refutationSteps.first else { return [] }

        let createsWinningAttack = SEE.hasWinningCapture(position: first.positionAfter, by: context.opponent)
        guard first.givesCheck || first.isCapture || createsWinningAttack else { return [] }

        let steps = Array(context.refutationSteps.prefix(TacticThemeClassifier.defaultHorizon))
        let resolution = LineReplay.resolutionPly(steps, for: context.opponent)
            ?? (first.givesCheck ? 1 : steps.count)
        let subtype: FindingSubtype = resolution <= Self.shallowHorizon ? .shallow : .deep

        let theme = TacticThemeClassifier.detail(
            steps: steps,
            from: context.positionAfter,
            score: context.refutationLine?.score,
            maxPlies: TacticThemeClassifier.defaultHorizon
        )

        var flags: Set<FindingFlag> = []
        if first.isForcing { flags.insert(.refutationIsForcing) }
        if context.playedMoveIsForcing { flags.insert(.playedMoveForcing) }

        return [
            Finding(
                detector: id,
                subtype: subtype,
                squares: [first.move.start, first.move.end] + theme.squares,
                themes: [theme.theme],
                flags: flags,
                magnitude: context.deltaEP,
                detail: "Refutation \(first.uci) resolves in \(resolution) plies"
            )
        ]
    }
}
