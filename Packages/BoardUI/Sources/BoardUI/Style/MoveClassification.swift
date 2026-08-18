//
//  MoveClassification.swift
//  BoardUI
//

import SwiftUI

/// How a move was judged. Only these are ever badged — badging every move turns
/// the move list into noise.
public enum MoveClassification: String, CaseIterable, Hashable, Sendable, Identifiable {
  case best
  case great
  case inaccuracy
  case mistake
  case blunder

  public var id: String { rawValue }

  /// The label shown on a badge.
  public var title: String {
    switch self {
    case .best: "Best"
    case .great: "Great"
    case .inaccuracy: "Inaccuracy"
    case .mistake: "Mistake"
    case .blunder: "Blunder"
    }
  }

  /// SF Symbol for the badge glyph.
  public var symbolName: String {
    switch self {
    case .best: "checkmark.seal.fill"
    case .great: "sparkle"
    case .inaccuracy: "exclamationmark.circle.fill"
    case .mistake: "exclamationmark.triangle.fill"
    case .blunder: "xmark.octagon.fill"
    }
  }

  /// The semantic colour for this classification.
  ///
  /// Great and best resolve to the accent rather than green: green reads as
  /// "correct" everywhere else in the product, and reusing it here would make
  /// every good move look like a solved puzzle.
  public func color(in style: BoardStyle) -> DualColor {
    switch self {
    case .best, .great: style.accent
    case .inaccuracy: style.caution
    case .mistake: style.warning
    case .blunder: style.danger
    }
  }
}
