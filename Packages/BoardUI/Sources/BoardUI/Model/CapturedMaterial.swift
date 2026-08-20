//
//  CapturedMaterial.swift
//  BoardUI
//

import ChessKit

/// What each side has taken, and who is ahead.
///
/// ## Why this is derived rather than recorded
///
/// A game session could keep a list as captures happen, and that list would be
/// exactly right — but it would only exist for a game played from move one.
/// Puzzles open on a FEN from the middle of somebody else's game, and a review
/// scrubber jumps to an arbitrary ply. Deriving from the position means the same
/// readout works on all three, and it cannot drift out of sync with the board it
/// is drawn beside.
///
/// ## The promotion caveat, stated rather than hidden
///
/// A side's losses are counted as "what a full army has, minus what is left".
/// Promotion breaks that arithmetic: a queened pawn shows as a captured pawn and
/// an extra queen that never existed, so the extra is clamped away and the pawn
/// is over-counted by one. Every mainstream board does the same thing, because
/// the alternative is threading move history into a view that otherwise needs
/// none. The **balance** is unaffected — it is computed from material actually
/// on the board — so the number the user reads stays correct even when the row
/// of glyphs beside it is a pawn off.
public struct CapturedMaterial: Equatable, Sendable {

  /// A full army, by kind. The king is absent: it is never captured.
  static let fullArmy: [(kind: Piece.Kind, count: Int)] = [
    (.queen, 1), (.rook, 2), (.bishop, 2), (.knight, 2), (.pawn, 8),
  ]

  /// The kinds in display order, heaviest first. Exposed so a caller
  /// summarising a capture list reads it in the same order it is drawn.
  public static let fullArmyOrder: [Piece.Kind] = fullArmy.map(\.kind)

  /// The pieces `color` has lost, heaviest first — which is the same list as
  /// the pieces the *other* side has captured.
  public static func lost(by color: Piece.Color, in position: Position) -> [Piece.Kind] {
    var remaining: [Piece.Kind: Int] = [:]
    for piece in position.pieces where piece.color == color {
      remaining[piece.kind, default: 0] += 1
    }

    return fullArmy.flatMap { entry in
      // Clamped at zero: a promotion can leave more of a kind than started.
      let missing = max(0, entry.count - (remaining[entry.kind] ?? 0))
      return Array(repeating: entry.kind, count: missing)
    }
  }

  /// How far ahead `color` is, in pawns. Zero or negative when they are not.
  ///
  /// Read from the material on the board rather than from ``lost(by:in:)``, so
  /// the promotion caveat above cannot reach the number.
  public static func advantage(for color: Piece.Color, in position: Position) -> Int {
    MaterialDelta.balance(in: position, for: color)
  }
}
