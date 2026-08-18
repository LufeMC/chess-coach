//
//  Zobrist.swift
//  ChessKit
//
//  Local addition to this fork — not present upstream.
//

/// Stable, process-independent position hashing.
///
/// `Position` conforms to `Hashable` using Swift's `Hasher`, which is seeded
/// randomly per process. That is fine for in-memory dictionaries and wrong for
/// anything persisted: the same position yields a different `hashValue` on the
/// next launch. Zobrist keys are computed from a fixed table, so they are
/// identical across launches, devices, and platforms — safe as a SQLite key and
/// as a transposition identity for repetition detection.
enum Zobrist {

    /// Deterministic 64-bit PRNG (splitmix64). Using a fixed algorithm and seed
    /// rather than `SystemRandomNumberGenerator` is what makes the table — and
    /// therefore every key derived from it — reproducible.
    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// [colorIndex][kindIndex][squareIndex] — 2 colors × 6 kinds × 64 squares.
    private static let pieceKeys: [[[UInt64]]] = {
        var rng = SplitMix64(state: 0x00C0_FFEE_5EED_1234)
        return (0..<2).map { _ in
            (0..<6).map { _ in
                (0..<64).map { _ in rng.next() }
            }
        }
    }()

    /// One key per castling right, in a fixed order.
    private static let castlingKeys: [UInt64] = {
        var rng = SplitMix64(state: 0x0BAD_C0DE_1357_9BDF)
        return (0..<4).map { _ in rng.next() }
    }()

    /// One key per en passant *file* (not square — only the file is legally
    /// relevant, matching FEN and standard Zobrist practice).
    private static let enPassantFileKeys: [UInt64] = {
        var rng = SplitMix64(state: 0x1234_5678_9ABC_DEF0)
        return (0..<8).map { _ in rng.next() }
    }()

    /// XORed in when it is Black to move.
    private static let blackToMoveKey: UInt64 = {
        var rng = SplitMix64(state: 0xFEED_FACE_CAFE_BEEF)
        return rng.next()
    }()

    private static func kindIndex(_ kind: Piece.Kind) -> Int {
        switch kind {
        case .pawn: 0
        case .knight: 1
        case .bishop: 2
        case .rook: 3
        case .queen: 4
        case .king: 5
        }
    }

    private static func colorIndex(_ color: Piece.Color) -> Int {
        color == .white ? 0 : 1
    }

    /// Computes the Zobrist key for a position.
    ///
    /// Covers exactly the components that make two positions the same for
    /// repetition purposes: piece placement, side to move, castling rights, and
    /// a *capturable* en passant file. The halfmove and fullmove clocks are
    /// deliberately excluded — two positions that differ only by clock are the
    /// same position under the threefold rule.
    static func key(for position: Position) -> UInt64 {
        var key: UInt64 = 0

        for piece in position.pieces {
            key ^= pieceKeys[colorIndex(piece.color)][kindIndex(piece.kind)][piece.square.rawValue]
        }

        if position.sideToMove == .black {
            key ^= blackToMoveKey
        }

        let castlings: [Castling] = [.wK, .wQ, .bK, .bQ]
        for (index, castling) in castlings.enumerated() where position.legalCastlings.contains(castling) {
            key ^= castlingKeys[index]
        }

        // Only a *possible* en passant capture changes the position's identity.
        // A pawn that just double-stepped with no enemy pawn able to take it
        // leaves the position identical to one reached without the double step.
        if position.enPassantIsPossible, let enPassant = position.enPassant {
            key ^= enPassantFileKeys[enPassant.captureSquare.file.number - 1]
        }

        return key
    }
}

extension Position {

    /// A stable 64-bit identity for this position, safe to persist.
    ///
    /// Unlike `hashValue`, this is identical across processes and devices. Use
    /// it as the position key in storage and for repetition detection; never
    /// persist `hashValue`.
    public var zobristKey: UInt64 {
        Zobrist.key(for: self)
    }
}
