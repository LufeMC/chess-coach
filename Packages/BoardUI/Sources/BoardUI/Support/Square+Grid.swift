//
//  Square+Grid.swift
//  BoardUI
//

import ChessKit

// ChessKit's `Square(_ file:_ rank:)` initialiser is internal, so BoardUI
// reconstructs squares through the raw value instead. The case order in
// ChessKit is a1…h1, a2…h2, … h8, which makes the raw value exactly
// `(rank - 1) * 8 + (file - 1)`.
extension Square {

  /// Builds a square from a 1-based file number and 1-based rank number.
  ///
  /// Returns `nil` when either coordinate is off the board, which keeps
  /// out-of-bounds handling explicit at the call site rather than silently
  /// clamping to `a1` the way `Square(_:_:)` does.
  static func at(file: Int, rank: Int) -> Square? {
    guard (1...8).contains(file), (1...8).contains(rank) else { return nil }
    return Square(rawValue: (rank - 1) * 8 + (file - 1))
  }

  /// The 1-based file number, `a` = 1.
  var fileNumber: Int { file.number }

  /// The 1-based rank number.
  var rankNumber: Int { rank.value }

  /// Chebyshev (king-move) distance between two squares.
  static func distance(_ a: Square, _ b: Square) -> Int {
    max(abs(a.fileNumber - b.fileNumber), abs(a.rankNumber - b.rankNumber))
  }

  /// Whether the displacement between two squares is a knight's jump.
  ///
  /// Used by the arrow layer: knight arrows are the one case where a straight
  /// shaft reads as the wrong move, so they get a bowed shaft instead.
  static func isKnightMove(from: Square, to: Square) -> Bool {
    let df = abs(from.fileNumber - to.fileNumber)
    let dr = abs(from.rankNumber - to.rankNumber)
    return (df == 1 && dr == 2) || (df == 2 && dr == 1)
  }
}
