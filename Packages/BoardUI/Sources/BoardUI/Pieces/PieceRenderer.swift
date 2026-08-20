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
/// The ``vector`` set needs no bundled assets, which lets the
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
    /// Artwork shipped inside this package's own resource bundle.
    ///
    /// Separate from `images` because that case resolves `nil` to the *main*
    /// bundle — correct for a set the host app supplies, wrong for one that
    /// travels with BoardUI.
    case bundledImages(prefix: String)
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

  /// Clay — the default set: soft, uneven toy pieces with a pale blue edge.
  ///
  /// The artwork carries its own fills, outlines and shading, so the
  /// body/outline colours are unused for this set.
  public static let clay = PieceRenderer(
    name: "Clay",
    source: .bundledImages(prefix: "clay-")
  )

  /// Staunty — the previous default, bundled with this package.
  ///
  /// Chunky, soft-edged and subtly shaded, which is what makes it survive at
  /// phone size: at a 45pt square, thin classic line art loses its outline to
  /// the pixel grid and the pieces flatten into symbols. Staunty's weight is
  /// also what lets the board underneath go as quiet as it does — low-contrast
  /// board, high-contrast pieces only works if the pieces hold up their end.
  ///
  /// The artwork carries its own fills, outlines and shading, so the
  /// body/outline colours below are unused for this set.
  public static let staunty = PieceRenderer(
    name: "Staunty",
    source: .bundledImages(prefix: "staunty-")
  )

  /// Cburnett — the Lichess default, also bundled.
  ///
  /// Kept as the traditional alternative for players who read positions faster
  /// in the set they have used for twenty years, which is a real thing and not
  /// worth arguing with.
  public static let cburnett = PieceRenderer(
    name: "Cburnett",
    source: .bundledImages(prefix: "cburnett-")
  )

  /// Built-in vector set. Kept as the fallback for any missing asset.
  public static let vector = PieceRenderer(name: "Vector", source: .vector)

  /// System glyph set.
  public static let unicode = PieceRenderer(name: "Unicode", source: .unicode)

  /// Every set that ships with the package, in presentation order.
  ///
  /// The three bundled artwork sets come first. The vector and glyph fallbacks are
  /// listed after them because they exist for previews and thumbnails, not as
  /// something anyone would choose.
  public static let builtIn: [PieceRenderer] = [.clay, .staunty, .cburnett, .vector, .unicode]

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
    switch source {
    case let .images(_, prefix), let .bundledImages(prefix):
      return prefix + color.rawValue + kindLetter(kind)
    case .vector, .unicode:
      return nil
    }
  }

  func bundle() -> Bundle? {
    switch source {
    case let .images(identifier, _):
      guard let identifier else { return .main }
      return Bundle(identifier: identifier)
    case .bundledImages:
      return .module
    case .vector, .unicode:
      return nil
    }
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
    renderer: PieceRenderer = .clay,
    size: CGFloat
  ) {
    self.kind = kind
    self.color = color
    self.renderer = renderer
    self.size = size
  }

  public init(piece: Piece, renderer: PieceRenderer = .clay, size: CGFloat) {
    self.init(kind: piece.kind, color: piece.color, renderer: renderer, size: size)
  }

  public var body: some View {
    content
      // Every set is inset to the same fraction of the square, whatever it
      // draws inside that box. A piece that touches the square edges makes a
      // dense middlegame read as one solid block and leaves a capture ring
      // nowhere to go.
      .padding(BoardMetrics.pieceInset(squareSide: size))
      .frame(width: size, height: size)
      // The toy assets contain their own contact shadows. Other sets need this
      // small shadow to stay separate from pale squares.
      .compositingGroup()
      .shadow(
        color: .black.opacity(usesEmbeddedDepth ? 0 : 0.20),
        radius: size * 0.022,
        x: 0,
        y: size * 0.018
      )
      .accessibilityLabel(Text("\(color.description) \(kind.description)"))
  }

  private var usesEmbeddedDepth: Bool {
    guard case let .bundledImages(prefix) = renderer.source else { return false }
    return prefix == "clay-"
  }

  @ViewBuilder
  private var content: some View {
    switch renderer.source {
    case .vector:
      vector
    case .unicode:
      glyph
    case .images, .bundledImages:
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
  }

  private var glyph: some View {
    // The solid glyphs are used for both colours — the outline glyphs (♔♕♖)
    // render inconsistently across system fonts and vanish on light squares.
    Text(solidGlyph)
      .font(.system(size: size * 0.92))
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

#Preview("Piece set — clay") {
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
