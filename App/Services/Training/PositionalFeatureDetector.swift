//
//  PositionalFeatureDetector.swift
//  ChessCoach
//

import ChessKit

/// Recognises the positional idea behind a quiet move.
///
/// ## Why the positions are found rather than written
///
/// Positional exercises cannot be hand-built. In a constructed position the
/// engine finds a tactic and the "positional" answer comes second — every
/// candidate written by hand failed that check against Stockfish, without
/// exception.
///
/// So the positions come from the corpus. Lichess has already tagged thousands
/// of puzzles as quiet moves and already verified their answers; all that is
/// missing is *which idea* each one is about. That is what this file adds: it
/// replays the answer and asks what the move did. A position only becomes an
/// outpost exercise if the move genuinely lands a piece on a square no enemy
/// pawn can ever attack.
///
/// Each detector is deliberately strict. A wrong classification is worse than
/// no exercise, because it teaches the pattern with an example that does not
/// contain it — and the user cannot tell.
enum PositionalFeatureDetector {

    /// Whether `uci`, played in `position`, is an example of `feature`.
    static func matches(_ feature: PositionalFeature, uci: String, in position: Position) -> Bool {
        guard let origin = PuzzleConcept.origin(ofUCI: uci),
            let destination = PuzzleConcept.destination(ofUCI: uci),
            let mover = position.piece(at: origin)
        else { return false }

        switch feature {
        case .outpost:
            return isOutpost(mover: mover, to: destination, in: position)
        case .openFile:
            return isOpenFile(mover: mover, from: origin, to: destination, in: position)
        case .blockade:
            return isBlockade(mover: mover, to: destination, in: position)
        case .worstPiece:
            return isWorstPiece(mover: mover, from: origin, in: position)
        }
    }

    /// Every feature this move is an example of.
    static func features(ofMove uci: String, in position: Position) -> [PositionalFeature] {
        PositionalFeature.allCases.filter { matches($0, uci: uci, in: position) }
    }

    // MARK: Outpost

    /// A minor piece landing where no enemy pawn can ever attack it, backed by
    /// a pawn of its own.
    ///
    /// "Can ever" is the important half: a square an enemy pawn could reach in
    /// three moves is not an outpost, and checking only the current attackers
    /// would call every empty square one.
    private static func isOutpost(mover: Piece, to destination: Square, in position: Position) -> Bool {
        guard mover.kind == .knight || mover.kind == .bishop else { return false }
        // Must be advanced: an "outpost" on your own second rank is just a piece.
        guard relativeRank(of: destination, for: mover.color) >= 4 else { return false }
        guard !anyEnemyPawnCanAttack(destination, mover: mover, in: position) else { return false }
        return isDefendedByOwnPawn(destination, color: mover.color, in: position)
    }

    /// Whether an enemy pawn on a neighbouring file is still behind `square`
    /// and could therefore advance to attack it.
    private static func anyEnemyPawnCanAttack(
        _ square: Square,
        mover: Piece,
        in position: Position
    ) -> Bool {
        let file = square.file.number
        let rank = relativeRank(of: square, for: mover.color)

        return position.pieces.contains { piece in
            guard piece.kind == .pawn, piece.color != mover.color else { return false }
            guard abs(piece.square.file.number - file) == 1 else { return false }
            // Still behind the square from the enemy's point of view, so it can
            // advance onto a square that attacks it.
            return relativeRank(of: piece.square, for: mover.color) > rank
        }
    }

    private static func isDefendedByOwnPawn(
        _ square: Square,
        color: Piece.Color,
        in position: Position
    ) -> Bool {
        let file = square.file.number
        let rank = relativeRank(of: square, for: color)

        return position.pieces.contains { piece in
            guard piece.kind == .pawn, piece.color == color else { return false }
            guard abs(piece.square.file.number - file) == 1 else { return false }
            return relativeRank(of: piece.square, for: color) == rank - 1
        }
    }

    // MARK: Open file

    /// A rook or queen stepping onto a file with no pawns of either colour.
    private static func isOpenFile(
        mover: Piece,
        from origin: Square,
        to destination: Square,
        in position: Position
    ) -> Bool {
        guard mover.kind == .rook || mover.kind == .queen else { return false }
        // Already on it is not "taking" it.
        guard origin.file != destination.file else { return false }
        return !position.pieces.contains {
            $0.kind == .pawn && $0.square.file == destination.file
        }
    }

    // MARK: Blockade

    /// A piece landing directly in front of an isolated enemy pawn.
    ///
    /// Isolated because that is the pawn worth blockading: one with neighbours
    /// can be supported and eventually pushed past, and calling that a blockade
    /// would teach the idea with an example that does not hold.
    private static func isBlockade(mover: Piece, to destination: Square, in position: Position) -> Bool {
        guard mover.kind != .pawn else { return false }
        guard let ahead = square(from: destination, forwardBy: 1, for: mover.color) else { return false }
        guard let blocked = position.piece(at: ahead),
            blocked.kind == .pawn,
            blocked.color != mover.color
        else { return false }

        let file = ahead.file.number
        return !position.pieces.contains {
            $0.kind == .pawn && $0.color == blocked.color
                && abs($0.square.file.number - file) == 1
        }
    }

    // MARK: Worst piece

    /// The moved piece had fewer squares available than any of its owner's
    /// other pieces, and few enough to be worth calling stuck.
    private static func isWorstPiece(mover: Piece, from origin: Square, in position: Position) -> Bool {
        guard mover.kind != .pawn, mover.kind != .king else { return false }

        var probe = Board(position: position)
        var counts: [Square: Int] = [:]
        for piece in position.pieces
        where piece.color == mover.color && piece.kind != .pawn && piece.kind != .king {
            counts[piece.square] = probe.legalMoves(forPieceAt: piece.square).count
        }

        // With one or two pieces left, "your worst piece" is not an idea, it is
        // an arithmetic accident.
        guard counts.count >= 3, let mine = counts[origin], let fewest = counts.values.min() else {
            return false
        }
        return mine == fewest && mine <= 3
    }

    // MARK: Geometry

    /// Rank counted from `color`'s own back rank, so one rule covers both sides.
    private static func relativeRank(of square: Square, for color: Piece.Color) -> Int {
        color == .white ? square.rank.value : 9 - square.rank.value
    }

    private static func square(from square: Square, forwardBy steps: Int, for color: Piece.Color) -> Square? {
        let rank = square.rank.value + (color == .white ? steps : -steps)
        guard (1...8).contains(rank) else { return nil }
        return Square("\(square.file.rawValue)\(rank)")
    }
}
