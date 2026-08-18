//
//  MaterialDelta.swift
//  BoardUI
//

import ChessKit

/// The change in material balance across one move, from one side's point of
/// view.
///
/// This exists so a capture can *say what it was worth*. A training app has
/// more use for that than a playing app does: the single hardest habit to build
/// is counting material before committing to a trade, and a number that appears
/// on the board every time material changes hands teaches it on every capture
/// instead of in a lesson nobody reads.
///
/// ## Whose point of view
///
/// The perspective is the **board's orientation** — the side the reader is
/// playing — not the side that happened to move. Measured from the mover, every
/// capture is a gain and the number is never red, which makes it decoration.
/// Measured from the reader, taking a knight is `+3` in green and losing a pawn
/// to the reply is `−1` in red, which is the actual lesson.
public struct MaterialDelta: Equatable, Sendable {

  /// Signed change in material, in pawns, from the perspective it was computed
  /// for. Positive means the perspective side is better off than before.
  public var value: Int

  public init(value: Int) {
    self.value = value
  }

  /// Whether the perspective side came out ahead.
  public var isGain: Bool { value > 0 }

  /// Whether anything changed at all.
  public var isZero: Bool { value == 0 }

  /// The floating label, e.g. `+3` or `−1`.
  ///
  /// A real U+2212 minus sign, not a hyphen: at the weight this is drawn, a
  /// hyphen next to a digit reads as a dash in a word.
  public var label: String {
    value > 0 ? "+\(value)" : (value < 0 ? "\u{2212}\(abs(value))" : "0")
  }

  // MARK: - Piece values

  /// The standard values, in pawns. The king is worth nothing here because it
  /// is never captured and including it would make every number nonsense.
  public static func value(of kind: Piece.Kind) -> Int {
    switch kind {
    case .pawn: 1
    case .knight, .bishop: 3
    case .rook: 5
    case .queen: 9
    case .king: 0
    }
  }

  /// Material on the board for one colour, in pawns.
  public static func material(in position: Position, for color: Piece.Color) -> Int {
    position.pieces.reduce(0) { total, piece in
      piece.color == color ? total + value(of: piece.kind) : total
    }
  }

  /// Material balance from one colour's point of view: its own material minus
  /// the opponent's.
  public static func balance(in position: Position, for color: Piece.Color) -> Int {
    material(in: position, for: color) - material(in: position, for: color.opposite)
  }

  /// How the balance moved between two positions.
  ///
  /// Promotion is included on purpose — a pawn becoming a queen is a `+8` swing
  /// and is exactly the kind of evaluation change worth marking.
  public static func between(
    _ before: Position,
    _ after: Position,
    for color: Piece.Color
  ) -> MaterialDelta {
    MaterialDelta(value: balance(in: after, for: color) - balance(in: before, for: color))
  }
}
