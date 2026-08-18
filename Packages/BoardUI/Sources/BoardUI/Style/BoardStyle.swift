//
//  BoardStyle.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Everything about how a board looks but nothing about what it contains.
///
/// The square tones are deliberately near-neutral and only about 8 L\* apart.
/// A saturated green/buff board eats every overlay drawn on top of it, and this
/// app draws a lot of overlays — highlights, hint rings, arrows, eval-delta
/// pulses. Low square contrast is what buys that headroom.
public struct BoardStyle: Hashable, Sendable, Identifiable {

  public var id: String { name }

  /// Human-readable theme name, shown in settings.
  public var name: String

  /// The lighter of the two square tones.
  public var lightSquare: DualColor
  /// The darker of the two square tones.
  public var darkSquare: DualColor

  /// The single interactive/brand colour. Never green — green is reserved for
  /// "good move" semantics and would collide.
  public var accent: DualColor
  /// Amber, used for inaccuracies and hints.
  public var caution: DualColor
  /// Orange, used for mistakes.
  public var warning: DualColor
  /// Red, used for blunders, threats and check.
  public var danger: DualColor
  /// A desaturated green used *only* for the "this was the answer" state, where
  /// the brief calls for a dashed green target square.
  public var success: DualColor

  /// Colour of the coordinate glyphs when they are shown.
  public var coordinate: DualColor

  /// Whether file/rank labels are drawn. Off by default per the brief.
  public var showsCoordinates: Bool

  /// Corner rounding of the board. Zero by default — the board runs
  /// edge-to-edge with no border.
  public var cornerRadius: CGFloat

  /// Which piece artwork to draw.
  public var pieceSet: PieceRenderer

  public init(
    name: String,
    lightSquare: DualColor,
    darkSquare: DualColor,
    accent: DualColor,
    caution: DualColor,
    warning: DualColor,
    danger: DualColor,
    success: DualColor,
    coordinate: DualColor,
    showsCoordinates: Bool = false,
    cornerRadius: CGFloat = 0,
    pieceSet: PieceRenderer = .cburnett
  ) {
    self.name = name
    self.lightSquare = lightSquare
    self.darkSquare = darkSquare
    self.accent = accent
    self.caution = caution
    self.warning = warning
    self.danger = danger
    self.success = success
    self.coordinate = coordinate
    self.showsCoordinates = showsCoordinates
    self.cornerRadius = cornerRadius
    self.pieceSet = pieceSet
  }

  /// The tone for a square, based on its board colour.
  public func squareColor(for squareColor: Square.Color) -> DualColor {
    squareColor == .light ? lightSquare : darkSquare
  }

  /// The coordinate tone, honouring the reader's contrast preference.
  ///
  /// The palette's coordinate grey is deliberately quiet so file and rank
  /// labels never compete with the position. "Increase Contrast" is a request
  /// to stop being quiet, so the glyphs go to the extreme of the current
  /// appearance instead — near-black on the light squares, near-white on the
  /// dark ones, which clears 7:1 against every built-in square tone.
  public func coordinateColor(_ contrast: ColorSchemeContrast) -> DualColor {
    contrast == .increased ? DualColor(light: 0x1C1B19, dark: 0xF4F3F0) : coordinate
  }

  /// Returns a copy with coordinates turned on.
  public func showingCoordinates(_ shown: Bool = true) -> BoardStyle {
    var copy = self
    copy.showsCoordinates = shown
    return copy
  }

  /// Returns a copy using a different piece set.
  public func usingPieceSet(_ renderer: PieceRenderer) -> BoardStyle {
    var copy = self
    copy.pieceSet = renderer
    return copy
  }
}

// MARK: - Built-in themes

extension BoardStyle {

  /// The default theme: warm-neutral greys, tuned dark-first.
  public static let slate = BoardStyle(
    name: "Slate",
    // Light appearance ≈ L* 90 / 82, dark appearance ≈ L* 32 / 25.
    lightSquare: DualColor(light: 0xE3E1DD, dark: 0x4A4E55),
    darkSquare: DualColor(light: 0xCBC9C5, dark: 0x383B41),
    accent: DualColor(light: 0x2F7E7B, dark: 0x4FB3AF),
    caution: DualColor(light: 0xC8871F, dark: 0xF0B74E),
    warning: DualColor(light: 0xD1662A, dark: 0xF09244),
    danger: DualColor(light: 0xC23B30, dark: 0xEE6152),
    success: DualColor(light: 0x2F8558, dark: 0x58C286),
    coordinate: DualColor(light: 0x6E6C68, dark: 0x9A9EA6)
  )

  /// A cooler, bluer variant of the same relationships.
  public static let ink = BoardStyle(
    name: "Ink",
    lightSquare: DualColor(light: 0xDFE3E8, dark: 0x444B57),
    darkSquare: DualColor(light: 0xC5CBD4, dark: 0x333944),
    accent: DualColor(light: 0x3A6EA5, dark: 0x6FA5DC),
    caution: DualColor(light: 0xC8871F, dark: 0xF0B74E),
    warning: DualColor(light: 0xD1662A, dark: 0xF09244),
    danger: DualColor(light: 0xC23B30, dark: 0xEE6152),
    success: DualColor(light: 0x2F8558, dark: 0x58C286),
    coordinate: DualColor(light: 0x687484, dark: 0x93A0B2)
  )

  /// A warmer paper variant for readers who dislike cool greys.
  public static let paper = BoardStyle(
    name: "Paper",
    lightSquare: DualColor(light: 0xE8E2D8, dark: 0x4E4941),
    darkSquare: DualColor(light: 0xD0C9BD, dark: 0x3C382F),
    accent: DualColor(light: 0x2F7E7B, dark: 0x4FB3AF),
    caution: DualColor(light: 0xC8871F, dark: 0xF0B74E),
    warning: DualColor(light: 0xD1662A, dark: 0xF09244),
    danger: DualColor(light: 0xC23B30, dark: 0xEE6152),
    success: DualColor(light: 0x2F8558, dark: 0x58C286),
    coordinate: DualColor(light: 0x776F62, dark: 0xA69C8C)
  )

  /// The theme used when a caller does not specify one.
  public static let `default` = BoardStyle.slate

  /// Every built-in theme, in presentation order.
  public static let builtIn: [BoardStyle] = [.slate, .ink, .paper]
}
