//
//  KingWeakeningPawnMoveDetector.swift
//  AnalysisKit
//

import ChessKit

/// Finds pawn moves that loosened the player's own king.
///
/// The gating conditions matter as much as the pattern. In an endgame the same
/// pawn move is often correct (the king wants luft and there is nothing left to
/// attack with), and against an opponent with no queen the shelter is far less
/// load-bearing — so both are required before the move is judged at all.
public struct KingWeakeningPawnMoveDetector: Detector, Sendable {
    public let id = DetectorID.kingWeakeningPawnMove

    /// Plies of the opponent's line scanned for a punishing follow-up.
    public static let punishHorizon = 4

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard context.playedMove.piece.kind == .pawn else { return [] }
        guard context.phase != .endgame else { return [] }
        guard context.judgment >= .inaccuracy else { return [] }
        guard opponentCanAttack(context) else { return [] }

        let occupancy = Occupancy(context.positionBefore)
        guard let king = occupancy.kingSquare(of: context.mover) else { return [] }

        let start = context.playedMove.start
        let inKingFiles = abs(start.fileIndex - king.fileIndex) <= 1
        let shelterRank = (2...3).contains(start.relativeRank(for: context.mover))
        guard inKingFiles, shelterRank else { return [] }

        let zone = PositionUtilities.kingZone(of: context.mover, in: context.positionAfter)
        let punished = context.refutationSteps
            .prefix(Self.punishHorizon)
            .contains { $0.mover == context.opponent && ($0.givesCheck || zone.contains($0.move.end)) }

        return [
            Finding(
                detector: id,
                subtype: punished ? .tacticalPunish : .positional,
                squares: [start, context.playedMove.end],
                flags: punished ? [.refutationIsForcing] : [],
                magnitude: context.deltaEP,
                detail: "Pawn \(context.playedUCI) left the king zone around \(king.notation)"
            )
        ]
    }

    /// The opponent still has a queen and at least one other piece — the minimum
    /// force needed to make a loosened king a real liability.
    private func opponentCanAttack(_ context: MoveContext) -> Bool {
        let pieces = Occupancy(context.positionAfter).pieces(of: context.opponent)
        let hasQueen = pieces.contains { $0.kind == .queen }
        let supportingPieces = pieces.filter { $0.kind != .queen && $0.kind != .king && $0.kind != .pawn }
        return hasQueen && supportingPieces.count >= 1
    }
}
