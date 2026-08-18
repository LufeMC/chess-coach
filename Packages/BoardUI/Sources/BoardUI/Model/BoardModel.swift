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

  func beginDrag(at square: Square, location: CGPoint) {
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
    clearSelection()
  }
}
