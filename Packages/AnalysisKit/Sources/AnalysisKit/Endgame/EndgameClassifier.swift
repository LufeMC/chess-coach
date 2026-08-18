//
//  EndgameClassifier.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// The kind of ending on the board.
public enum EndgameType: String, Sendable, Codable, CaseIterable {
    /// King and pawn versus lone king — exactly solvable, see ``KPKBitbase``.
    case kpk
    /// A textbook forced mate with no pawns: KQK, KRK or KBBK.
    case basicMate
    /// Kings and pawns only, beyond KPK.
    case pawnEndgame
    /// Rooks (and pawns) only besides the kings.
    case rookEndgame
    case other

    var subtype: FindingSubtype {
        switch self {
        case .kpk: .kpk
        case .basicMate: .basicMate
        case .pawnEndgame: .pawnEndgame
        case .rookEndgame: .rookEndgame
        case .other: .otherEndgame
        }
    }
}

/// Which of the three results a position is heading for.
///
/// The ±200cp boundary is a deliberate compromise: tight enough that converting
/// a won ending into a draw registers, loose enough that endgame evaluation noise
/// (a passed pawn worth "+1.4" that is actually drawn) does not manufacture flips
/// on every move.
public enum ResultClass: String, Sendable, Codable {
    case winning
    case drawish
    case losing

    public static let boundary = 200

    public static func classify(_ score: UCIScore) -> ResultClass {
        let cp = score.centipawnValue()
        if cp >= boundary { return .winning }
        if cp <= -boundary { return .losing }
        return .drawish
    }
}

/// Recognises endgame types and the two rook-ending techniques every player is
/// taught first.
public enum EndgameClassifier {

    public static func classify(_ position: Position) -> EndgameType {
        let pieces = position.pieces
        let pawns = pieces.filter { $0.kind == .pawn }
        let others = pieces.filter { $0.kind != .king && $0.kind != .pawn }

        if pawns.count == 1, others.isEmpty, pieces.count == 3 { return .kpk }

        if pawns.isEmpty {
            for color in [Piece.Color.white, .black] {
                let mine = others.filter { $0.color == color }
                let theirs = others.filter { $0.color != color }
                guard theirs.isEmpty else { continue }
                if mine.count == 1, mine[0].kind == .queen || mine[0].kind == .rook { return .basicMate }
                if mine.count == 2, mine.allSatisfy({ $0.kind == .bishop }) { return .basicMate }
            }
        }

        if others.isEmpty { return .pawnEndgame }
        if others.allSatisfy({ $0.kind == .rook }) { return .rookEndgame }
        return .other
    }

    /// Signature of the Lucena position: the strong side's king is on the
    /// promotion square with its pawn on the seventh, the defending king is cut
    /// off, and a rook is available to build the bridge.
    ///
    /// This is a *signature*, not a proof — it recognises the picture the player
    /// should be reaching for so the coaching copy can name it. A full proof would
    /// need tablebases.
    public static func lucenaSignature(_ position: Position) -> Bool {
        guard case .some(let setup) = rookAndPawnSetup(position) else { return false }
        guard setup.pawn.square.relativeRank(for: setup.strong) == 7 else { return false }

        let promotionSquare = Square.offset(
            setup.pawn.square,
            files: 0,
            ranks: setup.strong == .white ? 1 : -1
        )
        guard let promotionSquare else { return false }
        guard setup.strongKing == promotionSquare else { return false }

        // The defending king must be shut out on the far side of the pawn's file.
        let fileGap = abs(setup.weakKing.fileIndex - setup.pawn.square.fileIndex)
        return fileGap >= 1 && setup.strongRook.square.fileIndex != setup.pawn.square.fileIndex
    }

    /// Signature of the Philidor defence: the defending rook sits on its third
    /// rank and the defending king is in front of the pawn, which has not yet
    /// reached the sixth.
    public static func philidorSignature(_ position: Position) -> Bool {
        guard case .some(let setup) = rookAndPawnSetup(position) else { return false }
        guard let weakRook = setup.weakRook else { return false }
        guard setup.pawn.square.relativeRank(for: setup.strong) <= 5 else { return false }
        // "Third rank" is counted from the defender's own side.
        guard weakRook.square.relativeRank(for: setup.weak) == 3 else { return false }
        return abs(setup.weakKing.fileIndex - setup.pawn.square.fileIndex) <= 1
            && setup.weakKing.relativeRank(for: setup.strong) > setup.pawn.square.relativeRank(for: setup.strong)
    }

    // MARK: Helpers

    private struct RookPawnSetup {
        let strong: Piece.Color
        let weak: Piece.Color
        let pawn: Piece
        let strongKing: Square
        let weakKing: Square
        let strongRook: Piece
        let weakRook: Piece?
    }

    /// Rook (+ single pawn) versus rook, from the pawn owner's point of view.
    private static func rookAndPawnSetup(_ position: Position) -> RookPawnSetup? {
        let pieces = position.pieces
        let pawns = pieces.filter { $0.kind == .pawn }
        guard pawns.count == 1, let pawn = pawns.first else { return nil }
        let rooks = pieces.filter { $0.kind == .rook }
        guard !rooks.isEmpty, rooks.count <= 2 else { return nil }
        guard pieces.count == 3 + rooks.count else { return nil }

        let strong = pawn.color
        guard let strongRook = rooks.first(where: { $0.color == strong }) else { return nil }
        let occupancy = Occupancy(position)
        guard let strongKing = occupancy.kingSquare(of: strong),
            let weakKing = occupancy.kingSquare(of: strong.opposite)
        else { return nil }

        return RookPawnSetup(
            strong: strong,
            weak: strong.opposite,
            pawn: pawn,
            strongKing: strongKing,
            weakKing: weakKing,
            strongRook: strongRook,
            weakRook: rooks.first(where: { $0.color != strong })
        )
    }
}
