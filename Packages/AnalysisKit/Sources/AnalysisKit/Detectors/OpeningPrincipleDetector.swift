//
//  OpeningPrincipleDetector.swift
//  AnalysisKit
//

import ChessKit

/// Checks the three opening rules a beginner most often breaks.
///
/// Deliberately engine-free: these are knowledge gaps, not calculation errors,
/// and they are worth naming even when the engine barely notices. Everything here
/// comes from the position and the move list, so it costs nothing to run and
/// stays meaningful when the engine's own preference is some deep sideline.
public struct OpeningPrincipleDetector: Detector, Sendable {
    public let id = DetectorID.openingPrinciple

    /// Repeating a piece move after this full-move number is normal play, not a
    /// development error.
    public static let repeatedMoveLimit = 8
    /// By this full-move number the king should have found a home.
    public static let castlingLimit = 14
    /// Minor pieces that should be out before the queen comes into play.
    public static let minorsBeforeQueen = 2

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        var findings: [Finding] = []

        if let finding = earlyQueen(context) { findings.append(finding) }
        if let finding = repeatedPieceMove(context) { findings.append(finding) }
        if let finding = delayedCastling(context) { findings.append(finding) }

        return findings
    }

    // MARK: Rules

    private func earlyQueen(_ context: MoveContext) -> Finding? {
        guard context.judgment >= .inaccuracy else { return nil }
        guard context.playedMove.piece.kind == .queen else { return nil }
        let developed = developedMinorCount(context.positionBefore, color: context.mover)
        guard developed < Self.minorsBeforeQueen else { return nil }

        return Finding(
            detector: id,
            subtype: .earlyQueen,
            squares: [context.playedMove.start, context.playedMove.end],
            magnitude: context.deltaEP,
            detail: "Queen moved with only \(developed) minor piece(s) developed"
        )
    }

    private func repeatedPieceMove(_ context: MoveContext) -> Finding? {
        guard context.judgment >= .inaccuracy else { return nil }
        guard context.playedMove.piece.kind != .pawn else { return nil }
        guard context.positionBefore.clock.fullmoves < Self.repeatedMoveLimit else { return nil }

        // Piece identity is tracked by following squares: if one of the mover's
        // earlier moves finished where this move starts, it is the same piece
        // moving again (barring a capture-and-replace on that square, which is
        // rare enough in the first eight moves to accept).
        let movedBefore = context.priorMoves.contains {
            $0.piece.color == context.mover && $0.end == context.playedMove.start && $0.piece.kind != .pawn
        }
        guard movedBefore else { return nil }

        return Finding(
            detector: id,
            subtype: .repeatedPieceMove,
            squares: [context.playedMove.start, context.playedMove.end],
            magnitude: context.deltaEP,
            detail: "\(context.playedMove.piece.kind.description) moved twice before move \(Self.repeatedMoveLimit)"
        )
    }

    /// The judgment gate matters more here than for the other two rules.
    ///
    /// `earlyQueen` and `repeatedPieceMove` describe the *move*, so they can only
    /// fire on the move that broke the principle. This one describes the
    /// *position*, and an uncastled king next to an open central file is still
    /// there on the following move, and the one after that. Ungated it fires on
    /// every move from move 14 until the king finds a home, which costs three
    /// separate things: findings bypass ``CauseTagger/fallbackMapping(_:)``, so a
    /// perfectly sound move ends up with a primary cause of `openingPrinciple`; a
    /// reinforcement moment in that span carries a mistake-flavoured tag; and
    /// every real mistake in between collects a knowledge tag it did not earn in
    /// its secondary tags.
    private func delayedCastling(_ context: MoveContext) -> Finding? {
        guard context.judgment >= .inaccuracy else { return nil }
        guard context.positionBefore.clock.fullmoves >= Self.castlingLimit else { return nil }
        guard !hasCastled(context) else { return nil }
        guard EvalMath.expectedPoints(score: context.evalBefore) <= 0.5 else { return nil }

        let centralFiles = [3, 4]  // d and e
        let openFiles = centralFiles.filter { PositionUtilities.isFileOpen($0, in: context.positionBefore) }
        guard !openFiles.isEmpty else { return nil }

        let occupancy = Occupancy(context.positionBefore)
        let king = occupancy.kingSquare(of: context.mover)

        return Finding(
            detector: id,
            subtype: .delayedCastling,
            squares: [king].compactMap { $0 },
            magnitude: context.deltaEP,
            detail: "Uncastled on move \(context.positionBefore.clock.fullmoves) with an open central file"
        )
    }

    // MARK: Helpers

    private func hasCastled(_ context: MoveContext) -> Bool {
        context.priorMoves.contains {
            guard $0.piece.color == context.mover else { return false }
            if case .castle = $0.result { return true }
            return false
        }
    }

    private func developedMinorCount(_ position: Position, color: Piece.Color) -> Int {
        let homeRank = color == .white ? 0 : 7
        let knightFiles = [1, 6]
        let bishopFiles = [2, 5]
        return position.pieces.filter { piece in
            guard piece.color == color else { return false }
            switch piece.kind {
            case .knight:
                return !(piece.square.rankIndex == homeRank && knightFiles.contains(piece.square.fileIndex))
            case .bishop:
                return !(piece.square.rankIndex == homeRank && bishopFiles.contains(piece.square.fileIndex))
            default:
                return false
            }
        }.count
    }
}
