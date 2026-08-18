//
//  ClassificationBadge.swift
//  BoardUI
//

import SwiftUI

/// The badge that names how a move was judged.
///
/// Tinted fill plus a glyph, never a bare colour swatch: the four "bad" grades
/// differ only by hue, and hue alone is not a distinction a colour-blind reader
/// can make — or anyone can make on a phone in sunlight.
public struct ClassificationBadge: View {

  /// How much room the badge takes.
  public enum Size: Sendable {
    /// Glyph only. For thumbnail corners and chart tooltips.
    case compact
    /// Glyph plus label. The default.
    case regular

    var font: Font {
      switch self {
      case .compact: .caption2.weight(.semibold)
      case .regular: .caption.weight(.semibold)
      }
    }

    var horizontalPadding: CGFloat {
      switch self {
      case .compact: 5
      case .regular: 8
      }
    }

    var verticalPadding: CGFloat {
      switch self {
      case .compact: 3
      case .regular: 4
      }
    }
  }

  private let kind: MoveClassification
  private let size: Size
  private let style: BoardStyle

  @Environment(\.colorScheme) private var colorScheme

  public init(kind: MoveClassification, size: Size = .regular, style: BoardStyle = .default) {
    self.kind = kind
    self.size = size
    self.style = style
  }

  public var body: some View {
    HStack(spacing: 4) {
      Image(systemName: kind.symbolName)
        .imageScale(.small)
      if size == .regular {
        Text(kind.title)
      }
    }
    .font(size.font)
    .foregroundStyle(tint)
    .padding(.horizontal, size.horizontalPadding)
    .padding(.vertical, size.verticalPadding)
    .background(tint.opacity(0.16), in: Capsule())
    .accessibilityElement()
    .accessibilityLabel(Text(kind.title))
  }

  private var tint: Color {
    kind.color(in: style).color(colorScheme)
  }
}

// MARK: - Previews

#Preview("Classification badges") {
  VStack(alignment: .leading, spacing: 12) {
    ForEach(MoveClassification.allCases) { kind in
      HStack(spacing: 12) {
        ClassificationBadge(kind: kind)
        ClassificationBadge(kind: kind, size: .compact)
      }
    }
  }
  .padding()
}
