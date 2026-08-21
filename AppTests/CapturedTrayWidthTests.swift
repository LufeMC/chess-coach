//
//  CapturedTrayWidthTests.swift
//  ChessCoachTests
//

import BoardUI
import ChessKit
import CoreGraphics
import Testing

@testable import ChessCoach

/// The captured row sits in a plain `VStack` with nothing limiting its width,
/// so an over-wide tray does not clip — it widens the whole screen. A puzzle
/// deep in an endgame arrived with nine captures a side and pushed the board
/// off both edges of the phone.
@Suite("Captured tray width")
struct CapturedTrayWidthTests {

    /// Mirrors `CapturedTray.body`: glyphs at `glyphSize`, each overlapping the
    /// last by 34%, on a chip with 9pt of padding either side.
    private func trayWidth(glyphs: Int, glyphSize: CGFloat = 30) -> CGFloat {
        guard glyphs > 0 else { return 0 }
        let step = glyphSize * (1 - 0.34)
        return glyphSize + CGFloat(glyphs - 1) * step + 18
    }

    /// The narrowest phone still supported, less the row's own padding, the
    /// gap between the trays, and the advantage badge.
    private let budget: CGFloat = 375 - 32 - 8 - 44

    @Test("Two full trays fit the narrowest screen")
    func twoFullTraysFit() {
        let both = trayWidth(glyphs: CapturedTray.maxGlyphs) * 2
        #expect(
            both <= budget,
            "two trays are \(both)pt against a \(budget)pt budget — the board will be pushed off screen"
        )
    }

    /// The bug, as arithmetic: this is what shipped before the cap.
    @Test("The uncapped tray is what overflowed")
    func uncappedOverflows() {
        #expect(trayWidth(glyphs: 9) * 2 > budget)
    }

    /// A cap is only safe if it keeps the pieces worth seeing. `lost(by:in:)`
    /// orders most valuable first, so the prefix must start with the queen.
    @Test("The glyphs kept are the most valuable ones")
    func capKeepsTheBigPieces() throws {
        // White has lost queen, both rooks, both bishops, both knights and two
        // pawns — far more than the tray can draw.
        let position = try #require(Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/2PPPP2/4K3 w kq - 0 1"))
        let lost = CapturedMaterial.lost(by: .white, in: position)

        #expect(lost.count > CapturedTray.maxGlyphs, "fixture is not crowded enough to test the cap")
        #expect(lost.first == .queen, "the tray would drop the queen and keep pawns")
        #expect(lost.prefix(CapturedTray.maxGlyphs).contains(.pawn) == false)
    }
}
