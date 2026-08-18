//
//  PieceRenderer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Selects and configures the artwork used to draw pieces.
///
/// The default ``vector`` set needs no bundled assets, which is what lets the
/// board render in previews from a clean checkout. ``images(named:prefix:bundleIdentifier:)``
/// is the seam for a real piece set later: it resolves `Image(name, bundle:)` at
/// draw time and silently falls back to the vector set when an asset is missing,
/// so shipping artwork is an additive change with no call-site churn.
public struct PieceRenderer: Hashable, Sendable, Identifiable {

  /// Where the artwork comes from.
  public enum Source: Hashable, Sendable {
    /// Built-in vector silhouettes. No assets required.
    case vector
    /// System font chess glyphs. A cheap fallback for very small thumbnails.
    case unicode
    /// Asset-catalog images named `"\(prefix)\(colorLetter)\(kindLetter)"`,
    /// e.g. `"merida-wK"`. The bundle is resolved by identifier so the value
    /// stays `Sendable`.
    case images(bundleIdentifier: String?, prefix: String)
  }

  public var id: String { name }

  /// Name shown in settings.
  public var name: String
  public var source: Source

  /// Fill for white pieces. Near-white in both appearances — a piece that
  /// changes tone with the colour scheme stops reading as "the white side".
  public var whiteBody: DualColor
  /// Fill for black pieces.
  public var blackBody: DualColor
  /// Outline stroke width as a fraction of the square edge. The outline is what
  /// keeps a white piece legible on a light square without a drop shadow.
  public var outlineWidth: CGFloat

  public init(
    name: String,
    source: Source,
    whiteBody: DualColor = DualColor(light: 0xFAFAF7, dark: 0xF2F1ED),
    blackBody: DualColor = DualColor(light: 0x2B2D31, dark: 0x191A1D),
    outlineWidth: CGFloat = 0.022
  ) {
    self.name = name
    self.source = source
    self.whiteBody = whiteBody
    self.blackBody = blackBody
    self.outlineWidth = outlineWidth
  }

  /// Built-in vector set.
  public static let vector = PieceRenderer(name: "Vector", source: .vector)

  /// System glyph set.
  public static let unicode = PieceRenderer(name: "Unicode", source: .unicode)

  /// An image-backed set. Falls back to vectors for any missing asset.
  public static func images(
    named name: String,
    prefix: String,
    bundleIdentifier: String? = nil
  ) -> PieceRenderer {
    PieceRenderer(
      name: name,
      source: .images(bundleIdentifier: bundleIdentifier, prefix: prefix)
    )
  }

  /// Body fill for a piece colour.
  public func body(for color: Piece.Color) -> DualColor {
    color == .white ? whiteBody : blackBody
  }

  /// Outline colour for a piece colour — always the opposing body tone, so the
  /// silhouette survives on either square tone.
  ///
  /// The outline is doing real work, not decoration: a white piece is only
  /// about 1.2:1 against a light square, and the dark edge around it is the
  /// entire reason the shape is visible at all. So at increased contrast the
  /// transparency comes off — the reader who asked for more separation is
  /// exactly the reader relying on that edge.
  public func outline(for color: Piece.Color, contrast: ColorSchemeContrast = .standard) -> DualColor {
    let base = color == .white ? blackBody : whiteBody
    guard contrast != .increased else { return base }
    return base.opacity(color == .white ? 0.55 : 0.52)
  }

  /// Outline stroke width in points for a piece drawn at `size`.
  ///
  /// Doubled at increased contrast: colour alone cannot rescue a hairline.
  public func outlineWidth(for size: CGFloat, contrast: ColorSchemeContrast = .standard) -> CGFloat {
    max(0.5, size * outlineWidth * (contrast == .increased ? 2 : 1))
  }

  /// The asset name an image-backed set would look for.
  func assetName(for kind: Piece.Kind, color: Piece.Color) -> String? {
    guard case let .images(_, prefix) = source else { return nil }
    return prefix + color.rawValue + kindLetter(kind)
  }

  func bundle() -> Bundle? {
    guard case let .images(identifier, _) = source else { return nil }
    guard let identifier else { return .main }
    return Bundle(identifier: identifier)
  }

  private func kindLetter(_ kind: Piece.Kind) -> String {
    switch kind {
    case .pawn: "P"
    case .knight: "N"
    case .bishop: "B"
    case .rook: "R"
    case .queen: "Q"
    case .king: "K"
    }
  }
}

// MARK: - Piece view

/// Draws one piece at a given size.
public struct PieceView: View {

  private let kind: Piece.Kind
  private let color: Piece.Color
  private let renderer: PieceRenderer
  private let size: CGFloat

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  public init(
    kind: Piece.Kind,
    color: Piece.Color,
    renderer: PieceRenderer = .vector,
    size: CGFloat
  ) {
    self.kind = kind
    self.color = color
    self.renderer = renderer
    self.size = size
  }

  public init(piece: Piece, renderer: PieceRenderer = .vector, size: CGFloat) {
    self.init(kind: piece.kind, color: piece.color, renderer: renderer, size: size)
  }

  public var body: some View {
    content
      .frame(width: size, height: size)
      .accessibilityLabel(Text("\(color.description) \(kind.description)"))
  }

  @ViewBuilder
  private var content: some View {
    switch renderer.source {
    case .vector:
      vector
    case .unicode:
      glyph
    case .images:
      if let name = renderer.assetName(for: kind, color: color),
        let bundle = renderer.bundle(),
        // `Image(_:bundle:)` renders a placeholder rather than failing when the
        // asset is absent, so existence is checked before committing to it.
        AssetProbe.exists(name: name, in: bundle)
      {
        Image(name, bundle: bundle)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        vector
      }
    }
  }

  private var vector: some View {
    // The piece is inset inside its square: a piece that touches the square
    // edges makes a dense middlegame look like a solid block of pieces.
    let inset = size * 0.06
    let body = renderer.body(for: color).color(colorScheme)
    let outline = renderer.outline(for: color, contrast: contrast).color(colorScheme)

    return ZStack {
      PieceShape(kind: kind)
        .fill(body)
        .overlay {
          PieceShape(kind: kind)
            .stroke(outline, lineWidth: renderer.outlineWidth(for: size, contrast: contrast))
        }
      PieceDetailShape(kind: kind)
        .fill(outline)
    }
    .padding(inset)
    .compositingGroup()
    .shadow(color: .black.opacity(0.28), radius: size * 0.02, x: 0, y: size * 0.012)
  }

  private var glyph: some View {
    // The solid glyphs are used for both colours — the outline glyphs (♔♕♖)
    // render inconsistently across system fonts and vanish on light squares.
    Text(solidGlyph)
      .font(.system(size: size * 0.82))
      .foregroundStyle(renderer.body(for: color).color(colorScheme))
      .shadow(color: renderer.outline(for: color, contrast: contrast).color(colorScheme), radius: 0.5)
      .minimumScaleFactor(0.5)
  }

  private var solidGlyph: String {
    switch kind {
    case .pawn: "\u{265F}\u{FE0E}"
    case .knight: "\u{265E}"
    case .bishop: "\u{265D}"
    case .rook: "\u{265C}"
    case .queen: "\u{265B}"
    case .king: "\u{265A}"
    }
  }
}

/// Platform-agnostic "does this asset exist" check for image-backed piece sets.
enum AssetProbe {
  static func exists(name: String, in bundle: Bundle) -> Bool {
    #if canImport(UIKit)
      return UIImage(named: name, in: bundle, compatibleWith: nil) != nil
    #elseif canImport(AppKit)
      return bundle.image(forResource: name) != nil
    #else
      return false
    #endif
  }
}

// MARK: - Previews

#Preview("Piece set — vector") {
  let kinds: [Piece.Kind] = [.king, .queen, .rook, .bishop, .knight, .pawn]
  return VStack(spacing: 0) {
    ForEach([Piece.Color.white, .black], id: \.self) { color in
      HStack(spacing: 0) {
        ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
          PieceView(kind: kind, color: color, size: 72)
            .background(
              (index + (color == .white ? 0 : 1)).isMultiple(of: 2)
                ? BoardStyle.default.lightSquare.dark
                : BoardStyle.default.darkSquare.dark
            )
        }
      }
    }
  }
  .padding()
  .background(Color.black)
}

#Preview("Piece set — unicode") {
  let kinds: [Piece.Kind] = [.king, .queen, .rook, .bishop, .knight, .pawn]
  return VStack(spacing: 0) {
    ForEach([Piece.Color.white, .black], id: \.self) { color in
      HStack(spacing: 0) {
        ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
          PieceView(kind: kind, color: color, renderer: .unicode, size: 72)
        }
      }
    }
  }
  .padding()
}
