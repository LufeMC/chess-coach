//
//  BoardStyle.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Everything about how a board looks but nothing about what it contains.
///
/// ## Low-contrast board, high-contrast pieces
///
/// That is the governing rule for everything in this file. **A board you notice
/// is a board competing with the game.** The squares are there to locate the
/// pieces, not to be looked at, so they recede almost to the page: the light
/// square is nearly the background, the dark square is only just
/// distinguishable from it, and every scrap of contrast on the surface is spent
/// on the pieces and on the overlays that explain them.
///
/// The built-in themes sit ~7 L\* apart in the light appearance. At a glance
/// the checker barely reads — which is the point. It also buys a great deal of
/// headroom: a 14%-alpha last-move wash and a 22%-alpha hint dot are both
/// clearly visible on a board this quiet, and neither would be on the
/// high-contrast brown/cream board that is the single most reliable tell of a
/// chess app designed in 2004.
///
/// ## Dark mode is a separate design
///
/// The dark values are *not* inversions. Cells land around L\* 33/30 — a
/// smaller delta still, because on a dark ground the eye separates tones more
/// readily — and comfortably lighter than any dark page background, so the
/// board reads as raised by lightness rather than by a shadow that would be
/// invisible anyway.
///
/// They stop there rather than going darker for one concrete reason: the
/// bundled cburnett black pieces are filled pure black. Every L\* the squares
/// lose comes straight off the black king's silhouette, and a board where the
/// black pieces are a slightly different black is unusable long before it is
/// tasteful.
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

  /// The warm yellow the last move is washed in.
  ///
  /// Its own token rather than the accent: the accent means "you are doing
  /// this", and the last move is the one thing on the board the user did *not*
  /// just do. Drawn at 14% so it stays plainly weaker than the 28% selection —
  /// get that ladder the wrong way round and the board reads as noise.
  public var lastMove: DualColor
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

  /// Whether a capture announces what it was worth.
  ///
  /// Rings radiating from the square plus the signed material delta floating
  /// above it. On by default because teaching evaluation on every capture is
  /// worth more to a training app than to anyone else, and off-switchable
  /// because a review scrubber and a 150pt thumbnail want a still board. The
  /// board additionally suppresses it whenever the user is not the one playing
  /// the moves — see ``BoardView``.
  public var showsMaterialFeedback: Bool

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
    lastMove: DualColor = DualColor(light: 0xE0A02A, dark: 0xF2C464),
    showsCoordinates: Bool = false,
    showsMaterialFeedback: Bool = true,
    cornerRadius: CGFloat = 0,
    pieceSet: PieceRenderer = .staunty
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
    self.lastMove = lastMove
    self.showsCoordinates = showsCoordinates
    self.showsMaterialFeedback = showsMaterialFeedback
    self.cornerRadius = cornerRadius
    self.pieceSet = pieceSet
  }

  /// The tone for a square, based on its board colour.
  public func squareColor(for squareColor: Square.Color) -> DualColor {
    squareColor == .light ? lightSquare : darkSquare
  }

  /// The tone of the *other* square colour — what a coordinate glyph is drawn
  /// in so it always sits on its own square's opposite.
  public func opposingSquareColor(for squareColor: Square.Color) -> DualColor {
    squareColor == .light ? darkSquare : lightSquare
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

  /// The coordinate tone for a glyph sitting on a square of a given colour.
  ///
  /// Normally the *opposing* square's tone at 40%: on a board this quiet, a
  /// label drawn in the other square's colour is exactly as loud as the checker
  /// pattern itself and no louder, which is the only weight a coordinate should
  /// ever carry. It also means the labels retune themselves for free whenever
  /// the squares do.
  ///
  /// "Increase Contrast" is a request to stop being quiet, so that reader gets
  /// the flat near-black/near-white instead — no opacity, no borrowing.
  public func coordinateColor(
    on squareColor: Square.Color,
    contrast: ColorSchemeContrast
  ) -> DualColor {
    guard contrast != .increased else { return coordinateColor(contrast) }
    return opposingSquareColor(for: squareColor).opacity(BoardMetrics.coordinateOpacity)
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

  /// Returns a copy with the capture material-delta flourish switched on or off.
  public func showingMaterialFeedback(_ shown: Bool = true) -> BoardStyle {
    var copy = self
    copy.showsMaterialFeedback = shown
    return copy
  }
}

// MARK: - Built-in themes

extension BoardStyle {

  /// The default theme: warm-neutral, all but weightless.
  ///
  /// Light appearance L\* 98.2 / 91.4 — a 6.8 delta. Dark appearance
  /// L\* 33.0 / 30.0 — 3.0, and both cells far lighter than any dark page
  /// ground, so the board is raised by lightness rather than by a shadow.
  ///
  /// The light square sits *above* the piece art's white body (L\* 94.8) and
  /// the dark square below it, so a white piece separates from both tones by
  /// three or four L\* before its outline does any work at all.
  public static let slate = BoardStyle(
    name: "Slate",
    lightSquare: DualColor(light: 0xFAFAF8, dark: 0x4A4E54),
    darkSquare: DualColor(light: 0xE9E6E0, dark: 0x43474D),
    accent: DualColor(light: 0x2F7E7B, dark: 0x4FB3AF),
    caution: DualColor(light: 0xC8871F, dark: 0xF0B74E),
    warning: DualColor(light: 0xD1662A, dark: 0xF09244),
    danger: DualColor(light: 0xC23B30, dark: 0xEE6152),
    success: DualColor(light: 0x2F8558, dark: 0x58C286),
    coordinate: DualColor(light: 0x6E6C68, dark: 0x9A9EA6)
  )

  /// A cooler, bluer variant of the same relationships.
  ///
  /// Light L\* 98.2 / 91.1, dark L\* 33.0 / 30.0.
  public static let ink = BoardStyle(
    name: "Ink",
    lightSquare: DualColor(light: 0xF8FAFC, dark: 0x474E5B),
    darkSquare: DualColor(light: 0xE1E6EC, dark: 0x414752),
    accent: DualColor(light: 0x3A6EA5, dark: 0x6FA5DC),
    caution: DualColor(light: 0xC8871F, dark: 0xF0B74E),
    warning: DualColor(light: 0xD1662A, dark: 0xF09244),
    danger: DualColor(light: 0xC23B30, dark: 0xEE6152),
    success: DualColor(light: 0x2F8558, dark: 0x58C286),
    coordinate: DualColor(light: 0x687484, dark: 0x93A0B2),
    lastMove: DualColor(light: 0xDDA02F, dark: 0xF0C46A)
  )

  /// A warmer paper variant for readers who dislike cool greys.
  ///
  /// Light L\* 98.3 / 91.2, dark L\* 33.0 / 30.0.
  public static let paper = BoardStyle(
    name: "Paper",
    lightSquare: DualColor(light: 0xFCFAF4, dark: 0x524D45),
    darkSquare: DualColor(light: 0xECE5D9, dark: 0x4B463E),
    accent: DualColor(light: 0x2F7E7B, dark: 0x4FB3AF),
    caution: DualColor(light: 0xC8871F, dark: 0xF0B74E),
    warning: DualColor(light: 0xD1662A, dark: 0xF09244),
    danger: DualColor(light: 0xC23B30, dark: 0xEE6152),
    success: DualColor(light: 0x2F8558, dark: 0x58C286),
    coordinate: DualColor(light: 0x776F62, dark: 0xA69C8C),
    // A touch redder on paper, where a pure yellow wash goes muddy against the
    // warm square underneath it.
    lastMove: DualColor(light: 0xD98E27, dark: 0xEFBB5F)
  )

  /// The theme used when a caller does not specify one.
  public static let `default` = BoardStyle.slate

  /// Every built-in theme, in presentation order.
  public static let builtIn: [BoardStyle] = [.slate, .ink, .paper]
}
