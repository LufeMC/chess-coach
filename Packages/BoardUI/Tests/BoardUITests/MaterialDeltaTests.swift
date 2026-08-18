//
//  MaterialDeltaTests.swift
//  BoardUITests
//

import ChessKit
import Testing

@testable import BoardUI

/// The number that floats out of a capture.
///
/// It has to be right in a way most board decoration does not: it is a
/// *teaching* signal, and a training app that shows the wrong material count
/// during a trade is worse than one that shows none.
struct MaterialDeltaTests {

  private func position(_ fen: String) -> Position { Position(fen: fen)! }

  // MARK: - Values

  @Test func piecesAreWorthWhatEveryBookSaysTheyAre() {
    #expect(MaterialDelta.value(of: .pawn) == 1)
    #expect(MaterialDelta.value(of: .knight) == 3)
    #expect(MaterialDelta.value(of: .bishop) == 3)
    #expect(MaterialDelta.value(of: .rook) == 5)
    #expect(MaterialDelta.value(of: .queen) == 9)
  }

  @Test func theKingIsWorthNothing() {
    // It is never captured, and counting it would make every number nonsense.
    #expect(MaterialDelta.value(of: .king) == 0)
  }

  @Test func theStartPositionIsWorthThirtyNineASide() {
    #expect(MaterialDelta.material(in: .standard, for: .white) == 39)
    #expect(MaterialDelta.material(in: .standard, for: .black) == 39)
  }

  @Test func theStartPositionIsBalanced() {
    #expect(MaterialDelta.balance(in: .standard, for: .white) == 0)
    #expect(MaterialDelta.balance(in: .standard, for: .black) == 0)
  }

  @Test func balanceIsSymmetric() {
    let lopsided = position("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN1 w Qkq - 0 1")
    #expect(
      MaterialDelta.balance(in: lopsided, for: .white)
        == -MaterialDelta.balance(in: lopsided, for: .black)
    )
    #expect(MaterialDelta.balance(in: lopsided, for: .white) == -5)
  }

  // MARK: - Deltas across a move

  @Test func aQuietMoveMovesNothing() {
    var board = Board(position: .standard)
    board.move(pieceAt: .e2, to: .e4)
    let delta = MaterialDelta.between(.standard, board.position, for: .white)
    #expect(delta.isZero)
  }

  @Test func winningAKnightIsPlusThreeToTheWinnerAndMinusThreeToTheLoser() {
    // White bishop on c4 takes the black knight on d5.
    let before = position("r1bqkb1r/ppp1pppp/8/3n4/2B5/8/PPPP1PPP/RNBQK1NR w KQkq - 0 4")
    var board = Board(position: before)
    board.move(pieceAt: .c4, to: .d5)

    #expect(MaterialDelta.between(before, board.position, for: .white).value == 3)
    #expect(MaterialDelta.between(before, board.position, for: .black).value == -3)
  }

  @Test func thePerspectiveIsTheReaderNotTheMover() {
    // This is the whole reason the flourish is ever red. Measured from whoever
    // just moved, every capture is a gain and the colour never means anything.
    let before = position("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    var board = Board(position: before)
    board.move(pieceAt: .e4, to: .d5)

    let forWhite = MaterialDelta.between(before, board.position, for: .white)
    let forBlack = MaterialDelta.between(before, board.position, for: .black)
    #expect(forWhite.isGain)
    #expect(!forBlack.isGain)
    #expect(forWhite.value == -forBlack.value)
  }

  @Test func promotingAPawnIsAnEightPointSwing() {
    // A pawn (1) becomes a queen (9). Worth marking for exactly the same reason
    // a capture is.
    let before = position("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    var board = Board(position: before)
    let played = board.move(pieceAt: .d7, to: .d8)
    if let move = played { board.completePromotion(of: move, to: .queen) }

    #expect(MaterialDelta.between(before, board.position, for: .white).value == 8)
  }

  @Test func anEnPassantCaptureCountsThePawnThatLeftTheBoard() {
    // The target square is empty, but a pawn still comes off — the case a naive
    // "what was standing on the destination" implementation gets wrong.
    let before = position("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2")
    var board = Board(position: before)
    board.move(pieceAt: .e5, to: .d6)

    #expect(MaterialDelta.between(before, board.position, for: .white).value == 1)
  }

  // MARK: - Labels

  @Test func labelsCarryTheirSign() {
    #expect(MaterialDelta(value: 3).label == "+3")
    #expect(MaterialDelta(value: 0).label == "0")
  }

  @Test func negativeLabelsUseARealMinusSign() {
    // At the weight this is drawn, a hyphen beside a digit reads as a dash in a
    // word rather than as a sign.
    #expect(MaterialDelta(value: -1).label == "\u{2212}1")
    #expect(!MaterialDelta(value: -9).label.contains("-"))
  }

  @Test func gainAndLossAreDistinguishableWithoutColour() {
    // Nothing on the board may be encoded by colour alone; the sign is the
    // second channel.
    #expect(MaterialDelta(value: 5).isGain)
    #expect(!MaterialDelta(value: -5).isGain)
    #expect(!MaterialDelta(value: 0).isGain)
    #expect(MaterialDelta(value: 0).isZero)
  }
}
