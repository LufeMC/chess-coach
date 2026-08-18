//
//  BoardFeedbackTests.swift
//  BoardUITests
//

import ChessKit
import CoreGraphics
import Testing

@testable import BoardUI

/// What the board says about a move once the move has happened: the material a
/// capture moved, and which events are worth a buzz.
///
/// The haptic assertions are really budget assertions. Every counter here is
/// cheap to increment and expensive to *feel*, and the failure mode is not a
/// crash — it is a board that vibrates in someone's pocket forty times a game
/// and gets the haptics switched off entirely.
@MainActor
struct BoardFeedbackTests {

  private let geometry = BoardGeometry(side: 400, orientation: .white)
  /// Black pawn on d5, white pawn on e4: `exd5` is one tap away.
  private let captureFEN = "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"

  private func model(
    _ fen: String = Position.standard.fen,
    orientation: Piece.Color = .white,
    materialFeedback: Bool = false
  ) -> BoardModel {
    let model = BoardModel(position: Position(fen: fen)!, orientation: orientation)
    model.emitsMaterialFeedback = materialFeedback
    return model
  }

  private func capturing(_ model: BoardModel) -> Position {
    var board = Board(position: model.position)
    board.move(pieceAt: .e4, to: .d5)
    return board.position
  }

  // MARK: - Material flourish

  @Test func aCaptureAnnouncesWhatItWasWorth() {
    let model = model(captureFEN, materialFeedback: true)
    model.update(position: capturing(model))

    let flourish = model.captureFlourish
    #expect(flourish?.square == .d5, "the rings belong on the square the piece came off")
    #expect(flourish?.delta.value == 1)
    #expect(flourish?.delta.label == "+1")
  }

  @Test func theSignFollowsTheReaderNotTheMover() {
    // Same capture, board turned around: White winning a pawn is a pawn *lost*
    // from Black's side of the table, and it has to say so.
    let model = model(captureFEN, orientation: .black, materialFeedback: true)
    model.update(position: capturing(model))

    #expect(model.captureFlourish?.delta.value == -1)
    #expect(model.captureFlourish?.delta.isGain == false)
    #expect(model.captureFlourish?.delta.label == "\u{2212}1")
  }

  @Test func boardsThatDidNotAskForItStaySilent() {
    // Review scrubbers and filmstrip thumbnails replay captures constantly.
    let model = model(captureFEN, materialFeedback: false)
    model.update(position: capturing(model))

    #expect(model.captureFlourish == nil)
    #expect(model.captureTicks == 1, "the capture still happened; only the flourish is off")
  }

  @Test func aQuietMoveThrowsNothing() {
    let model = model(materialFeedback: true)
    var board = Board(position: .standard)
    board.move(pieceAt: .e2, to: .e4)
    model.update(position: board.position)

    #expect(model.captureFlourish == nil)
  }

  @Test func consecutiveCapturesEachGetTheirOwnRings() {
    // Two captures on the same square in a row must not be diffed away as "no
    // change" — the second one would silently never animate.
    let model = model(captureFEN, materialFeedback: true)
    model.update(position: capturing(model))
    let first = model.captureFlourish

    var board = Board(position: model.position)
    board.move(pieceAt: .d8, to: .d5)
    model.update(position: board.position)

    #expect(model.captureFlourish?.id != first?.id)
    #expect(model.captureFlourish?.delta.value == -1, "the recapture takes it back")
  }

  @Test func theFlourishClearsItselfWithoutBeingAsked() async {
    let model = model(captureFEN, materialFeedback: true)
    model.update(position: capturing(model))
    #expect(model.captureFlourish != nil)

    try? await Task.sleep(for: .milliseconds(1_100))
    #expect(model.captureFlourish == nil, "a number left on the board becomes wallpaper")
  }

  // MARK: - Haptic budget

  @Test func pickingUpAPieceIsItsOwnEvent() {
    let model = model()
    #expect(model.liftTicks == 0)
    model.beginDrag(at: .e2, location: .zero)
    #expect(model.liftTicks == 1)
  }

  @Test func anEmptySquareLiftsNothing() {
    let model = model()
    model.beginDrag(at: .e4, location: .zero)
    #expect(model.liftTicks == 0)
  }

  @Test func aLegalDropIsMarkedOnceAndACaptureOnlyOnce() {
    let model = model(captureFEN)
    let interaction = BoardInteraction.userMove { _, _ in .accepted }

    // A quiet move: the landing is the event.
    model.attemptMove(from: .d2, to: .d4, interaction: interaction, geometry: geometry)
    #expect(model.moveTicks == 1)

    // A capture raises the heavier tap instead. Both together would give one
    // capture two buzzes inside 200ms.
    model.attemptMove(from: .e4, to: .d5, interaction: interaction, geometry: geometry)
    #expect(model.moveTicks == 1, "the capture is announced by the capture tick, not this one")
  }

  @Test func aRefusalIsMarkedDistinctly() {
    let model = model()
    let interaction = BoardInteraction.userMove { _, _ in .rejected }

    model.attemptMove(from: .e2, to: .e4, interaction: interaction, geometry: geometry)
    #expect(model.rejectionTicks == 1)
    #expect(model.moveTicks == 0, "a refused move never landed")
  }

  @Test func theOpponentsOrdinaryMovesRaiseNoUserEvent() {
    // The rule that keeps a 40-move game from buzzing eighty times: mark state
    // changes the user caused, not ones the app decided on.
    let model = model()
    var board = Board(position: .standard)
    board.move(pieceAt: .e2, to: .e4)
    model.update(position: board.position)

    #expect(model.moveTicks == 0)
    #expect(model.liftTicks == 0)
    #expect(model.captureTicks == 0)
    #expect(model.placementTicks == 1, "the board still knows it happened")
  }

  @Test func checkIsAnnouncedOnDeliveryAndNotWhileItStands() {
    let model = model("rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq g3 0 2")
    var board = Board(position: model.position)
    board.move(pieceAt: .d8, to: .h4)
    model.update(position: board.position)
    #expect(model.checkTicks == 1)

    // The same king still in check one position later is not news. (Not a legal
    // continuation — it does not need to be; the model is being asked about a
    // position, not a game.)
    model.update(position: Position(fen: "rnb1kbnr/pppp1p1p/6p1/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 0 4")!)
    #expect(model.checkedColor == .white)
    #expect(model.checkTicks == 1, "a repeating alert about an unchanged fact is just noise")
  }

  // MARK: - Lift geometry

  @Test func aPieceLiftsFromTheCentreOfItsSquareNotFromTheTouchPoint() {
    let model = model()
    let interaction = BoardInteraction.userMove { _, _ in .accepted }
    // Press in the top-left corner of e2 rather than its middle.
    let frame = geometry.frame(of: .e2)
    let corner = CGPoint(x: frame.minX + 2, y: frame.minY + 2)

    model.pressChanged(start: corner, location: corner, geometry: geometry, interaction: interaction)

    #expect(model.drag?.origin == .e2)
    #expect(
      model.drag?.location == geometry.center(of: .e2),
      "lifting at the touch point yanks the piece sideways before the drag starts"
    )
    #expect(model.drag?.isActive == false)
  }
}
