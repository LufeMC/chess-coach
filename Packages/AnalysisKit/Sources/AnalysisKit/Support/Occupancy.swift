//
//  Occupancy.swift
//  AnalysisKit
//

import ChessKit

/// A mutable 64-square piece placement with attack geometry.
///
/// ## Why this exists rather than using `Board`
///
/// `ChessKit.Board` is a *rules* engine: every mutation goes through legality
/// checks, toggles the side to move, and updates draw counters. Static exchange
/// evaluation needs the opposite — it has to play out a sequence of captures
/// that are individually illegal (a pinned rook still recaptures in SEE), out of
/// turn, and it has to re-derive attackers against each intermediate occupancy
/// so that x-rays and batteries appear as the front piece vacates. There is no
/// public API on `Board` that allows that, and rebuilding a `Board` from a FEN
/// between every capture would be both slow and lossy.
///
/// So AnalysisKit keeps its own dumb placement array. Its attack semantics are
/// identical to the fork's `Board.attackers(of:by:)` — geometric, ignoring pins
/// and check — and `OccupancyParityTests` asserts that equivalence against
/// `Board` across a spread of positions so the two can never drift.
struct Occupancy: Sendable, Equatable {

    /// Indexed by `Square.rawValue` (a1 == 0 ... h8 == 63).
    private var squares: [Piece?]

    init(_ position: Position) {
        squares = Array(repeating: nil, count: 64)
        for piece in position.pieces {
            squares[piece.square.rawValue] = piece
        }
    }

    init(pieces: [Piece]) {
        squares = Array(repeating: nil, count: 64)
        for piece in pieces {
            squares[piece.square.rawValue] = piece
        }
    }

    // MARK: Access

    subscript(square: Square) -> Piece? {
        squares[square.rawValue]
    }

    var occupiedSquares: [Square] {
        squares.indices.compactMap { squares[$0] != nil ? Square(rawValue: $0) : nil }
    }

    func pieces(of color: Piece.Color) -> [Piece] {
        squares.compactMap { $0 }.filter { $0.color == color }
    }

    func kingSquare(of color: Piece.Color) -> Square? {
        squares.compactMap { $0 }.first { $0.color == color && $0.kind == .king }?.square
    }

    // MARK: Mutation

    mutating func remove(at square: Square) {
        squares[square.rawValue] = nil
    }

    mutating func place(_ piece: Piece, at square: Square) {
        var moved = piece
        moved.square = square
        squares[square.rawValue] = moved
    }

    /// Moves whatever stands on `from` to `to`, replacing any occupant.
    ///
    /// No legality checking whatsoever — that is the whole point.
    mutating func slide(from: Square, to: Square) {
        guard let piece = squares[from.rawValue] else { return }
        squares[from.rawValue] = nil
        place(piece, at: to)
    }

    // MARK: Attack geometry

    /// Every square holding a `color` piece that attacks `square`.
    ///
    /// Geometric only: pins and check are ignored, matching
    /// `Board.attackers(of:by:)`, because a pinned defender still influences an
    /// exchange sequence.
    func attackers(of square: Square, by color: Piece.Color) -> [Square] {
        var result: [Square] = []

        // Pawns. To find which white pawns hit `square`, look where a *black*
        // pawn standing on `square` would capture — the direction inverts.
        let pawnRankDelta = color == .white ? -1 : 1
        for fileDelta in [-1, 1] {
            if let from = offset(square, files: fileDelta, ranks: pawnRankDelta),
                let piece = self[from], piece.color == color, piece.kind == .pawn {
                result.append(from)
            }
        }

        for delta in Occupancy.knightDeltas {
            if let from = offset(square, files: delta.0, ranks: delta.1),
                let piece = self[from], piece.color == color, piece.kind == .knight {
                result.append(from)
            }
        }

        for delta in Occupancy.kingDeltas {
            if let from = offset(square, files: delta.0, ranks: delta.1),
                let piece = self[from], piece.color == color, piece.kind == .king {
                result.append(from)
            }
        }

        for direction in Occupancy.allDirections {
            guard let (from, piece) = firstOccupied(from: square, direction: direction) else { continue }
            guard piece.color == color else { continue }
            let isDiagonal = direction.0 != 0 && direction.1 != 0
            let matches = isDiagonal
                ? (piece.kind == .bishop || piece.kind == .queen)
                : (piece.kind == .rook || piece.kind == .queen)
            if matches { result.append(from) }
        }

        return result
    }

    func isAttacked(_ square: Square, by color: Piece.Color) -> Bool {
        !attackers(of: square, by: color).isEmpty
    }

    /// The cheapest `color` piece attacking `square`.
    ///
    /// SEE always recaptures with the least valuable attacker, so this is the
    /// primitive that drives the swap loop.
    func leastValuableAttacker(of square: Square, by color: Piece.Color) -> Piece? {
        attackers(of: square, by: color)
            .compactMap { self[$0] }
            .min { PieceValues.value(of: $0.kind) < PieceValues.value(of: $1.kind) }
    }

    /// Squares that `piece` attacks from where it currently stands.
    ///
    /// Pawns report only their capture squares — pushes are not attacks. Used by
    /// the fork detector and the discovered-attack test.
    func attackedSquares(from square: Square) -> [Square] {
        guard let piece = self[square] else { return [] }
        var result: [Square] = []

        switch piece.kind {
        case .pawn:
            let rankDelta = piece.color == .white ? 1 : -1
            for fileDelta in [-1, 1] {
                if let target = offset(square, files: fileDelta, ranks: rankDelta) {
                    result.append(target)
                }
            }
        case .knight:
            for delta in Occupancy.knightDeltas {
                if let target = offset(square, files: delta.0, ranks: delta.1) { result.append(target) }
            }
        case .king:
            for delta in Occupancy.kingDeltas {
                if let target = offset(square, files: delta.0, ranks: delta.1) { result.append(target) }
            }
        case .bishop, .rook, .queen:
            for direction in directions(for: piece.kind) {
                var current = square
                while let next = offset(current, files: direction.0, ranks: direction.1) {
                    result.append(next)
                    if self[next] != nil { break }
                    current = next
                }
            }
        }

        return result
    }

    /// The ray direction from `origin` to `target` if they are aligned, else nil.
    func direction(from origin: Square, to target: Square) -> (Int, Int)? {
        let fileDelta = target.fileIndex - origin.fileIndex
        let rankDelta = target.rankIndex - origin.rankIndex
        if fileDelta == 0 && rankDelta == 0 { return nil }
        if fileDelta == 0 { return (0, rankDelta > 0 ? 1 : -1) }
        if rankDelta == 0 { return (fileDelta > 0 ? 1 : -1, 0) }
        if abs(fileDelta) == abs(rankDelta) {
            return (fileDelta > 0 ? 1 : -1, rankDelta > 0 ? 1 : -1)
        }
        return nil
    }

    /// First occupied square walking `direction` from `square`, exclusive of it.
    func firstOccupied(from square: Square, direction: (Int, Int)) -> (Square, Piece)? {
        var current = square
        while let next = offset(current, files: direction.0, ranks: direction.1) {
            if let piece = self[next] { return (next, piece) }
            current = next
        }
        return nil
    }

    func directions(for kind: Piece.Kind) -> [(Int, Int)] {
        switch kind {
        case .bishop: Occupancy.diagonalDirections
        case .rook: Occupancy.straightDirections
        case .queen: Occupancy.allDirections
        default: []
        }
    }

    // MARK: Square arithmetic

    /// Square arithmetic that returns `nil` off the board.
    ///
    /// `Square.left`/`.up` clamp at the edges (returning the same square), which
    /// silently wraps logic into false positives, so all geometry here uses this
    /// instead.
    func offset(_ square: Square, files: Int, ranks: Int) -> Square? {
        Square.offset(square, files: files, ranks: ranks)
    }

    static let knightDeltas: [(Int, Int)] = [
        (1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)
    ]
    static let kingDeltas: [(Int, Int)] = [
        (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)
    ]
    static let diagonalDirections: [(Int, Int)] = [(1, 1), (1, -1), (-1, -1), (-1, 1)]
    static let straightDirections: [(Int, Int)] = [(0, 1), (1, 0), (0, -1), (-1, 0)]
    static var allDirections: [(Int, Int)] { straightDirections + diagonalDirections }

    static func == (lhs: Occupancy, rhs: Occupancy) -> Bool {
        lhs.squares == rhs.squares
    }
}

// MARK: - Square helpers

extension Square {
    /// 0-based file index, a == 0.
    var fileIndex: Int { rawValue % 8 }
    /// 0-based rank index, rank 1 == 0.
    var rankIndex: Int { rawValue / 8 }

    /// Bounded square arithmetic; `nil` when the result leaves the board.
    static func offset(_ square: Square, files: Int, ranks: Int) -> Square? {
        let file = square.fileIndex + files
        let rank = square.rankIndex + ranks
        guard (0...7).contains(file), (0...7).contains(rank) else { return nil }
        return Square(rawValue: rank * 8 + file)
    }

    /// Rank counted from `color`'s own side: 1 is that colour's back rank.
    func relativeRank(for color: Piece.Color) -> Int {
        color == .white ? rankIndex + 1 : 8 - rankIndex
    }
}
