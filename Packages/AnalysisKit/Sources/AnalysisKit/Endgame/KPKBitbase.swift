//
//  KPKBitbase.swift
//  AnalysisKit
//

import ChessKit

/// The exact result of a king-and-pawn versus king position, with best play.
public enum KPKOutcome: String, Sendable, Codable {
    /// The side with the pawn wins.
    case win
    /// Drawn.
    case draw
}

/// An exact king + pawn versus king bitbase, built by retrograde analysis on
/// first use.
///
/// ## Why a bitbase and not the engine
///
/// KPK is the one endgame where a shallow engine evaluation is actively
/// misleading: the difference between a win and a draw is a single tempo, and a
/// depth-limited search reports "+2.3" for positions that are dead drawn. Since
/// this is exactly where beginners lose half points, the app needs the truth
/// rather than an approximation — and the same table later drives a drill mode
/// where every position must be labelled correctly.
///
/// ## Layout
///
/// The index space is `2 × 64 × 64 × 24`: side to move, strong king, weak king,
/// and the pawn restricted to files a-d and ranks 2-7 (the other half of the
/// board is reached by mirroring). That is 196,608 entries, stored one bit each —
/// 24KB, built in a fraction of a second and then immutable and `Sendable`.
///
/// The construction is the standard retrograde fixpoint: mark the positions whose
/// result is immediate, then repeatedly resolve unknown positions from their
/// successors until nothing changes. A win for the strong side propagates
/// backwards through "there exists a winning move"; a draw propagates through
/// "every move draws".
public enum KPKBitbase {

    // MARK: Public API

    /// Probes the bitbase for a KPK position.
    ///
    /// - parameter strongSide: The colour that owns the pawn.
    /// - parameter strongKing: The strong side's king.
    /// - parameter pawn: The pawn.
    /// - parameter weakKing: The bare king.
    /// - parameter sideToMove: Whose turn it is.
    public static func probe(
        strongSide: Piece.Color,
        strongKing: Square,
        pawn: Square,
        weakKing: Square,
        sideToMove: Piece.Color
    ) -> KPKOutcome {
        // Normalise to "white owns the pawn": flip the board vertically for a
        // black pawn, then mirror horizontally so the pawn sits on files a-d.
        var strong = strongKing
        var pawnSquare = pawn
        var weak = weakKing
        let strongToMove = sideToMove == strongSide

        if strongSide == .black {
            strong = flipRank(strong)
            pawnSquare = flipRank(pawnSquare)
            weak = flipRank(weak)
        }
        if pawnSquare.fileIndex > 3 {
            strong = flipFile(strong)
            pawnSquare = flipFile(pawnSquare)
            weak = flipFile(weak)
        }

        // Pawns cannot stand on the first or last rank; a caller handing us one
        // has a promotion, not a KPK position.
        guard (1...6).contains(pawnSquare.rankIndex) else { return .draw }

        let pawnIndex = (pawnSquare.rankIndex - 1) * 4 + pawnSquare.fileIndex
        let index = Self.index(
            strongToMove: strongToMove ? 0 : 1,
            strongKing: strong.rawValue,
            weakKing: weak.rawValue,
            pawnIndex: pawnIndex
        )
        return table.isWin(index) ? .win : .draw
    }

    /// Probes a position, if it is a KPK position at all.
    ///
    /// - returns: `nil` when the material is not king + pawn versus lone king.
    public static func probe(position: Position) -> KPKOutcome? {
        let pieces = position.pieces
        guard pieces.count == 3 else { return nil }
        guard let pawn = pieces.first(where: { $0.kind == .pawn }) else { return nil }
        let kings = pieces.filter { $0.kind == .king }
        guard kings.count == 2 else { return nil }
        guard let strongKing = kings.first(where: { $0.color == pawn.color }),
            let weakKing = kings.first(where: { $0.color != pawn.color })
        else { return nil }

        return probe(
            strongSide: pawn.color,
            strongKing: strongKing.square,
            pawn: pawn.square,
            weakKing: weakKing.square,
            sideToMove: position.sideToMove
        )
    }

    /// Number of index slots. Exposed for tests that walk the whole table.
    public static let indexCount = 2 * 64 * 64 * 24

    // MARK: Storage

    /// Bit-packed win flags. `static let` gives lazy, once-only, thread-safe
    /// construction without any mutable global state.
    static let table = Table()

    struct Table: Sendable {
        private let words: [UInt64]

        init() {
            words = KPKBitbase.build()
        }

        func isWin(_ index: Int) -> Bool {
            words[index >> 6] & (1 << UInt64(index & 63)) != 0
        }
    }

    // MARK: Construction

    /// Result flags, combined with bitwise OR while scanning successors so that
    /// "any successor wins" and "every successor draws" are one pass.
    private enum Outcome {
        static let invalid: UInt8 = 0
        static let unknown: UInt8 = 1
        static let draw: UInt8 = 2
        static let win: UInt8 = 4
    }

    static func index(strongToMove: Int, strongKing: Int, weakKing: Int, pawnIndex: Int) -> Int {
        ((pawnIndex * 2 + strongToMove) * 64 + strongKing) * 64 + weakKing
    }

    private static func build() -> [UInt64] {
        var results = [UInt8](repeating: Outcome.unknown, count: indexCount)

        // Pass 1: everything whose result is immediate.
        for pawnIndex in 0..<24 {
            let pawn = pawnSquare(pawnIndex)
            for strongToMove in 0..<2 {
                for strongKing in 0..<64 {
                    for weakKing in 0..<64 {
                        let index = index(
                            strongToMove: strongToMove,
                            strongKing: strongKing,
                            weakKing: weakKing,
                            pawnIndex: pawnIndex
                        )
                        results[index] = initialResult(
                            strongToMove: strongToMove == 0,
                            strongKing: strongKing,
                            weakKing: weakKing,
                            pawn: pawn
                        )
                    }
                }
            }
        }

        // Pass 2: fixpoint. Each sweep resolves the positions whose successors
        // have all become known; converges in well under thirty sweeps.
        var changed = true
        while changed {
            changed = false
            for pawnIndex in 0..<24 {
                let pawn = pawnSquare(pawnIndex)
                for strongToMove in 0..<2 {
                    for strongKing in 0..<64 {
                        for weakKing in 0..<64 {
                            let index = index(
                                strongToMove: strongToMove,
                                strongKing: strongKing,
                                weakKing: weakKing,
                                pawnIndex: pawnIndex
                            )
                            guard results[index] == Outcome.unknown else { continue }
                            let resolved = classify(
                                strongToMove: strongToMove == 0,
                                strongKing: strongKing,
                                weakKing: weakKing,
                                pawn: pawn,
                                pawnIndex: pawnIndex,
                                results: results
                            )
                            if resolved != Outcome.unknown {
                                results[index] = resolved
                                changed = true
                            }
                        }
                    }
                }
            }
        }

        var words = [UInt64](repeating: 0, count: (indexCount + 63) / 64)
        for index in 0..<indexCount where results[index] == Outcome.win {
            words[index >> 6] |= (1 << UInt64(index & 63))
        }
        return words
    }

    /// Positions whose value needs no search.
    private static func initialResult(
        strongToMove: Bool,
        strongKing: Int,
        weakKing: Int,
        pawn: Int
    ) -> UInt8 {
        // Illegal placements: touching kings, or a king standing on the pawn.
        if kingDistance(strongKing, weakKing) <= 1 { return Outcome.invalid }
        if strongKing == pawn || weakKing == pawn { return Outcome.invalid }
        // With the strong side to move the weak king cannot already be in check
        // from the pawn.
        if strongToMove, pawnAttacks(pawn).contains(weakKing) { return Outcome.invalid }

        if strongToMove {
            // Pawn on the seventh: promote, unless the new queen is captured on
            // the spot or our own king is in the way.
            if rank(pawn) == 6 {
                let promotion = pawn + 8
                if strongKing != promotion,
                    kingDistance(weakKing, promotion) > 1 || kingDistance(strongKing, promotion) == 1 {
                    return Outcome.win
                }
            }
        } else {
            // Stalemate: no weak-king move avoids the strong king and the pawn.
            let safeMoves = kingMoves(weakKing).filter { target in
                kingDistance(target, strongKing) > 1 && !pawnAttacks(pawn).contains(target)
            }
            if safeMoves.isEmpty { return Outcome.draw }
            // Winning the pawn outright leaves a bare king: dead drawn.
            if kingDistance(weakKing, pawn) <= 1, kingDistance(strongKing, pawn) > 1 { return Outcome.draw }
        }

        return Outcome.unknown
    }

    /// Resolves one position from its successors.
    ///
    /// The strong side needs one winning move; the weak side needs one drawing
    /// move. Successors that are illegal contribute `invalid` (zero), so they
    /// drop out of the OR automatically — which is also how "the weak king may
    /// not capture a defended pawn" is enforced without a special case.
    private static func classify(
        strongToMove: Bool,
        strongKing: Int,
        weakKing: Int,
        pawn: Int,
        pawnIndex: Int,
        results: [UInt8]
    ) -> UInt8 {
        let good = strongToMove ? Outcome.win : Outcome.draw
        let bad = strongToMove ? Outcome.draw : Outcome.win

        var combined: UInt8 = Outcome.invalid

        if strongToMove {
            for target in kingMoves(strongKing) {
                combined |= results[
                    index(strongToMove: 1, strongKing: target, weakKing: weakKing, pawnIndex: pawnIndex)
                ]
            }
            if rank(pawn) < 6 {
                let pushed = pawn + 8
                combined |= results[
                    index(
                        strongToMove: 1,
                        strongKing: strongKing,
                        weakKing: weakKing,
                        pawnIndex: pawnIndexOf(pushed)
                    )
                ]
                if rank(pawn) == 1, pushed != strongKing, pushed != weakKing {
                    let doublePush = pawn + 16
                    combined |= results[
                        index(
                            strongToMove: 1,
                            strongKing: strongKing,
                            weakKing: weakKing,
                            pawnIndex: pawnIndexOf(doublePush)
                        )
                    ]
                }
            }
        } else {
            for target in kingMoves(weakKing) {
                combined |= results[
                    index(strongToMove: 0, strongKing: strongKing, weakKing: target, pawnIndex: pawnIndex)
                ]
            }
        }

        if combined & good != 0 { return good }
        if combined & Outcome.unknown != 0 { return Outcome.unknown }
        return bad
    }

    // MARK: Square arithmetic (raw Ints — this is the hot loop)

    private static func file(_ square: Int) -> Int { square % 8 }
    private static func rank(_ square: Int) -> Int { square / 8 }

    private static func pawnSquare(_ pawnIndex: Int) -> Int {
        let rank = pawnIndex / 4 + 1
        let file = pawnIndex % 4
        return rank * 8 + file
    }

    private static func pawnIndexOf(_ square: Int) -> Int {
        (rank(square) - 1) * 4 + file(square)
    }

    private static func kingDistance(_ a: Int, _ b: Int) -> Int {
        max(abs(file(a) - file(b)), abs(rank(a) - rank(b)))
    }

    private static let kingMoveTable: [[Int]] = (0..<64).map { square in
        var moves: [Int] = []
        for fileDelta in -1...1 {
            for rankDelta in -1...1 where !(fileDelta == 0 && rankDelta == 0) {
                let f = square % 8 + fileDelta
                let r = square / 8 + rankDelta
                if (0...7).contains(f), (0...7).contains(r) { moves.append(r * 8 + f) }
            }
        }
        return moves
    }

    private static let pawnAttackTable: [[Int]] = (0..<64).map { square in
        var attacks: [Int] = []
        let r = square / 8 + 1
        guard r <= 7 else { return attacks }
        for fileDelta in [-1, 1] {
            let f = square % 8 + fileDelta
            if (0...7).contains(f) { attacks.append(r * 8 + f) }
        }
        return attacks
    }

    private static func kingMoves(_ square: Int) -> [Int] { kingMoveTable[square] }
    private static func pawnAttacks(_ square: Int) -> [Int] { pawnAttackTable[square] }

    private static func flipRank(_ square: Square) -> Square {
        Square(rawValue: (7 - square.rankIndex) * 8 + square.fileIndex) ?? square
    }

    private static func flipFile(_ square: Square) -> Square {
        Square(rawValue: square.rankIndex * 8 + (7 - square.fileIndex)) ?? square
    }
}
