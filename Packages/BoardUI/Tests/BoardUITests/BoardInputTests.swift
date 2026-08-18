//
//  BoardInputTests.swift
//  BoardUITests
//

import ChessKit
import CoreGraphics
import Testing

@testable import BoardUI

/// The input state machine, driven through the same entry points the gesture
/// uses. These run without a rendered board, which is the point: the bug they
/// were written for — tap a piece, tap a square, nothing happens — was invisible
/// to every test the package had, because the whole state machine lived inside
/// `BoardView` where nothing could reach it.
@MainActor
struct BoardInputTests {

  private let geometry = BoardGeometry(side: 400, orientation: .white)

  private func model(_ fen: String = Position.standard.fen, orientation: Piece.Color = .white) -> BoardModel {
    BoardModel(position: Position(fen: fen)!, orientation: orientation)
  }

  // MARK: - Tap to select, tap to move

  @Test func tapSelectsThenTapMoves() {
    let model = model()
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    #expect(model.selection == .e2, "the first tap has to survive the finger lifting")
    #expect(model.legalDestinations == [.e3, .e4])
    #expect(played.isEmpty)

    model.tap(.e4, geometry: geometry, interaction: interaction)
    #expect(played.count == 1)
    #expect(played.first?.0 == .e2)
    #expect(played.first?.1 == .e4)
    #expect(model.selection == nil, "an accepted move hands the board back to the caller")
  }

  @Test func tappingTheSelectedPieceAgainPutsItDown() {
    let model = model()
    var calls = 0
    let interaction = BoardInteraction.userMove { _, _ in calls += 1; return .accepted }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.tap(.e2, geometry: geometry, interaction: interaction)

    #expect(model.selection == nil)
    #expect(model.legalDestinations.isEmpty)
    #expect(calls == 0)
  }

  @Test func tappingAnIllegalSquareDeselectsWithoutAskingTheCaller() {
    let model = model()
    var calls = 0
    let interaction = BoardInteraction.userMove { _, _ in calls += 1; return .accepted }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.tap(.a5, geometry: geometry, interaction: interaction)

    #expect(model.selection == nil)
    #expect(model.legalDestinations.isEmpty)
    #expect(calls == 0, "a square the piece cannot reach is not a move attempt")
  }

  @Test func tappingAnotherFriendlyPieceSwitchesTheSelection() {
    let model = model()
    var calls = 0
    let interaction = BoardInteraction.userMove { _, _ in calls += 1; return .accepted }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.tap(.g1, geometry: geometry, interaction: interaction)

    #expect(model.selection == .g1)
    #expect(model.legalDestinations == [.f3, .h3])
    #expect(calls == 0)
  }

  @Test func tappingAnEnemyPieceOnALegalSquareIsACapture() {
    // White pawn on e4, black pawn on d5.
    let model = model("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.tap(.e4, geometry: geometry, interaction: interaction)
    model.tap(.d5, geometry: geometry, interaction: interaction)

    #expect(played.count == 1, "an enemy piece on a legal square is a target, not a new selection")
    #expect(played.first?.1 == .d5)
  }

  @Test func tappingAnEnemyPieceOffTheLegalSquaresDeselects() {
    let model = model()
    var calls = 0
    let interaction = BoardInteraction.userMove { _, _ in calls += 1; return .accepted }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.tap(.d7, geometry: geometry, interaction: interaction)

    // The idle side cannot be picked up, so there is nothing to switch to.
    #expect(model.selection == nil)
    #expect(calls == 0)
  }

  @Test func tappingOffTheBoardDeselects() {
    let model = model()
    model.tap(.e2, geometry: geometry, interaction: .userMove { _, _ in .accepted })
    model.tap(nil, interaction: .userMove { _, _ in .accepted })
    #expect(model.selection == nil)
  }

  // MARK: - The same thing, through the gesture

  @Test func aPressAndLiftOnAPieceLeavesItSelected() {
    // The regression test for the original bug: the press selected the piece and
    // the lift ran the same square through the tap rules, which read it as
    // "tapped the piece that is already selected" and put it straight back down.
    let model = model()
    model.pressAndLift(.e2, geometry: geometry, interaction: .userMove { _, _ in .accepted })

    #expect(model.selection == .e2)
    #expect(model.legalDestinations == [.e3, .e4])
  }

  @Test func pressAndLiftTwicePlaysTheMove() {
    let model = model()
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.pressAndLift(.g1, geometry: geometry, interaction: interaction)
    model.pressAndLift(.f3, geometry: geometry, interaction: interaction)

    #expect(played.count == 1)
    #expect(played.first?.0 == .g1)
    #expect(played.first?.1 == .f3)
  }

  @Test func aPressThatTravelsIsADragAndStillPlaysTheMove() {
    let model = model()
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.dragPiece(from: .d2, to: .d4, geometry: geometry, interaction: interaction)

    #expect(played.count == 1)
    #expect(played.first?.1 == .d4)
    #expect(model.selection == nil, "finishing a drag hands the board back")
    #expect(model.drag == nil)
  }

  @Test func aDragCanStartOnAnAlreadySelectedPiece() {
    let model = model()
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.dragPiece(from: .e2, to: .e4, geometry: geometry, interaction: interaction)

    #expect(played.count == 1, "selection must not block the drag it was going to become")
    #expect(model.drag == nil)
  }

  @Test func aDragBackToTheOriginKeepsTheSelectionForAFollowUpTap() {
    let model = model()
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.dragPiece(from: .e2, to: .e2, geometry: geometry, interaction: interaction)
    #expect(played.isEmpty)
    #expect(model.selection == .e2, "putting a piece back down should not cost the pick-up")

    model.tap(.e4, geometry: geometry, interaction: interaction)
    #expect(played.count == 1)
  }

  @Test func aDragOffTheBoardIsAnAbort() {
    let model = model()
    var calls = 0
    let interaction = BoardInteraction.userMove { _, _ in calls += 1; return .accepted }

    let start = geometry.center(of: .e2)
    let away = CGPoint(x: geometry.side + geometry.squareSide * 3, y: geometry.side / 2)
    model.pressChanged(start: start, location: start, geometry: geometry, interaction: interaction)
    model.pressChanged(start: start, location: away, geometry: geometry, interaction: interaction)
    model.pressEnded(start: start, location: away, geometry: geometry, interaction: interaction)

    #expect(calls == 0)
    #expect(model.selection == nil)
    #expect(model.drag == nil)
  }

  @Test func aPressThatBarelyMovesIsStillATap() {
    let model = model()
    let interaction = BoardInteraction.userMove { _, _ in .accepted }

    let start = geometry.center(of: .e2)
    // Less than the threshold: a hand is never perfectly still, and if that
    // counted as a drag then tap-to-move would fail for anyone with a tremor.
    let jitter = CGPoint(x: start.x + geometry.dragThreshold * 0.5, y: start.y)
    model.pressChanged(start: start, location: jitter, geometry: geometry, interaction: interaction)
    model.pressEnded(start: start, location: jitter, geometry: geometry, interaction: interaction)

    #expect(model.selection == .e2)
    #expect(model.drag == nil)
  }

  // MARK: - Interaction modes

  @Test func lockedBoardsAcceptNothing() {
    let model = model()
    model.pressAndLift(.e2, geometry: geometry, interaction: .locked)
    #expect(model.selection == nil)

    model.tap(.e2, interaction: .locked)
    #expect(model.selection == nil)
    #expect(model.drag == nil)
  }

  @Test func replayBoardsSelectButNeverMove() {
    let model = model()

    model.pressAndLift(.e2, geometry: geometry, interaction: .replay)
    #expect(model.selection == .e2, "previewing legal moves is most of why people replay a game")
    #expect(model.legalDestinations == [.e3, .e4])

    model.pressAndLift(.e4, geometry: geometry, interaction: .replay)
    #expect(model.selection == nil)
    #expect(model.position == .standard, "replay cannot change the game")
  }

  @Test func replayBoardsCanInterrogateEitherSide() {
    let model = model()
    model.pressAndLift(.b8, geometry: geometry, interaction: .replay)
    #expect(model.selection == .b8)
    #expect(model.legalDestinations == [.a6, .c6])
  }

  @Test func replayDragsPutThePieceBackAndKeepTheDots() {
    let model = model()
    model.dragPiece(from: .e2, to: .e4, geometry: geometry, interaction: .replay)
    #expect(model.position == .standard)
    #expect(model.selection == .e2)
    #expect(model.drag == nil)
  }

  // MARK: - Refusal

  @Test func aRefusedTapRestoresTheSelectionAndThePosition() {
    let model = model()
    let before = model.position
    let interaction = BoardInteraction.userMove { _, _ in .rejected(reason: "Look again.") }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.tap(.e4, geometry: geometry, interaction: interaction)

    #expect(model.position == before)
    #expect(model.layout.token(at: .e2) != nil)
    #expect(model.rejection?.square == .e2)
    #expect(model.rejection?.reason == "Look again.")
    // Still in hand, so the second try is one tap rather than a fresh pick-up.
    #expect(model.selection == .e2)
    #expect(model.legalDestinations == [.e3, .e4])
  }

  @Test func aRefusedDragTravelsHomeRatherThanTeleporting() {
    let model = model()
    model.dragPiece(
      from: .e2,
      to: .e4,
      geometry: geometry,
      interaction: .userMove { _, _ in .rejected }
    )

    // The ghost is still on screen and aimed at the origin; a piece that simply
    // vanished back to its square reads as a dropped frame, not as a refusal.
    #expect(model.drag?.isReturning == true)
    #expect(model.drag?.target == .e2)
    #expect(model.drag?.location == geometry.center(of: .e2))
    #expect(model.selection == .e2)
  }

  @Test func aSecondTryAfterARefusalCanBeASingleTap() {
    let model = model()
    var attempts: [Square] = []
    let interaction = BoardInteraction.userMove { _, to in
      attempts.append(to)
      return to == .e4 ? .rejected(reason: "Too fast.") : .accepted
    }

    model.tap(.e2, geometry: geometry, interaction: interaction)
    model.tap(.e4, geometry: geometry, interaction: interaction)
    model.tap(.e3, geometry: geometry, interaction: interaction)

    #expect(attempts == [.e4, .e3])
    #expect(model.rejection == nil, "a move that lands clears the refusal mark")
  }

  // MARK: - Promotion

  @Test func tappingAPromotionSquareOpensThePicker() {
    let model = model("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    var chosen: Piece.Kind?
    let interaction = BoardInteraction.userMove { _, _ in
      .needsPromotion(complete: { kind in
        chosen = kind
        return .accepted
      })
    }

    model.tap(.d7, geometry: geometry, interaction: interaction)
    model.tap(.d8, geometry: geometry, interaction: interaction)

    #expect(model.pendingPromotion?.from == .d7)
    #expect(model.pendingPromotion?.to == .d8)
    #expect(chosen == nil, "the move is suspended, not applied")

    model.choosePromotion(.queen, geometry: geometry)
    #expect(chosen == .queen)
    #expect(model.pendingPromotion == nil)
    #expect(model.selection == nil)
  }

  @Test func aPromotionRefusedAfterTheChoiceStillSnapsBack() {
    let model = model("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    let interaction = BoardInteraction.userMove { _, _ in
      .needsPromotion(complete: { _ in .rejected(reason: "Underpromotion loses here.") })
    }

    model.tap(.d7, geometry: geometry, interaction: interaction)
    model.tap(.d8, geometry: geometry, interaction: interaction)
    model.choosePromotion(.knight, geometry: geometry)

    #expect(model.rejection?.reason == "Underpromotion loses here.")
    #expect(model.rejection?.square == .d7)
    #expect(model.selection == .d7)
    #expect(model.position.piece(at: .d7)?.kind == .pawn)
  }

  @Test func theBoardIgnoresTapsWhileThePickerIsUp() {
    let model = model("8/3P2k1/8/8/8/8/6K1/8 w - - 0 1")
    var attempts = 0
    let interaction = BoardInteraction.userMove { _, _ in
      attempts += 1
      return .needsPromotion
    }

    model.tap(.d7, geometry: geometry, interaction: interaction)
    model.tap(.d8, geometry: geometry, interaction: interaction)
    #expect(attempts == 1)

    // The choice belongs to the move in flight; a stray tap on the board behind
    // the picker must not start a second one.
    model.pressAndLift(.g7, geometry: geometry, interaction: interaction)
    model.tap(.d8, geometry: geometry, interaction: interaction)
    #expect(attempts == 1)
    #expect(model.pendingPromotion != nil)
  }

  // MARK: - Animation and interruption

  @Test func aPositionArrivingMidPressDiscardsTheLift() {
    let model = model()
    var calls = 0
    let interaction = BoardInteraction.userMove { _, _ in calls += 1; return .accepted }

    let start = geometry.center(of: .e2)
    model.pressChanged(start: start, location: start, geometry: geometry, interaction: interaction)

    // The engine replies while the finger is still down.
    var board = Board(position: .standard)
    board.move(pieceAt: .g1, to: .f3)
    model.update(position: board.position)

    model.pressEnded(start: start, location: start, geometry: geometry, interaction: interaction)

    #expect(calls == 0, "the lift meant something about a board that no longer exists")
    #expect(model.selection == nil)
    #expect(model.drag == nil)
  }

  @Test func aTapDuringASnapBackDoesNotStrandTheReturningPiece() {
    let model = model()
    model.dragPiece(
      from: .e2,
      to: .e4,
      geometry: geometry,
      interaction: .userMove { _, _ in .rejected }
    )
    #expect(model.drag?.isReturning == true)

    // A second press lands while the refused pawn is still travelling home.
    model.pressAndLift(.g1, geometry: geometry, interaction: .userMove { _, _ in .accepted })

    #expect(model.drag?.isReturning == true, "the animation owns the drag state, not the new press")
    #expect(model.drag?.origin == .e2)
    #expect(model.selection == .g1)
  }

  @Test func aSnapBackClearsItselfAndLetsPlayResume() async {
    let model = model()
    model.dragPiece(
      from: .e2,
      to: .e4,
      geometry: geometry,
      interaction: .userMove { _, _ in .rejected }
    )

    try? await Task.sleep(for: .milliseconds(300))
    #expect(model.drag == nil)

    var played = 0
    model.dragPiece(
      from: .e2,
      to: .e3,
      geometry: geometry,
      interaction: .userMove { _, _ in played += 1; return .accepted }
    )
    #expect(played == 1)
  }

  // MARK: - Accessibility

  @Test func squareLabelsNameTheSquareAndItsOccupant() {
    let model = model()
    #expect(model.accessibilityLabel(for: .e2) == "e2, white pawn")
    #expect(model.accessibilityLabel(for: .g8) == "g8, black knight")
    #expect(model.accessibilityLabel(for: .e4) == "e4, empty")
  }

  @Test func squareLabelsAnnounceTheCurrentSelectionAndItsTargets() {
    let model = model("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    model.select(.e4)

    #expect(model.accessibilityLabel(for: .e4) == "e4, white pawn, selected")
    #expect(model.accessibilityLabel(for: .e5) == "e5, empty, legal move")
    #expect(model.accessibilityLabel(for: .d5) == "d5, black pawn, legal capture")
    #expect(model.accessibilityLabel(for: .a3) == "a3, empty", "unrelated squares stay quiet")
  }

  @Test func squareHintsDescribeWhatActivationWouldDo() {
    let model = model("rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")
    let interaction = BoardInteraction.userMove { _, _ in .accepted }

    #expect(model.accessibilityHint(for: .e4, interaction: interaction) == "Selects")
    #expect(model.accessibilityHint(for: .d5, interaction: interaction) == nil)

    model.select(.e4)
    #expect(model.accessibilityHint(for: .e4, interaction: interaction) == "Deselects")
    #expect(model.accessibilityHint(for: .e5, interaction: interaction) == "Moves here")
    #expect(model.accessibilityHint(for: .d5, interaction: interaction) == "Captures")
  }

  @Test func lockedSquaresOfferNoActionAndReplaySquaresOnlyPreview() {
    let model = model()
    #expect(model.accessibilityHint(for: .e2, interaction: .locked) == nil)
    #expect(model.accessibilityHint(for: .e2, interaction: .replay) == "Shows legal moves")
  }

  @Test func voiceOverCanSelectAndMoveWithTwoActivations() {
    // `tap` is what an accessibility action calls, so the VoiceOver path is the
    // pointer path with the geometry left out.
    let model = model()
    var played: [(Square, Square)] = []
    let interaction = BoardInteraction.userMove { from, to in
      played.append((from, to))
      return .accepted
    }

    model.tap(.b1, interaction: interaction)
    #expect(model.selection == .b1)
    model.tap(.c3, interaction: interaction)

    #expect(played.count == 1)
    #expect(played.first?.0 == .b1)
    #expect(played.first?.1 == .c3)
  }
}

// MARK: - Gesture simulation

/// Drives the model the way `BoardView`'s drag gesture does, so the tests
/// exercise the real entry points rather than a paraphrase of them.
extension BoardModel {

  /// A finger down on a square and up again without travelling.
  fileprivate func pressAndLift(_ square: Square, geometry: BoardGeometry, interaction: BoardInteraction) {
    let point = geometry.center(of: square)
    pressChanged(start: point, location: point, geometry: geometry, interaction: interaction)
    pressEnded(start: point, location: point, geometry: geometry, interaction: interaction)
  }

  /// A press that travels far enough to count as a drag before it lifts.
  fileprivate func dragPiece(
    from: Square,
    to: Square,
    geometry: BoardGeometry,
    interaction: BoardInteraction
  ) {
    let start = geometry.center(of: from)
    let end = geometry.center(of: to)
    pressChanged(start: start, location: start, geometry: geometry, interaction: interaction)
    // A midpoint sample, because a real drag is a stream of them and the
    // threshold has to be crossed on the way rather than at the end.
    pressChanged(
      start: start,
      location: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
      geometry: geometry,
      interaction: interaction
    )
    pressChanged(start: start, location: end, geometry: geometry, interaction: interaction)
    pressEnded(start: start, location: end, geometry: geometry, interaction: interaction)
  }

  /// The square-level tap, with the argument order the tests read best in.
  fileprivate func tap(_ square: Square?, geometry: BoardGeometry, interaction: BoardInteraction) {
    tap(square, interaction: interaction, geometry: geometry)
  }
}
