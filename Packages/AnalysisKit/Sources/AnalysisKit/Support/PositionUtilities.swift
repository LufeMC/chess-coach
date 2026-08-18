//
//  PositionUtilities.swift
//  AnalysisKit
//

import ChessKit

/// Legality queries that `ChessKit.Board` does not expose directly.
///
/// `Board.state` is computed for the side that just moved, so on a board built
/// straight from a FEN it reports on the side that is *not* to move. That makes
/// it unusable for "is the player to move in check / mated", which several
/// detectors need, so those answers are derived here from move generation and
/// ``Occupancy`` instead.
public enum PositionUtilities {

    /// Whether `color`'s king is attacked in `position`.
    public static func isInCheck(_ position: Position, color: Piece.Color) -> Bool {
        let occupancy = Occupancy(position)
        guard let king = occupancy.kingSquare(of: color) else { return false }
        return occupancy.isAttacked(king, by: color.opposite)
    }

    /// All legal (start, end) pairs for the side to move.
    ///
    /// Promotions appear once per destination square; the promotion piece is
    /// assumed to be a queen, which is all any caller here needs.
    public static func legalMovePairs(in position: Position) -> [(start: Square, end: Square)] {
        let board = Board(position: position)
        let occupancy = Occupancy(position)
        return occupancy.pieces(of: position.sideToMove).flatMap { piece in
            board.legalMoves(forPieceAt: piece.square).map { (piece.square, $0) }
        }
    }

    /// All legal moves for the side to move, materialised as `Move` values.
    ///
    /// Each move is produced by replaying it on a fresh board, so `checkState`
    /// and capture information are populated.
    public static func legalMoves(in position: Position) -> [Move] {
        legalMovePairs(in: position).compactMap { pair in
            var board = Board(position: position)
            return board.move(pieceAt: pair.start, to: pair.end)
        }
    }

    public static func hasLegalMove(in position: Position) -> Bool {
        let board = Board(position: position)
        let occupancy = Occupancy(position)
        return occupancy.pieces(of: position.sideToMove).contains {
            !board.legalMoves(forPieceAt: $0.square).isEmpty
        }
    }

    public static func isCheckmate(_ position: Position) -> Bool {
        isInCheck(position, color: position.sideToMove) && !hasLegalMove(in: position)
    }

    public static func isStalemate(_ position: Position) -> Bool {
        !isInCheck(position, color: position.sideToMove) && !hasLegalMove(in: position)
    }

    /// Non-king, non-pawn pieces on the board — the material count that decides
    /// the endgame phase.
    public static func heavyAndMinorPieceCount(_ position: Position) -> Int {
        position.pieces.filter { $0.kind != .king && $0.kind != .pawn }.count
    }

    /// Whether the given file (0-based, a == 0) has no pawns of either colour.
    public static func isFileOpen(_ fileIndex: Int, in position: Position) -> Bool {
        !position.pieces.contains { $0.kind == .pawn && $0.square.fileIndex == fileIndex }
    }

    /// The squares that make up `color`'s king zone: the king's file ±1 across
    /// `color`'s own first three ranks.
    ///
    /// Used both for "this pawn move loosened the king" (restricted to ranks 2-3
    /// by the detector) and for "the refutation landed next to the king".
    public static func kingZone(of color: Piece.Color, in position: Position) -> Set<Square> {
        let occupancy = Occupancy(position)
        guard let king = occupancy.kingSquare(of: color) else { return [] }
        var zone: Set<Square> = []
        for fileDelta in -1...1 {
            for relativeRank in 1...3 {
                let rankIndex = color == .white ? relativeRank - 1 : 8 - relativeRank
                let fileIndex = king.fileIndex + fileDelta
                guard (0...7).contains(fileIndex), (0...7).contains(rankIndex) else { continue }
                if let square = Square(rawValue: rankIndex * 8 + fileIndex) { zone.insert(square) }
            }
        }
        return zone
    }
}

/// Builds the "what if I could pass?" position used to probe for threats.
///
/// A null move hands the turn to the opponent without changing the board. If the
/// engine's evaluation jumps when the opponent gets a free move, the opponent
/// was threatening something — that is the whole idea behind `ignoredThreat`.
public enum NullMove {

    /// The FEN of `position` with the side to move flipped and en passant
    /// cleared.
    ///
    /// - returns: `nil` when the side to move is in check. A null move is
    ///   illegal there (you cannot "pass" out of check), and the resulting FEN
    ///   would describe a position with a king capturable in one, which makes the
    ///   engine's answer meaningless.
    public static func probeFEN(for position: Position) -> String? {
        guard !PositionUtilities.isInCheck(position, color: position.sideToMove) else { return nil }

        var fields = position.fen.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }

        fields[1] = position.sideToMove == .white ? "b" : "w"
        // The en passant target belongs to the side that is losing the move; it
        // cannot survive a pass.
        fields[3] = "-"
        if fields.count >= 5 { fields[4] = "0" }
        if fields.count >= 6, position.sideToMove == .black, let fullmoves = Int(fields[5]) {
            fields[5] = String(fullmoves + 1)
        }

        return fields.joined(separator: " ")
    }

    /// The position a null move produces, if one is legal.
    public static func probePosition(for position: Position) -> Position? {
        probeFEN(for: position).flatMap(Position.init(fen:))
    }
}
