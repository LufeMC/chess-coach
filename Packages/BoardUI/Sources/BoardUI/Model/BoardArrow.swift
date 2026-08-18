//
//  BoardArrow.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// What an arrow is saying.
public enum ArrowStyle: String, CaseIterable, Hashable, Sendable, Identifiable {
  /// The engine's first choice.
  case best
  /// A playable alternative — same colour as `best`, quieter.
  case alternative
  /// What the opponent is threatening.
  case threat
  /// A coach hint at the top of the hint ladder.
  case hint

  public var id: String { rawValue }

  func color(in style: BoardStyle) -> DualColor {
    switch self {
    case .best: style.accent
    case .alternative: style.accent
    case .threat: style.danger
    case .hint: style.caution
    }
  }

  /// Arrows are the loudest thing on the board, so only one of them is drawn at
  /// full strength. Alternatives drop to half so the best move still wins.
  var opacity: Double {
    switch self {
    case .best: 0.85
    case .alternative: 0.45
    case .threat: 0.8
    case .hint: 0.85
    }
  }
}

/// An arrow drawn between two squares.
public struct BoardArrow: Hashable, Sendable, Identifiable {

  public var from: Square
  public var to: Square
  public var style: ArrowStyle

  public var id: String { "\(from.notation)\(to.notation)-\(style.rawValue)" }

  public init(from: Square, to: Square, style: ArrowStyle = .best) {
    self.from = from
    self.to = to
    self.style = style
  }

  /// Convenience for a ChessKit move.
  public init(_ move: Move, style: ArrowStyle = .best) {
    self.init(from: move.start, to: move.end, style: style)
  }
}
