//
//  SquareHighlight.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// The visual treatments a square can receive.
///
/// Each kind renders as a distinctly *shaped* mark, not just a different colour:
/// a dot, a ring, a wash and a dashed border are all still distinguishable when
/// two of them land on the same square, and they survive colour-blindness.
public enum HighlightKind: String, CaseIterable, Hashable, Sendable, Identifiable {
  /// Square the last move started from — a quiet wash.
  case lastMoveFrom
  /// Square the last move ended on — the same wash, one step louder.
  case lastMoveTo
  /// The king is in check. A radial glow, so the king stays readable.
  case check
  /// The square the user has picked up or tapped.
  case selected
  /// A legal destination on an empty square. Centre dot.
  case legalMove
  /// A legal destination that captures. Ring around the target piece.
  case legalCapture
  /// Coach hint. Solid ring, the loudest non-destructive mark.
  case hint
  /// A square implicated in a review "moment". Dashed border, neutral.
  case momentSquare
  /// The square that was the right answer, after a wrong attempt.
  case correctAnswer

  public var id: String { rawValue }

  /// Whether the mark sits under the pieces (washes) or over them (rings, dots).
  ///
  /// Washes must go under so they never dim a piece; rings must go over so a
  /// capture target reads as circled rather than smudged.
  var drawsAbovePieces: Bool {
    switch self {
    case .legalCapture, .hint, .correctAnswer, .momentSquare: true
    case .lastMoveFrom, .lastMoveTo, .check, .selected, .legalMove: false
    }
  }
}

/// A square plus the treatment applied to it.
public struct SquareHighlight: Hashable, Sendable, Identifiable {

  public var square: Square
  public var kind: HighlightKind

  public var id: String { "\(square.notation)-\(kind.rawValue)" }

  public init(_ square: Square, _ kind: HighlightKind) {
    self.square = square
    self.kind = kind
  }

  public init(square: Square, kind: HighlightKind) {
    self.init(square, kind)
  }
}

extension SquareHighlight {

  /// Convenience for the pair of squares a move touched.
  public static func lastMove(from: Square, to: Square) -> [SquareHighlight] {
    [SquareHighlight(from, .lastMoveFrom), SquareHighlight(to, .lastMoveTo)]
  }

  /// Convenience for a completed `Move` from ChessKit.
  public static func lastMove(_ move: Move) -> [SquareHighlight] {
    lastMove(from: move.start, to: move.end)
  }
}
