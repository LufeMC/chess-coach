//
//  KPKBitbaseTests.swift
//  AnalysisKitTests
//

import ChessKit
import Testing

@testable import AnalysisKit

@Suite("KPK bitbase")
struct KPKBitbaseTests {

    private func probe(
        _ strongKing: Square,
        _ pawn: Square,
        _ weakKing: Square,
        _ sideToMove: Piece.Color,
        strongSide: Piece.Color = .white
    ) -> KPKOutcome {
        KPKBitbase.probe(
            strongSide: strongSide,
            strongKing: strongKing,
            pawn: pawn,
            weakKing: weakKing,
            sideToMove: sideToMove
        )
    }

    /// The textbook opposition pair. With the kings facing off across the pawn,
    /// the side *not* to move holds the opposition — so the same placement is a
    /// draw or a win purely on the strength of whose turn it is. Any indexing or
    /// side-to-move bug in the table shows up here immediately.
    @Test("Opposition decides Ke5/Pe4 vs Ke7")
    func opposition() {
        #expect(probe(.e5, .e4, .e7, .white) == .draw)
        #expect(probe(.e5, .e4, .e7, .black) == .win)
        // The same shape one file over behaves identically.
        #expect(probe(.d5, .d4, .d7, .white) == .draw)
        #expect(probe(.d5, .d4, .d7, .black) == .win)
    }

    /// A king on the sixth rank in front of its pawn wins whoever is to move —
    /// the one case where the opposition does not matter.
    @Test("King on the sixth in front of the pawn always wins")
    func kingOnSixth() {
        #expect(probe(.e6, .e5, .e8, .white) == .win)
        #expect(probe(.e6, .e5, .e8, .black) == .win)
    }

    /// Rook pawns are the great exception: the defending king in the corner
    /// cannot be evicted, so it is drawn regardless of the move.
    @Test("Rook pawn with the defending king in the corner is drawn")
    func rookPawnCornerDraw() {
        #expect(probe(.h6, .h5, .h8, .white) == .draw)
        #expect(probe(.h6, .h5, .h8, .black) == .draw)
        #expect(probe(.a6, .a5, .a8, .white) == .draw)
        #expect(probe(.a6, .a5, .a8, .black) == .draw)
    }

    @Test("A pawn the defending king cannot reach queens")
    func defenderTooFar() {
        #expect(probe(.b7, .b6, .h4, .white) == .win)
        #expect(probe(.e1, .e2, .e8, .white) == .win)
        #expect(probe(.b7, .b6, .d7, .white) == .win)
    }

    /// Black-owned pawns are answered by mirroring the board vertically. If the
    /// mirror were wrong, the pawn would appear to be running the wrong way.
    @Test("Black pawns mirror to the same results")
    func blackSideMirror() {
        // Vertical mirror of Ke5/Pe4 vs Ke7 with the colours swapped.
        #expect(probe(.e4, .e5, .e2, .black, strongSide: .black) == .draw)
        #expect(probe(.e4, .e5, .e2, .white, strongSide: .black) == .win)
        // Vertical mirror of the drawn rook-pawn corner.
        #expect(probe(.h3, .h4, .h1, .black, strongSide: .black) == .draw)
    }

    /// Files e-h are reached by mirroring horizontally; a broken mirror would
    /// make the two halves of the board disagree.
    @Test("File mirroring is consistent across the board")
    func fileMirror() {
        // `rank` is the strong king's 0-based rank index; the pawn sits one below
        // it and the defending king two above, so it stops at 5.
        for rank in 2...5 {
            for file in 0...3 {
                let leftPawn = Square(rawValue: (rank - 1) * 8 + file)!
                let rightPawn = Square(rawValue: (rank - 1) * 8 + (7 - file))!
                let leftStrong = Square(rawValue: rank * 8 + file)!
                let rightStrong = Square(rawValue: rank * 8 + (7 - file))!
                let leftWeak = Square(rawValue: (rank + 2) * 8 + file)!
                let rightWeak = Square(rawValue: (rank + 2) * 8 + (7 - file))!

                #expect(
                    probe(leftStrong, leftPawn, leftWeak, .white)
                        == probe(rightStrong, rightPawn, rightWeak, .white)
                )
            }
        }
    }

    @Test("Probing a position recognises KPK and rejects anything else")
    func positionProbe() throws {
        let kpk = try #require(Position(fen: "8/8/8/4k3/8/4P3/4K3/8 w - - 0 1"))
        #expect(KPKBitbase.probe(position: kpk) != nil)

        // Ke5/Pe4 vs Ke7 with White to move, as a FEN.
        let drawn = try #require(Position(fen: "8/4k3/8/4K3/4P3/8/8/8 w - - 0 1"))
        #expect(KPKBitbase.probe(position: drawn) == .draw)
        let won = try #require(Position(fen: "8/4k3/8/4K3/4P3/8/8/8 b - - 0 1"))
        #expect(KPKBitbase.probe(position: won) == .win)

        let notKPK = try #require(Position(fen: "8/8/8/4k3/8/4P3/4K3/4R3 w - - 0 1"))
        #expect(KPKBitbase.probe(position: notKPK) == nil)
    }

    /// The published size of the KPK bitbase. Reaching exactly this number from
    /// an independent implementation of the retrograde analysis is the strongest
    /// single check available without a tablebase to compare against.
    @Test("The table contains the known number of won positions")
    func tableSize() {
        var wins = 0
        for index in 0..<KPKBitbase.indexCount where KPKBitbase.table.isWin(index) { wins += 1 }
        #expect(wins == 111_282)
    }
}
