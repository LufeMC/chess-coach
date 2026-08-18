//
//  BoardModelTests.swift
//  BoardUITests
//

import ChessKit
import Testing

@testable import BoardUI

/// The interaction rules that the gesture layer depends on. These are the parts
/// a preview cannot check: selection bookkeeping, what counts as a capture, and
/// the refusal path that the second-try training flow is built on.
@MainActor
struct BoardModelTests {

  private func model(_ fen: String = Position.standard.fen, orientation: Piece.Color = .white) -> BoardModel {
    BoardModel(position: Position(fen: fen)!, orientation: orientation)
  }

  // MARK: - Selection

  @Test func selectingAPieceListsItsLegalDestinations() {
    let model = model()
    model.select(.g1)
    #expect(model.selection == .g1)
    #expect(model.legalDestinations == [.f3, .h3])
  }

  @Test func selectionClearsCleanly() {
    let model = model()
    model.select(.e2)
    model.clearSelection()
    #expect(model.selection == nil)
    #expect(model.legalDestinations.isEmpty)
  }

  @Test func onlyTheSideToMoveCanBePickedUp() {
    let model = model()
    let interaction = BoardInteraction.userMove { _, _ in .accepted }
    #expect(model.canPickUp(.e2, interaction: interaction))
    #expect(!model.canPickUp(.e7, interaction: interaction))
    #expect(!model.canPickUp(.e4, interaction: interaction), "empty squares are not pickable")
  }

  @Test func lockedBoardsRefuseSelectionAndReplayBoardsAllowIt() {
    let model = model()
    #expect(!model.canPickUp(.e2, interaction: .locked))
    // Replay is read-only but still lets a reader interrogate either side.
    #expect(model.canPickUp(.e2, interaction: .replay))
    #expect(model.canPickUp(.e7, interaction: .replay))
  }

  // MARK: - Capture detection

  @Test func occupiedDestinationsReadAsCaptures() {
    let model = model("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    model.select(.e4)
    #expect(model.isCapture(.d5))
    #expect(!model.isCapture(.e5))
  }

  @Test func enPassantReadsAsACaptureEvenThoughTheSquareIsEmpty() {
    // White pawn on e5, black has just played d7-d5.
    let model = model("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")
    model.select(.e5)
    #expect(model.position.piece(at: .d6) == nil)
    #expect(model.isCapture(.d6), "the target square is empty but a pawn still comes off")
    #expect(!model.isCapture(.e6))
  }

  @Test func highlightsMarkCapturesAndQuietMovesDifferently() {
    let model = model("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    model.select(.e4)
    let highlights = model.interactionHighlights()
    #expect(highlights.contains(SquareHighlight(.e4, .selected)))
    #expect(highlights.contains(SquareHighlight(.d5, .legalCapture)))
    #expect(highlights.contains(SquareHighlight(.e5, .legalMove)))
  }

  // MARK: - Check

  @Test func theCheckedKingIsFound() {
    let model = model("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
    #expect(model.checkedKingSquare == .e1)
  }

  @Test func quietPositionsHaveNoCheckedKing() {
    #expect(model().checkedKingSquare == nil)
  }

  // MARK: - Move attempts

  @Test func acceptedMovesClearTheInteraction() {
    let model = model()
    model.select(.e2)
    model.beginDrag(at: .e2, location: .zero)
    model.attemptMove(from: .e2, to: .e4, interaction: .userMove { _, _ in .accepted })
    #expect(model.selection == nil)
    #expect(model.drag == nil)
    #expect(model.rejection == nil)
  }

  @Test func rejectedMovesSnapBackAndSurfaceTheReason() {
    let model = model()
    model.select(.e2)
    model.beginDrag(at: .e2, location: .zero)
    model.attemptMove(
      from: .e2,
      to: .e4,
      interaction: .userMove { _, _ in .rejected(reason: "Try again.") }
    )

    // The piece is sent home rather than removed, which is what reads as a
    // refusal instead of a dropped frame.
    #expect(model.drag?.isReturning == true)
    #expect(model.drag?.target == .e2)
    #expect(model.rejection?.square == .e2)
    #expect(model.rejection?.reason == "Try again.")
    #expect(model.selection == nil)
  }

  @Test func rejectionNeverMutatesThePosition() {
    let model = model()
    let before = model.position
    model.attemptMove(from: .e2, to: .e4, interaction: .userMove { _, _ in .rejected })
    #expect(model.position == before)
    #expect(model.layout.token(at: .e2) != nil)
    #expect(model.layout.token(at: .e4) == nil)
  }

  @Test func lockedBoardsIgnoreMoveAttempts() {
    let model = model()
    model.attemptMove(from: .e2, to: .e4, interaction: .locked)
    #expect(model.position == Position.standard)
    #expect(model.rejection == nil)
  }

  @Test func movingAPieceOntoItselfIsANoOp() {
    let model = model()
    var calls = 0
    model.attemptMove(from: .e2, to: .e2, interaction: .userMove { _, _ in calls += 1; return .accepted })
    #expect(calls == 0)
  }

  // MARK: - Promotion

  @Test func promotionOpensThePickerAndWaitsForAChoice() {
    let model = model("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    var chosen: Piece.Kind?

    model.attemptMove(
      from: .d7,
      to: .d8,
      interaction: .userMove { _, _ in
        .needsPromotion(complete: { kind in
          chosen = kind
          return .accepted
        })
      }
    )

    // Nothing has been decided yet — the move is suspended, not applied.
    #expect(model.pendingPromotion?.to == .d8)
    #expect(model.pendingPromotion?.color == .white)
    #expect(chosen == nil)

    model.choosePromotion(.knight)
    #expect(chosen == .knight)
    #expect(model.pendingPromotion == nil)
  }

  @Test func aPromotionCanStillBeRefused() {
    let model = model("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    model.attemptMove(
      from: .d7,
      to: .d8,
      interaction: .userMove { _, _ in
        .needsPromotion(complete: { _ in .rejected(reason: "Underpromotion loses here.") })
      }
    )
    model.choosePromotion(.knight)
    #expect(model.rejection?.reason == "Underpromotion loses here.")
    #expect(model.rejection?.square == .d7)
  }

  @Test func cancellingPromotionLeavesTheBoardUntouched() {
    let model = model("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    model.attemptMove(from: .d7, to: .d8, interaction: .userMove { _, _ in .needsPromotion })
    #expect(model.pendingPromotion != nil)
    model.cancelPromotion()
    #expect(model.pendingPromotion == nil)
    #expect(model.selection == nil)
    #expect(model.position.piece(at: .d7)?.kind == .pawn)
  }

  // MARK: - External position updates

  @Test func aNewPositionEndsTheCurrentInteraction() {
    let model = model()
    model.select(.e2)
    model.beginDrag(at: .e2, location: .zero)

    var board = Board(position: .standard)
    board.move(pieceAt: .e2, to: .e4)
    model.update(position: board.position)

    #expect(model.selection == nil)
    #expect(model.drag == nil)
    #expect(model.layout.token(at: .e4) != nil)
  }

  @Test func feedbackFiresOncePerEvent() {
    let model = model("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    #expect(model.placementTicks == 0)
    #expect(model.captureTicks == 0)

    var board = Board(position: model.position)
    board.move(pieceAt: .e4, to: .d5)
    model.update(position: board.position)

    #expect(model.placementTicks == 1)
    #expect(model.captureTicks == 1, "a capture is a distinct feedback event")
    #expect(model.checkTicks == 0)
  }

  @Test func checkRaisesItsOwnFeedback() {
    let quiet = model("rnb1kbnr/pppp1ppp/8/4p3/6P1/5P1q/PPPPP2P/RNBQKBNR b KQkq - 0 3")
    var board = Board(position: quiet.position)
    board.move(pieceAt: .h3, to: .g4)
    quiet.update(position: board.position)
    // Moving the queen off the checking diagonal resolves it; no check event.
    #expect(quiet.checkTicks == 0)

    // After 1.f3 e5 2.g4, Black to move: Qh4 is mate, and mate must still raise
    // the check event.
    let checking = model("rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq g3 0 2")
    var checkingBoard = Board(position: checking.position)
    checkingBoard.move(pieceAt: .d8, to: .h4)
    checking.update(position: checkingBoard.position)
    #expect(checking.checkTicks == 1)
    #expect(checking.checkedKingSquare == .e1)
  }

  @Test func repeatingTheSamePositionRaisesNoFeedback() {
    let model = model()
    model.update(position: .standard)
    #expect(model.placementTicks == 0)
  }
}
