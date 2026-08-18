//
//  BoardModel.swift
//  BoardUI
//

import ChessKit
import Observation
import SwiftUI

/// Mutable board state that belongs to the view, not to the game.
///
/// Selection, drag, hover and the pending promotion are all *presentation*
/// state — the caller owns the `Position` and is told about attempted moves
/// through ``BoardInteraction``. Keeping the two apart is what lets a rejected
/// move snap back with no rollback logic anywhere.
@MainActor
@Observable
final class BoardModel {

  // MARK: Position-derived state

  private(set) var position: Position
  private(set) var board: Board
  private(set) var layout = PieceLayout()
  /// Colour of the king currently in check, if any.
  private(set) var checkedColor: Piece.Color?

  /// Pieces that have just left the board.
  ///
  /// A captured piece is held for as long as the capturing piece takes to slide
  /// onto it. Removing it the instant the position changes leaves the target
  /// square visibly empty for the whole animation, which reads as the piece
  /// having been taken by nothing.
  private(set) var departing: [PieceToken] = []
  private var departureToken = 0

  var orientation: Piece.Color

  // MARK: Interaction state

  var selection: Square?
  var legalDestinations: Set<Square> = []
  var hoveredSquare: Square?
  var drag: DragState?
  var pendingPromotion: PendingPromotion?
  var rejection: Rejection?

  /// The press currently under the user's finger, if any.
  private(set) var press: Press?

  /// Set when the position changes under a press that is still in flight.
  private var pressInvalidated = false

  // MARK: Feedback counters
  //
  // `.sensoryFeedback` fires on a value *change*, so each event needs its own
  // monotonically increasing trigger rather than a shared enum.

  private(set) var placementTicks = 0
  private(set) var captureTicks = 0
  private(set) var checkTicks = 0

  struct DragState: Equatable {
    var origin: Square
    var tokenID: PieceToken.ID
    /// Current point in board space.
    var location: CGPoint
    /// Where the drop would land right now.
    var target: Square
    /// True once the pointer has travelled far enough to count as a drag.
    var isActive: Bool
    /// Set while the piece animates back after a refusal.
    var isReturning: Bool = false
  }

  struct PendingPromotion: Equatable {
    var from: Square
    var to: Square
    var color: Piece.Color
    var complete: MoveAcceptance.PromotionCompletion?

    static func == (lhs: PendingPromotion, rhs: PendingPromotion) -> Bool {
      lhs.from == rhs.from && lhs.to == rhs.to && lhs.color == rhs.color
    }
  }

  struct Rejection: Equatable {
    var square: Square
    var reason: String?
    var token: Int
  }

  /// A press in flight, from touch-down to lift.
  ///
  /// The lift can only be interpreted in the light of what the press already
  /// did. A press that *created* the selection has done the tap's work
  /// already; sending its lift through ``tap(_:interaction:geometry:)`` as well
  /// would read as "tapped the selected piece" and switch the selection
  /// straight back off, which is precisely why tap-then-tap used to do nothing.
  struct Press: Equatable {
    /// Square the press went down on. `nil` when it landed off the board.
    var square: Square?
    /// True when this press is what put the selection on `square`.
    var selectedOnPress: Bool
  }

  private var rejectionToken = 0

  init(position: Position, orientation: Piece.Color) {
    self.position = position
    self.orientation = orientation
    self.board = Board(position: position)
    self.checkedColor = Self.checkedKing(in: position)
    self.layout.apply(position: position)
  }

  /// Which king, if either, is in check in `position`.
  ///
  /// `Board.state` is phrased relative to the side that just *moved*, so a board
  /// built straight from a position answers about the wrong king — it reports on
  /// the side **not** to move. Asking the same question with the turn flipped
  /// puts it back the right way round and reuses ChessKit's own attack
  /// detection rather than reimplementing it here.
  ///
  /// The clock and en-passant fields are neutralised because `Board` resolves
  /// draw conditions *before* check, and a long shuffle would otherwise report a
  /// fifty-move draw over the top of a real check.
  private static func checkedKing(in position: Position) -> Piece.Color? {
    var fields = position.fen.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 6 else { return nil }
    fields[1] = fields[1] == "w" ? "b" : "w"
    fields[3] = "-"
    fields[4] = "0"
    guard let flipped = Position(fen: fields.joined(separator: " ")) else { return nil }

    switch Board(position: flipped).state {
    case .check(let color), .checkmate(let color):
      return color
    default:
      return nil
    }
  }

  // MARK: - External updates

  /// Called whenever the caller publishes a new position.
  func update(position newPosition: Position) {
    guard newPosition != position else { return }

    let previousPieceCount = position.pieces.count
    let previousTokens = layout.tokens
    position = newPosition
    board = Board(position: newPosition)
    checkedColor = Self.checkedKing(in: newPosition)
    layout.apply(position: newPosition)
    holdDepartingPieces(from: previousTokens)

    // Any external change ends the current interaction — the piece the user was
    // holding may no longer exist.
    selection = nil
    legalDestinations = []
    drag = nil
    pendingPromotion = nil
    // Whatever was refused, the game has moved on from it.
    rejection = nil

    // A gesture still in the user's finger was aimed at a board that has just
    // stopped existing — an engine reply landing mid-tap is the usual cause.
    // Marking it means the lift is discarded rather than replayed against
    // whatever now happens to occupy those squares.
    if press != nil {
      press = nil
      pressInvalidated = true
    }

    placementTicks += 1
    if newPosition.pieces.count < previousPieceCount {
      captureTicks += 1
    }
    if checkedColor != nil {
      checkTicks += 1
    }
  }

  /// Keeps just-captured pieces on screen until the capturing piece arrives.
  private func holdDepartingPieces(from previous: [PieceToken]) {
    let live = Set(layout.tokens.map(\.id))
    let gone = previous.filter { !live.contains($0.id) }
    departing = gone
    guard !gone.isEmpty else { return }

    departureToken += 1
    let token = departureToken
    Task { @MainActor in
      // Slightly longer than the piece slide so the capture never uncovers an
      // empty square, short enough that it is never noticed as a delay.
      try? await Task.sleep(for: .milliseconds(220))
      if self.departureToken == token { self.departing = [] }
    }
  }

  // MARK: - Selection

  func canPickUp(_ square: Square, interaction: BoardInteraction) -> Bool {
    guard interaction.allowsPieceSelection else { return false }
    guard let piece = position.piece(at: square) else { return false }
    // Only the side to move can be picked up. Letting the idle side be dragged
    // looks responsive but produces a rejection on every single drop.
    return piece.color == position.sideToMove || !interaction.allowsMoves
  }

  func select(_ square: Square) {
    selection = square
    legalDestinations = Set(board.legalMoves(forPieceAt: square))
  }

  func clearSelection() {
    selection = nil
    legalDestinations = []
  }

  /// Highlights generated by the current interaction, merged with the caller's.
  func interactionHighlights() -> [SquareHighlight] {
    var result: [SquareHighlight] = []
    if let selection {
      result.append(SquareHighlight(selection, .selected))
    }
    for destination in legalDestinations.sorted(by: { $0.rawValue < $1.rawValue }) {
      result.append(SquareHighlight(destination, isCapture(destination) ? .legalCapture : .legalMove))
    }
    return result
  }

  /// Whether moving the selected piece to `square` takes something.
  ///
  /// En passant counts: the target square is empty, but a pawn still comes off,
  /// and showing it as a quiet move would misrepresent the position.
  func isCapture(_ square: Square) -> Bool {
    if let occupant = position.piece(at: square) {
      return occupant.color != position.sideToMove
    }
    guard let selection, let piece = position.piece(at: selection), piece.kind == .pawn else {
      return false
    }
    return selection.fileNumber != square.fileNumber
  }

  /// The square holding the king that is currently in check, if any.
  var checkedKingSquare: Square? {
    guard let checkedColor else { return nil }
    return position.pieces.first { $0.kind == .king && $0.color == checkedColor }?.square
  }

  // MARK: - Pointer input
  //
  // Tap-tap and drag-and-drop are one gesture, not two modes: a press that
  // never travels is a tap, one that travels is a drag, and either can finish a
  // move the other one started. The whole state machine lives here rather than
  // in the view so the rules can be exercised without rendering a board.

  /// Handles pointer movement, beginning the press on the first callback.
  ///
  /// A zero-distance drag gesture has no separate "began" callback — the first
  /// change *is* the touch-down — so the press is opened lazily here.
  func pressChanged(
    start: CGPoint,
    location: CGPoint,
    geometry: BoardGeometry,
    interaction: BoardInteraction
  ) {
    guard interaction.allowsPieceSelection, pendingPromotion == nil else { return }

    if press == nil {
      beginPress(at: start, geometry: geometry, interaction: interaction)
    }

    let travelled = hypot(location.x - start.x, location.y - start.y)
    updateDrag(
      location: location,
      target: geometry.nearestSquare(to: location),
      isActive: travelled > geometry.dragThreshold
    )
  }

  /// Handles the lift, resolving the press as either a drop or a tap.
  func pressEnded(
    start: CGPoint,
    location: CGPoint,
    geometry: BoardGeometry,
    interaction: BoardInteraction
  ) {
    guard interaction.allowsPieceSelection, pendingPromotion == nil else {
      press = nil
      return
    }
    guard !pressInvalidated else {
      press = nil
      pressInvalidated = false
      endLiveDrag()
      clearSelection()
      return
    }
    // Every real press arrives through `pressChanged` first. Opening one here
    // as well costs nothing and keeps a lone `onEnded` behaving like a tap
    // rather than like nothing at all.
    if press == nil {
      beginPress(at: start, geometry: geometry, interaction: interaction)
    }
    let press = self.press
    self.press = nil

    let travelled = hypot(location.x - start.x, location.y - start.y)
    let wasDrag = liveDrag?.isActive == true || travelled > geometry.dragThreshold

    if let drag = liveDrag, wasDrag {
      drop(drag, at: location, geometry: geometry, interaction: interaction)
      return
    }

    endLiveDrag()
    guard let press else {
      clearSelection()
      return
    }
    // The press has already selected this square; taking the lift through
    // `tap` as well would toggle the selection straight back off.
    guard !press.selectedOnPress else { return }
    tap(press.square, interaction: interaction, geometry: geometry)
  }

  /// Opens a press: picks the piece up when there is one to pick up.
  ///
  /// The piece is lifted on touch-down so a drag can start from the very first
  /// movement. A press that turns out to be a tap simply puts it back down.
  private func beginPress(at point: CGPoint, geometry: BoardGeometry, interaction: BoardInteraction) {
    pressInvalidated = false

    var record = Press(square: geometry.square(at: point), selectedOnPress: false)
    defer { press = record }

    guard let square = record.square else { return }
    // A press on a square the selected piece can reach is a move in waiting,
    // not a new selection — even when one of our own pieces is standing there,
    // which is how castling reads when the rook is the target square.
    if interaction.allowsMoves, selection != nil, legalDestinations.contains(square) { return }
    guard canPickUp(square, interaction: interaction) else { return }

    if selection != square {
      select(square)
      record.selectedOnPress = true
    }
    beginDrag(at: square, location: point)
  }

  /// What a press that never travelled means, expressed purely in squares.
  ///
  /// This is also the entry point VoiceOver uses, which is why it takes no
  /// geometry it cannot do without: activating a square is a tap on it.
  func tap(_ square: Square?, interaction: BoardInteraction, geometry: BoardGeometry? = nil) {
    guard interaction.allowsPieceSelection, pendingPromotion == nil else { return }
    guard let square else {
      // Released off the board: nothing was aimed at, so put the piece down.
      clearSelection()
      return
    }

    if let selection {
      // Tapping the piece again puts it down.
      if square == selection {
        clearSelection()
        return
      }
      // A legal destination is a move whatever is standing on it. An enemy
      // piece there is a capture, not a request to look at the other side.
      if interaction.allowsMoves, legalDestinations.contains(square) {
        attemptMove(from: selection, to: square, interaction: interaction, geometry: geometry)
        return
      }
    }

    if canPickUp(square, interaction: interaction) {
      select(square)
    } else {
      clearSelection()
    }
  }

  /// Resolves a drag that has been released.
  func drop(
    _ drag: DragState,
    at point: CGPoint,
    geometry: BoardGeometry,
    interaction: BoardInteraction
  ) {
    // A release more than one square outside the board is an abort, not a move
    // to the nearest edge square — that is how people take a drag back.
    let bounds = CGRect(x: 0, y: 0, width: geometry.side, height: geometry.side)
      .insetBy(dx: -geometry.squareSide, dy: -geometry.squareSide)
    guard bounds.contains(point) else {
      endLiveDrag()
      clearSelection()
      return
    }

    let target = geometry.nearestSquare(to: point)
    guard target != drag.origin else {
      // Dropped back where it started: keep the selection so the move can still
      // be finished with a tap instead of picking the piece up again.
      endLiveDrag()
      if selection != drag.origin { select(drag.origin) }
      return
    }
    guard interaction.allowsMoves else {
      // Replay: the piece goes back but the legal-move dots stay up, because
      // asking "where could that have gone?" is the whole point of the mode.
      endLiveDrag()
      return
    }
    attemptMove(from: drag.origin, to: target, interaction: interaction, geometry: geometry)
  }

  // MARK: - Accessibility
  //
  // The board is the app's primary control, so it has to be operable without
  // pointing at anything. Every square gets its own element, and the two
  // strings below are what a reader hears: where they are, and what happens if
  // they act. They live on the model rather than in the layer because they are
  // derived from interaction state, and because that makes them testable.

  /// What a square *is*: its name, its occupant, and its role in the move being
  /// composed. Complete on its own — hints can be switched off, labels cannot.
  func accessibilityLabel(for square: Square) -> String {
    var parts = [square.notation]
    if let piece = position.piece(at: square) {
      parts.append("\(piece.color.description) \(piece.kind.description)".lowercased())
    } else {
      parts.append("empty")
    }
    if square == selection {
      parts.append("selected")
    } else if selection != nil, legalDestinations.contains(square) {
      parts.append(isCapture(square) ? "legal capture" : "legal move")
    }
    return parts.joined(separator: ", ")
  }

  /// What activating a square would *do*, or `nil` when it would do nothing.
  func accessibilityHint(for square: Square, interaction: BoardInteraction) -> String? {
    guard interaction.allowsPieceSelection, pendingPromotion == nil else { return nil }
    if square == selection { return "Deselects" }
    if interaction.allowsMoves, selection != nil, legalDestinations.contains(square) {
      return isCapture(square) ? "Captures" : "Moves here"
    }
    if canPickUp(square, interaction: interaction) {
      return interaction.allowsMoves ? "Selects" : "Shows legal moves"
    }
    return nil
  }

  // MARK: - Move attempts

  /// Runs a move attempt through the caller's handler and reacts to the answer.
  func attemptMove(
    from: Square,
    to: Square,
    interaction: BoardInteraction,
    geometry: BoardGeometry? = nil
  ) {
    guard let handler = interaction.moveHandler else {
      clearSelection()
      return
    }
    guard from != to else {
      endDrag()
      return
    }

    resolve(handler(from, to), from: from, to: to, geometry: geometry)
  }

  private func resolve(
    _ acceptance: MoveAcceptance,
    from: Square,
    to: Square,
    geometry: BoardGeometry? = nil
  ) {
    switch acceptance {
    case .accepted:
      // The caller will publish a new position; clear local state now so the
      // board does not show a stale selection for a frame.
      clearSelection()
      endDrag()
      // A move that lands answers the refusal that came before it. Leaving the
      // red ring and its caption up would have them describing the move the
      // user just fixed.
      rejection = nil

    case let .rejected(reason):
      snapBack(to: from, reason: reason, in: geometry)

    case let .needsPromotion(complete):
      let color = position.piece(at: from)?.color ?? position.sideToMove
      pendingPromotion = PendingPromotion(from: from, to: to, color: color, complete: complete)
      endDrag()
    }
  }

  /// Completes a pending promotion with the chosen piece kind.
  func choosePromotion(_ kind: Piece.Kind, geometry: BoardGeometry? = nil) {
    guard let pending = pendingPromotion else { return }
    pendingPromotion = nil
    guard let complete = pending.complete else {
      // No completion handler: the caller is driving promotion itself and just
      // needed the picker's UI. Nothing more for the board to do.
      clearSelection()
      return
    }
    resolve(complete(kind), from: pending.from, to: pending.to, geometry: geometry)
  }

  func cancelPromotion() {
    pendingPromotion = nil
    clearSelection()
  }

  // MARK: - Drag

  /// The drag that belongs to the gesture in the user's finger.
  ///
  /// A piece flying home from a refusal still has a ``DragState``, but that one
  /// is animation, not input: treating it as the current gesture would let a
  /// fresh tap "drop" a piece the user is not holding.
  var liveDrag: DragState? {
    guard let drag, !drag.isReturning else { return nil }
    return drag
  }

  func beginDrag(at square: Square, location: CGPoint) {
    // Never interrupt a snap-back. Replacing the returning state strands its
    // ghost on the wrong square while the real token is still drawn hidden.
    guard drag?.isReturning != true else { return }
    guard let token = layout.token(at: square) else { return }
    drag = DragState(
      origin: square,
      tokenID: token.id,
      location: location,
      target: square,
      isActive: false
    )
  }

  func updateDrag(location: CGPoint, target: Square, isActive: Bool) {
    guard var current = drag, !current.isReturning else { return }
    current.location = location
    current.target = target
    current.isActive = current.isActive || isActive
    drag = current
  }

  func endDrag() {
    drag = nil
  }

  /// Ends the user's drag while leaving a snap-back in flight alone.
  private func endLiveDrag() {
    if drag?.isReturning != true { drag = nil }
  }

  /// Animates the dragged piece home and flashes the origin square.
  ///
  /// The snap-back is the entire point of `.rejected` — a piece that simply
  /// vanishes back to its square reads as a dropped frame, while one that
  /// travels back reads as "no, not that one".
  func snapBack(to square: Square, reason: String?, in geometry: BoardGeometry? = nil) {
    rejectionToken += 1
    rejection = Rejection(square: square, reason: reason, token: rejectionToken)

    if var current = drag {
      current.isReturning = true
      current.target = square
      if let geometry {
        current.location = geometry.center(of: square)
      }
      drag = current
      let token = rejectionToken
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(180))
        if self.drag?.isReturning == true { self.drag = nil }
        try? await Task.sleep(for: .milliseconds(1_600))
        if self.rejection?.token == token { self.rejection = nil }
      }
    } else {
      let token = rejectionToken
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1_800))
        if self.rejection?.token == token { self.rejection = nil }
      }
    }

    // A refusal puts the board back exactly as it was before the attempt, the
    // selection included. That is what makes the second-try flow work by tap as
    // well as by drag: "no, not that one" leaves the piece in hand, so the next
    // try is one tap rather than a fresh pick-up.
    if position.piece(at: square) != nil {
      select(square)
    } else {
      clearSelection()
    }
  }
}
