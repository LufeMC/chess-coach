//
//  BoardPaletteTests.swift
//  BoardUITests
//

import ChessKit
import SwiftUI
import Testing

@testable import BoardUI

/// The square tones, measured rather than eyeballed.
///
/// Board palettes rot the same way every time: someone nudges a square "just a
/// bit warmer", the delta creeps up, and six months later the board is a
/// brown/cream chequerboard that eats every overlay drawn on it. These tests
/// pin the one property that matters — **low-contrast board, high-contrast
/// pieces** — in numbers, so the drift fails a build instead of a review.
/// The quiet family the palette rules were written for. ``BoardStyle/clay`` is
/// a deliberate exception — a bold toy board whose heavy 3D pieces carry the
/// contrast the quiet themes forbid — so it is pinned by its own tests below
/// rather than graded against rules it was designed to break.
private let quietThemes: [BoardStyle] = [.slate, .ink, .paper]

@MainActor
struct BoardPaletteTests {

  /// CIE L\* of a resolved colour. Perceptual lightness, which is the axis the
  /// whole palette is designed on.
  private func lightness(_ color: Color) -> Double {
    let resolved = color.resolve(in: EnvironmentValues())
    func linear(_ channel: Float) -> Double {
      let c = Double(channel)
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let y =
      0.2126 * linear(resolved.red)
      + 0.7152 * linear(resolved.green)
      + 0.0722 * linear(resolved.blue)
    let epsilon = 216.0 / 24389.0
    let kappa = 24389.0 / 27.0
    let f = y > epsilon ? pow(y, 1.0 / 3.0) : (kappa * y + 16) / 116
    return 116 * f - 16
  }

  @Test(arguments: quietThemes)
  func lightSquaresAreAllButThePage(theme: BoardStyle) {
    // Essentially white. The squares are there to locate the pieces, not to be
    // looked at.
    #expect(lightness(theme.lightSquare.light) > 96)
  }

  @Test(arguments: quietThemes)
  func theCheckerBarelyReadsInTheLightAppearance(theme: BoardStyle) {
    let delta = lightness(theme.lightSquare.light) - lightness(theme.darkSquare.light)
    #expect(delta > 0, "the light square has to be the lighter one")
    #expect(delta >= 5, "below this the board stops reading as a grid at all")
    #expect(delta <= 9, "above this the squares start competing with the pieces")
  }

  @Test(arguments: quietThemes)
  func theCheckerIsQuieterStillInTheDarkAppearance(theme: BoardStyle) {
    let light = lightness(theme.lightSquare.dark)
    let dark = lightness(theme.darkSquare.dark)
    let lightDelta = lightness(theme.lightSquare.light) - lightness(theme.darkSquare.light)
    #expect(light - dark > 0)
    #expect(light - dark < lightDelta, "on a dark ground the eye separates tones more readily")
  }

  @Test(arguments: quietThemes)
  func darkModeIsADesignAndNotAnInversion(theme: BoardStyle) {
    // Cells sit well above a dark page ground (a system dark background is
    // L* 0–11), so the board is raised by lightness — the only elevation that
    // works when a shadow would be invisible.
    #expect(lightness(theme.lightSquare.dark) > 20)
    #expect(lightness(theme.darkSquare.dark) > 20)
    // …and well below the light appearance, so nothing here was computed by
    // flipping a light value.
    #expect(lightness(theme.darkSquare.dark) < 45)
  }

  @Test(arguments: quietThemes)
  func thePieceArtworkSeparatesFromBothSquareTones(theme: BoardStyle) {
    // Staunty's white body is #F0F0F0, L* 94.8. The light square is designed to
    // sit above it and the dark square below it, so a white piece has a tonal
    // edge on either square before its outline does any work at all.
    let whiteBody = lightness(Color(hex: 0xF0F0F0))
    #expect(lightness(theme.lightSquare.light) > whiteBody)
    #expect(lightness(theme.darkSquare.light) < whiteBody)
  }

  @Test(arguments: quietThemes)
  func theLastMoveWashIsWarmAndNotTheAccent(theme: BoardStyle) {
    // Two separate jobs: the accent means "you are doing this", the last move
    // means "this already happened". Sharing a colour collapses them.
    #expect(theme.lastMove != theme.accent)
    let warm = theme.lastMove.light.resolve(in: EnvironmentValues())
    #expect(warm.red > warm.blue, "a cool 'warm yellow' is just a grey wash")
    #expect(warm.green > warm.blue)
  }

  @Test(arguments: quietThemes)
  func coordinatesBorrowTheOpposingSquareTone(theme: BoardStyle) {
    // Which is what makes them retune themselves for free whenever the squares
    // do, and keeps them exactly as loud as the checker pattern and no louder.
    #expect(theme.opposingSquareColor(for: .light) == theme.darkSquare)
    #expect(theme.opposingSquareColor(for: .dark) == theme.lightSquare)
  }

  @Test(arguments: quietThemes)
  func increasedContrastStopsBorrowingAndGoesToTheExtreme(theme: BoardStyle) {
    // A reader who asked for contrast is asking the labels to stop being quiet,
    // so they get a flat near-black or near-white instead of a 40% borrow.
    let quiet = theme.coordinateColor(on: .light, contrast: .standard)
    let loud = theme.coordinateColor(on: .light, contrast: .increased)
    #expect(quiet != loud)
    #expect(lightness(loud.light) < 20, "near-black on a light appearance")
    #expect(lightness(loud.dark) > 90, "near-white on a dark one")
  }

  @Test func theDefaultBoardShowsNoCoordinates() {
    // Coordinates in a gutter steal width from the surface the user looks at
    // more than any other.
    #expect(BoardStyle.default.showsCoordinates == false)
  }

  @Test func theDefaultIsTheClayToyBoard() {
    #expect(BoardStyle.default == .clay)
    // Rounded like every other card in the app's toy look.
    #expect(BoardStyle.clay.cornerRadius == 16)
    // The quiet themes stay flat and stay offered.
    #expect(BoardStyle.slate.cornerRadius == 0)
    #expect(BoardStyle.builtIn.contains(.slate))
  }

  @Test func theClayCheckerIsBoldButOrdered() {
    // Clay breaks the quiet-board ceiling on purpose, but the relationships
    // still hold: the light square is the lighter one in both appearances, and
    // dark mode is designed, not inverted.
    #expect(lightness(BoardStyle.clay.lightSquare.light) > lightness(BoardStyle.clay.darkSquare.light))
    #expect(lightness(BoardStyle.clay.lightSquare.dark) > lightness(BoardStyle.clay.darkSquare.dark))
    #expect(lightness(BoardStyle.clay.darkSquare.dark) < 45)
  }

  @Test func theDefaultPieceSetIsTheOneThatSurvivesAPhone() {
    #expect(BoardStyle.default.pieceSet == .clay)
    #expect(PieceRenderer.builtIn.contains(.clay))
    #expect(PieceRenderer.builtIn.contains(.staunty))
    #expect(PieceRenderer.builtIn.contains(.cburnett), "the classic set stays available")
  }
}

// MARK: - Captured material

/// What each side has taken, derived from the position rather than recorded.
@MainActor
struct CapturedMaterialTests {

  private func position(_ fen: String) -> Position {
    guard let position = Position(fen: fen) else {
      Issue.record("bad fixture FEN: \(fen)")
      return .standard
    }
    return position
  }

  @Test func nothingIsLostAtTheStart() {
    #expect(CapturedMaterial.lost(by: .white, in: .standard).isEmpty)
    #expect(CapturedMaterial.lost(by: .black, in: .standard).isEmpty)
    #expect(CapturedMaterial.advantage(for: .white, in: .standard) == 0)
  }

  @Test func missingPiecesAreReportedHeaviestFirst() {
    // Black keeps one rook, one bishop, the king and four pawns; everything
    // else has come off.
    let board = position("r1b1k3/pppp4/8/8/8/8/PPPPPPPP/RNBQKBNR w KQq - 0 1")
    #expect(
        CapturedMaterial.lost(by: .black, in: board)
            == [.queen, .rook, .bishop, .knight, .knight, .pawn, .pawn, .pawn, .pawn]
    )
  }

  @Test func theAdvantageGoesToWhoeverIsAhead() {
    let board = position("r1b1k3/pppp4/8/8/8/8/PPPPPPPP/RNBQKBNR w KQq - 0 1")
    #expect(CapturedMaterial.advantage(for: .white, in: board) > 0)
    #expect(CapturedMaterial.advantage(for: .black, in: board) < 0)
  }

  /// The caveat, pinned so nobody "fixes" the clamp and starts printing a
  /// negative number of captured queens.
  @Test func promotionCannotProduceANegativeCount() {
    // Black has two queens; one of them was a pawn.
    let board = position("4k3/8/8/8/8/8/8/qq2K3 w - - 0 1")
    let lost = CapturedMaterial.lost(by: .black, in: board)
    #expect(!lost.contains(.queen))
    // ...and the balance is still read from the board, so it stays correct.
    #expect(CapturedMaterial.advantage(for: .black, in: board) == 18)
  }
}
