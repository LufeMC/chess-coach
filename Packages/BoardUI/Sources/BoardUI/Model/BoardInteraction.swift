//
//  BoardInteraction.swift
//  BoardUI
//

import ChessKit

/// The board's answer to "the user tried to play this move".
///
/// The board never mutates the position itself — the caller owns game state.
/// This is the whole reason the second-try training flow works: the coach can
/// refuse a blunder, the board snaps the piece back, and nothing downstream has
/// to be rolled back because nothing downstream ever moved.
public enum MoveAcceptance {

  /// The move stands. The caller is expected to publish a new `Position`.
  case accepted

  /// The move is refused and the piece returns to where it started.
  /// `reason` is surfaced briefly under the board when non-nil.
  case rejected(reason: String?)

  /// The move needs a promotion piece before it can be judged.
  ///
  /// The board presents the inline picker over the destination square and calls
  /// `complete` with the chosen kind; whatever that returns is treated as the
  /// final answer, so a caller can still reject after seeing the choice.
  /// Use the parameterless ``needsPromotion`` when the caller tracks its own
  /// pending promotion (for example via ChessKit's `Board.state`).
  case needsPromotion(complete: PromotionCompletion?)

  /// A promotion handler: given the chosen kind, return the final acceptance.
  public typealias PromotionCompletion = @MainActor (Piece.Kind) -> MoveAcceptance

  /// `.needsPromotion` with no completion handler.
  ///
  /// Spelled as a static so callers can write the bare `.needsPromotion` the
  /// simple case reads best as, while the associated-value form stays available.
  public static var needsPromotion: MoveAcceptance { .needsPromotion(complete: nil) }

  /// `.rejected` with no explanation.
  public static var rejected: MoveAcceptance { .rejected(reason: nil) }
}

/// How much the board lets the user do.
public enum BoardInteraction {

  /// Nothing is tappable. Used for thumbnails and for boards the coach drives.
  case locked

  /// Read-only, but a tap on a piece still reveals its legal moves.
  ///
  /// Review scrubbing wants exactly this: you cannot change the game, but being
  /// able to ask "where could that knight have gone?" is most of why people
  /// replay a game at all.
  case replay

  /// The user may play moves. `onMove` decides whether each attempt stands.
  case userMove(onMove: @MainActor (Square, Square) -> MoveAcceptance)

  /// Whether a piece can be picked up at all.
  var allowsPieceSelection: Bool {
    switch self {
    case .locked: false
    case .replay, .userMove: true
    }
  }

  /// Whether a selected piece can actually be moved.
  var allowsMoves: Bool {
    switch self {
    case .locked, .replay: false
    case .userMove: true
    }
  }

  var moveHandler: (@MainActor (Square, Square) -> MoveAcceptance)? {
    switch self {
    case .locked, .replay: nil
    case let .userMove(handler): handler
    }
  }
}
