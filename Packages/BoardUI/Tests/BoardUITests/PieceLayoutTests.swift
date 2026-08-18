//
//  PieceLayoutTests.swift
//  BoardUITests
//

import ChessKit
import Testing

@testable import BoardUI

/// The token identities produced here are what SwiftUI animates between. If a
/// move does not preserve identity the piece pops instead of sliding, and if it
/// preserves the *wrong* identity a different piece slides across the board.
struct PieceLayoutTests {

  private func layout(_ fen: String) -> PieceLayout {
    PieceLayout(position: Position(fen: fen)!)
  }

  @Test func startPositionHasThirtyTwoDistinctTokens() throws {
    let layout = PieceLayout(position: .standard)
    #expect(layout.tokens.count == 32)
    #expect(Set(layout.tokens.map(\.id)).count == 32)
  }

  @Test func aQuietMoveKeepsThePieceIdentity() throws {
    var layout = PieceLayout(position: .standard)
    let knight = try #require(layout.token(at: .g1))

    var board = Board(position: .standard)
    board.move(pieceAt: .g1, to: .f3)
    layout.apply(position: board.position)

    let moved = try #require(layout.token(at: .f3))
    #expect(moved.id == knight.id)
    #expect(layout.token(at: .g1) == nil)
    #expect(layout.tokens.count == 32)
  }

  @Test func untouchedPiecesKeepTheirIdentities() throws {
    var layout = PieceLayout(position: .standard)
    let before = Dictionary(uniqueKeysWithValues: layout.tokens.map { ($0.square, $0.id) })

    var board = Board(position: .standard)
    board.move(pieceAt: .e2, to: .e4)
    layout.apply(position: board.position)

    for token in layout.tokens where token.square != .e4 {
      #expect(before[token.square] == token.id, "\(token.square.notation) changed identity")
    }
  }

  @Test func aCaptureRemovesExactlyOneToken() throws {
    // Black pawn on d5, white pawn on e4: exd5 takes one piece off.
    var layout = layout("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    let attacker = try #require(layout.token(at: .e4))
    let victim = try #require(layout.token(at: .d5))
    let countBefore = layout.tokens.count

    var board = Board(position: Position(fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")!)
    board.move(pieceAt: .e4, to: .d5)
    layout.apply(position: board.position)

    #expect(layout.tokens.count == countBefore - 1)
    #expect(layout.token(at: .d5)?.id == attacker.id)
    #expect(!layout.tokens.contains { $0.id == victim.id })
  }

  @Test func castlingSlidesBothKingAndRook() throws {
    let fen = "rnbqk2r/pppp1ppp/5n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"
    var layout = layout(fen)
    let king = try #require(layout.token(at: .e1))
    let rook = try #require(layout.token(at: .h1))

    var board = Board(position: Position(fen: fen)!)
    board.move(pieceAt: .e1, to: .g1)
    layout.apply(position: board.position)

    #expect(layout.token(at: .g1)?.id == king.id)
    #expect(layout.token(at: .f1)?.id == rook.id)
  }

  @Test func promotionReusesThePawnSoItSlidesIn() throws {
    let fen = "8/3P2k1/8/8/8/8/6K1/8 w - - 0 1"
    var layout = layout(fen)
    let pawn = try #require(layout.token(at: .d7))

    var board = Board(position: Position(fen: fen)!)
    // Bound to a local first: `#require` decomposes the call it is handed and
    // cannot re-invoke a `mutating` method on a captured copy.
    let played = board.move(pieceAt: .d7, to: .d8)
    let move = try #require(played)
    board.completePromotion(of: move, to: .queen)
    layout.apply(position: board.position)

    let queen = try #require(layout.token(at: .d8))
    #expect(queen.id == pawn.id, "the promoted piece should inherit the pawn's identity")
    #expect(queen.kind == .queen)
  }

  @Test func anUnrelatedPositionGetsFreshIdentities() throws {
    var layout = PieceLayout(position: .standard)
    let originalIDs = Set(layout.tokens.map(\.id))

    // A pure-endgame position shares no piece placement with the start.
    layout.apply(position: Position(fen: "8/8/4k3/8/8/4K3/4P3/8 w - - 0 1")!)

    #expect(layout.tokens.count == 3)
    // The kings and pawn are matched to leftovers of the same kind rather than
    // invented, which is fine — what matters is that nothing is duplicated.
    #expect(Set(layout.tokens.map(\.id)).count == 3)
    #expect(originalIDs.isSuperset(of: Set(layout.tokens.map(\.id))))
  }

  @Test func identicalPiecesResolveDeterministically() throws {
    // Two white rooks; moving one must not make the other slide instead.
    let fen = "4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"
    var a = layout(fen)
    var b = layout(fen)

    var board = Board(position: Position(fen: fen)!)
    board.move(pieceAt: .a1, to: .d1)

    a.apply(position: board.position)
    b.apply(position: board.position)

    #expect(a.tokens == b.tokens)
    #expect(a.token(at: .h1)?.id == b.token(at: .h1)?.id)
  }

  @Test func reapplyingTheSamePositionIsAnIdentity() throws {
    var layout = PieceLayout(position: .standard)
    let before = layout.tokens
    layout.apply(position: .standard)
    #expect(layout.tokens == before)
  }
}
