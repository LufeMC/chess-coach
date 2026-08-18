//
//  Board+Attacks.swift
//  ChessKit
//
//  Local addition to this fork — not present upstream.
//

/// Public attack queries.
///
/// Upstream keeps its attack machinery private and exposes only `legalMoves`,
/// which is insufficient for analysis: `legalMoves` excludes moves onto one's
/// own pieces, so it can tell you what a piece can *capture* but never what it
/// *defends*. Static exchange evaluation and hanging-piece detection both need
/// the full attacker/defender picture, so this fork surfaces the underlying
/// bitboard queries.
extension Board {

    /// Every square occupied by a `color` piece that attacks `square`.
    ///
    /// "Attacks" here is geometric and ignores pins and check: a pinned rook
    /// still defends the squares it bears on, which is exactly the semantics
    /// static exchange evaluation needs.
    ///
    /// - parameter square: The target square.
    /// - parameter color: The attacking side.
    /// - returns: The squares holding attackers, unordered.
    public func attackers(of square: Square, by color: Piece.Color) -> [Square] {
        attackerBitboard(of: square, by: color).squares
    }

    /// Whether any `color` piece attacks `square`.
    ///
    /// Cheaper than `attackers(of:by:)` when only the yes/no answer is needed.
    public func isSquareAttacked(_ square: Square, by color: Piece.Color) -> Bool {
        attackerBitboard(of: square, by: color) != 0
    }

    /// The lowest-valued `color` piece attacking `square`, if any.
    ///
    /// Static exchange evaluation always recaptures with the least valuable
    /// attacker, so this is the primitive that drives the swap loop.
    public func leastValuableAttacker(of square: Square, by color: Piece.Color) -> Piece? {
        let attackers = attackerBitboard(of: square, by: color)
        guard attackers != 0 else { return nil }

        // Ordered cheapest-first; the first hit wins.
        let order: [Piece.Kind] = [.pawn, .knight, .bishop, .rook, .queen, .king]
        for kind in order {
            for attackerSquare in attackers.squares {
                if let piece = position.piece(at: attackerSquare),
                    piece.kind == kind,
                    piece.color == color
                {
                    return piece
                }
            }
        }
        return nil
    }

    /// Bitboard of `color` pieces attacking `square`.
    ///
    /// Mirrors the private `attackers(to:set:)` but filters to one side. Pawn
    /// attack direction is inverted deliberately: to find which white pawns
    /// attack a square, look at where a *black* pawn on that square could
    /// capture.
    func attackerBitboard(of square: Square, by color: Piece.Color) -> Bitboard {
        let set = position.pieceSet
        let sq = square.bb
        let us = set.get(color)

        let pawns = color == .white ? set.P : set.p
        let pawnAttackers = pawnCaptureMask(color.opposite, from: sq) & pawns

        let knights = Attacks.knights[sq, default: 0] & set.knights & us
        let kings = Attacks.kings[sq, default: 0] & set.kings & us
        let diagonal = Attacks.bishops.attacks(from: square, for: set.all) & set.diagonals & us
        let straight = Attacks.rooks.attacks(from: square, for: set.all) & set.lines & us

        return pawnAttackers | knights | kings | diagonal | straight
    }

    /// Squares a pawn of `color` standing on `sq` would capture on.
    private func pawnCaptureMask(_ color: Piece.Color, from sq: Bitboard) -> Bitboard {
        switch color {
        case .white: sq.northWest() | sq.northEast()
        case .black: sq.southWest() | sq.southEast()
        }
    }
}
