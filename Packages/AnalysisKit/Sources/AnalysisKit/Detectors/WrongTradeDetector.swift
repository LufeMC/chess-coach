//
//  WrongTradeDetector.swift
//  AnalysisKit
//

import ChessKit

/// Finds captures that should not have been made.
///
/// Two different errors wear the same clothes. `.losesMaterial` is arithmetic —
/// the exchange simply drops material. `.badSimplification` is strategic — the
/// exchange is materially fine but trades pieces off while standing worse, which
/// is how a player with problems to solve removes their own chances of solving
/// them.
public struct WrongTradeDetector: Detector, Sendable {
    public let id = DetectorID.wrongTrade

    /// Below this expected-points level the mover is "worse" and should be
    /// keeping pieces on to retain counterplay.
    public static let worseThanEqualEP = 0.45
    /// Two pieces within this many centipawns count as an even trade (so a
    /// knight for a bishop qualifies).
    public static let equalMaterialTolerance = 100

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard case .capture(let captured) = context.playedMove.result else { return [] }
        guard context.judgment >= .inaccuracy else { return [] }

        let see = SEE.seeOfCapture(position: context.positionBefore, move: context.playedMove) ?? 0

        if see < 0 {
            return [
                Finding(
                    detector: id,
                    subtype: .losesMaterial,
                    squares: [context.playedMove.end],
                    flags: [.playedMoveForcing],
                    magnitude: Double(-see),
                    detail: "\(context.playedUCI) has SEE \(see)"
                )
            ]
        }

        guard isBadSimplification(context, captured: captured) else { return [] }

        return [
            Finding(
                detector: id,
                subtype: .badSimplification,
                squares: [context.playedMove.end],
                flags: [.playedMoveForcing],
                magnitude: context.deltaEP,
                detail: "Even trade of \(captured.kind.description) while worse"
            )
        ]
    }

    private func isBadSimplification(_ context: MoveContext, captured: Piece) -> Bool {
        guard EvalMath.expectedPoints(score: context.evalBefore) < Self.worseThanEqualEP else { return false }
        guard captured.kind != .pawn else { return false }

        // "Removes equal non-pawn material" — the opponent takes an equivalent
        // piece straight back, so the net effect is fewer pieces on the board
        // rather than a material change.
        guard let recapture = context.refutationMove, recapture.end == context.playedMove.end,
            case .capture(let recaptured) = recapture.result
        else { return false }
        let difference = abs(PieceValues.value(of: recaptured) - PieceValues.value(of: captured))
        guard difference <= Self.equalMaterialTolerance else { return false }

        // If the engine also wanted a capture, the problem is which capture, not
        // the decision to trade.
        guard let best = context.bestMove else { return false }
        if case .capture = best.result { return false }

        return true
    }
}
