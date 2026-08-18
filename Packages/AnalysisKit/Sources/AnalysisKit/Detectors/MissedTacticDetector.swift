//
//  MissedTacticDetector.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Finds positions where a concrete tactic was available and was not played.
///
/// "Tactical" is defined narrowly on purpose: inside the first six plies of the
/// best line the player has to give a check or a capture, **and** the line has to
/// actually win something. Without the second half every quiet build-up move that
/// happens to include a recapture would be reported as a missed tactic.
public struct MissedTacticDetector: Detector, Sendable {
    public let id = DetectorID.missedTactic

    /// Plies of the best line examined.
    public static let horizon = 6
    /// Centipawns the line must net for it to count as winning something.
    public static let materialThreshold = 150

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard context.judgment >= .inaccuracy else { return [] }
        let steps = Array(context.bestLineSteps.prefix(Self.horizon))
        guard !steps.isEmpty else { return [] }

        let moverForcesSomething = steps.contains { $0.mover == context.mover && ($0.givesCheck || $0.isCapture) }
        guard moverForcesSomething else { return [] }

        let swing = LineReplay.materialSwing(steps, for: context.mover)
        let isMate = isMateScore(context.bestLine.score) || steps.last?.move.checkState == .checkmate
        guard swing >= Self.materialThreshold || isMate else { return [] }

        let theme = TacticThemeClassifier.classify(
            steps: steps,
            from: context.positionBefore,
            score: context.bestLine.score,
            maxPlies: Self.horizon
        )

        var flags: Set<FindingFlag> = []
        if context.playedMoveIsForcing { flags.insert(.playedMoveForcing) }
        if context.bestMoveIsQuiet { flags.insert(.bestMoveQuiet) }

        return [
            Finding(
                detector: id,
                subtype: context.playedMoveIsForcing ? .playedForcing : .playedQuiet,
                squares: [steps[0].move.start, steps[0].move.end],
                themes: [theme],
                flags: flags,
                magnitude: isMate ? Double(PieceValues.queen) : Double(swing),
                detail: "Best line \(steps.map(\.uci).joined(separator: " ")) nets \(swing)cp"
            )
        ]
    }

    private func isMateScore(_ score: UCIScore) -> Bool {
        if case .mate(let n) = score { return n > 0 }
        return false
    }
}
