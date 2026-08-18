//
//  Phase.swift
//  AnalysisKit
//

import ChessKit

/// Which part of the game a position belongs to.
public enum Phase: String, Sendable, Codable, CaseIterable {
    case opening
    case middlegame
    case endgame

    /// Ply (half-move number, 1-based) through which a position still counts as
    /// the opening.
    public static let openingPlyLimit = 20
    /// At or below this many non-king, non-pawn pieces the position is an
    /// endgame — one queen plus a minor per side, or two rooks per side, is the
    /// boundary case.
    public static let endgamePieceLimit = 6

    /// Classifies a position.
    ///
    /// - parameter ply: 1-based half-move number of the move about to be played
    ///   (White's first move is ply 1).
    ///
    /// - note: The material test is applied **before** the ply test, which is a
    ///   deliberate deviation from a literal reading of the spec's ordering. A
    ///   hand-built K+P vs K study is an endgame whether it arises on ply 4 or
    ///   ply 80, and `endgameTechniqueError` — including the exact KPK bitbase —
    ///   keys off this classification. In real games the two orderings almost
    ///   never disagree: reaching six or fewer pieces inside twenty plies takes
    ///   eight captures.
    public static func classify(position: Position, ply: Int) -> Phase {
        if PositionUtilities.heavyAndMinorPieceCount(position) <= endgamePieceLimit { return .endgame }
        if ply <= openingPlyLimit { return .opening }
        return .middlegame
    }
}
