//
//  BoardMetrics.swift
//  BoardUI
//

import ChessKit
import CoreGraphics

/// Every number the board's overlays are drawn from, in one place.
///
/// Two reasons this is a type rather than a scattering of literals:
///
/// 1. **It is testable.** Dot diameters, ring insets, the drag lift and the
///    deselection stagger are all pure arithmetic, and they are exactly the
///    things that silently drift when a view file is edited in a hurry.
/// 2. **It keeps the ratios honest.** A legal-move dot and a capture ring have
///    to agree with each other and with the piece inset, or a dense middlegame
///    turns into a smear. Reading them next to each other makes a bad ratio
///    obvious before it ships.
///
/// Fractions are of the *square edge* unless a name says otherwise, so the
/// board looks identical at thumbnail and full-screen sizes.
public enum BoardMetrics {

  // MARK: - Pieces

  /// Piece width as a fraction of the square.
  ///
  /// A full-bleed piece makes a dense middlegame read as one solid block and
  /// makes captures illegible — the ring around a captured piece has nowhere to
  /// go. Everything between 0.82 and 0.88 works; 0.85 leaves room for the
  /// capture ring without making the pieces look lost in their squares.
  public static let pieceScale: CGFloat = 0.85

  /// The padding that insets a piece to ``pieceScale`` inside its square.
  public static func pieceInset(squareSide: CGFloat) -> CGFloat {
    max(0, squareSide * (1 - pieceScale) / 2)
  }

  // MARK: - Overlay opacities
  //
  // The ladder these form is the whole readability story of the board:
  // selection must beat last-move, and last-move must be quiet enough that a
  // board covered in it still reads as a position rather than as noise.

  /// Selection fill — a whole-square wash, never a ring.
  public static let selectionFill: Double = 0.28

  /// Last-move fill, on both the from- and to-square.
  public static let lastMoveFill: Double = 0.14

  /// Legal-move dots and capture rings.
  public static let moveHint: Double = 0.22

  /// Legal-move dots and capture rings for a reader who asked for more contrast.
  public static let moveHintIncreasedContrast: Double = 0.42

  /// The piece left behind on the origin square during a drag.
  public static let dragGhost: Double = 0.25

  /// Opacity ladder for a move hint at the reader's contrast setting.
  public static func moveHintOpacity(increasedContrast: Bool) -> Double {
    increasedContrast ? moveHintIncreasedContrast : moveHint
  }

  // MARK: - Legal moves

  /// Diameter of the dot on an empty legal square.
  public static func legalMoveDotDiameter(squareSide: CGFloat) -> CGFloat {
    squareSide * 0.22
  }

  /// A stroked circle expressed the way SwiftUI needs it.
  public struct Ring: Equatable, Sendable {
    /// Inset from the square edge to the ring's outer edge.
    public var inset: CGFloat
    /// Stroke width.
    public var lineWidth: CGFloat
    /// Outer diameter of the ring.
    public var outerDiameter: CGFloat
    /// Diameter of the hole the ring frames.
    public var innerDiameter: CGFloat
  }

  /// The ring that frames a piece standing on a legal destination.
  ///
  /// Inset from the square edge and stroked at a tenth of it, so the ring
  /// *frames* the piece rather than covering it. With pieces at
  /// ``pieceScale`` the hole is wide enough that the artwork still reads.
  public static func legalCaptureRing(
    squareSide: CGFloat,
    increasedContrast: Bool = false
  ) -> Ring {
    let inset = squareSide * 0.06
    let lineWidth = squareSide * (increasedContrast ? 0.13 : 0.10)
    let outer = max(0, squareSide - inset * 2)
    return Ring(
      inset: inset,
      lineWidth: lineWidth,
      outerDiameter: outer,
      innerDiameter: max(0, outer - lineWidth * 2)
    )
  }

  /// The ring drawn on the square a dragged piece would land on.
  ///
  /// A ring and not a fill: a wash under a piece lifted 24pt above the board is
  /// simply invisible, which is the whole reason hover feedback so often looks
  /// broken on touch.
  public static func dropTargetRing(squareSide: CGFloat) -> Ring {
    let inset = squareSide * 0.05
    let lineWidth = squareSide * 0.055
    let outer = max(0, squareSide - inset * 2)
    return Ring(
      inset: inset,
      lineWidth: lineWidth,
      outerDiameter: outer,
      innerDiameter: max(0, outer - lineWidth * 2)
    )
  }

  // MARK: - Check

  /// Outer radius of the glow behind a checked king.
  ///
  /// Past the square's edges so the falloff runs off them rather than ending in
  /// a visible circle drawn inside the square, and short of the half-diagonal
  /// (0.707) so it does not wash into the diagonal neighbours.
  public static func checkGlowRadius(squareSide: CGFloat) -> CGFloat {
    squareSide * 0.62
  }

  /// The bloom the glow starts at before easing down to rest. One pulse, never
  /// a loop — a repeating animation during thinking time is exhausting.
  public static let checkGlowBloomScale: CGFloat = 1.18
  /// The intensity the glow holds at while check persists.
  public static let checkGlowRestOpacity: Double = 0.62
  /// Duration of the single pulse.
  public static let checkPulseDuration: Double = 0.4

  // MARK: - Capture

  /// How long a captured piece takes to scale down and fade out.
  public static let captureFadeDuration: Double = 0.18
  /// The scale a captured piece shrinks to as it goes.
  public static let captureFadeScale: CGFloat = 0.6
  /// A beat before the fade starts, so the capturing piece is already arriving
  /// and the square is never seen empty.
  public static let captureFadeDelay: Double = 0.06

  /// How long the material-delta rings and their number stay on screen.
  public static let captureFlourishDuration: Double = 0.62
  /// Number of concentric rings in the material-delta flourish.
  public static let captureFlourishRings = 3

  /// Scale the `n`th flourish ring expands to. Rings pass through each other's
  /// spacing, which is what makes them read as radiating rather than as one
  /// thick ring.
  public static func captureFlourishScale(ring: Int) -> CGFloat {
    1.0 + 0.42 * CGFloat(ring + 1)
  }

  /// Start delay of the `n`th flourish ring.
  public static func captureFlourishDelay(ring: Int) -> Double {
    Double(ring) * 0.07
  }

  // MARK: - Drag

  /// The square size the absolute point values below were chosen against.
  ///
  /// A phone board is 8 squares across a ~360pt content width. Shadows and the
  /// finger offset are specified in points because they are about a fingertip
  /// and a light source, not about the board; they are scaled from this
  /// reference so an iPad board does not end up with a pinhole shadow.
  public static let referenceSquareSide: CGFloat = 45

  /// A lifted piece grows by this much. The one place on the board where
  /// something is genuinely above the surface.
  public static let dragLiftScale: CGFloat = 1.15

  /// How far up the dragged piece is drawn from the touch point.
  ///
  /// The *drop target stays under the finger* — only the drawing moves. That is
  /// the point: the square you are aiming at is the one you can see, instead of
  /// the one under your thumb.
  ///
  /// Clamped against the square so a thumbnail-sized board does not fling the
  /// piece two ranks clear of the finger.
  public static func fingerOffset(squareSide: CGFloat) -> CGFloat {
    min(24, squareSide * 0.55)
  }

  /// How long a refused piece takes to fly home.
  ///
  /// Matched to `.boardGentle`: at response 0.60 and 0.90 damping the piece is
  /// within 2% of its square after this long. Cutting it shorter hands the
  /// piece back to the grid mid-flight and it visibly jumps the last of the
  /// way, which is the one thing a snap-back must not do.
  public static let snapBackFlight: Double = 0.42

  /// Drop shadow for a lifted piece: `radius 12, y 6, opacity 0.25` at the
  /// reference square size, scaled from there.
  public static func dragShadow(squareSide: CGFloat) -> (radius: CGFloat, offsetY: CGFloat, opacity: Double) {
    let scale = max(0, squareSide) / referenceSquareSide
    return (radius: 12 * scale, offsetY: 6 * scale, opacity: 0.25)
  }

  /// Everything the drag layer needs to draw one lifted piece.
  ///
  /// Pure so the three states a drag passes through — pressed but not
  /// travelling, travelling, returning after a refusal — can be checked without
  /// a rendered board. The bug this exists to prevent is the piece jumping to
  /// the touch point on touch-down: a press near a square's edge would visibly
  /// yank the piece sideways before the drag had even started.
  public struct DragPresentation: Equatable, Sendable {
    /// Where to draw the piece, in board space.
    public var position: CGPoint
    public var scale: CGFloat
    public var shadowRadius: CGFloat
    public var shadowOffsetY: CGFloat
    public var shadowOpacity: Double
    /// Opacity of the piece left behind on the origin square.
    public var ghostOpacity: Double
  }

  /// Resolves how a dragged piece is drawn.
  ///
  /// - Parameters:
  ///   - originCenter: centre of the square the piece was picked up from.
  ///   - touch: the current pointer location in board space.
  ///   - isActive: whether the pointer has travelled past the drag threshold.
  ///   - isReturning: whether the piece is flying home after a refusal.
  ///   - liftsAboveFinger: false for a pointer, which occludes nothing.
  public static func dragPresentation(
    squareSide: CGFloat,
    originCenter: CGPoint,
    touch: CGPoint,
    isActive: Bool,
    isReturning: Bool,
    liftsAboveFinger: Bool = true
  ) -> DragPresentation {
    let shadow = dragShadow(squareSide: squareSide)

    // Home again: the piece lands flat, and no ghost — a ghost under a piece
    // that is arriving on the same square just looks like a rendering fault.
    guard !isReturning else {
      return DragPresentation(
        position: originCenter,
        scale: 1,
        shadowRadius: 0,
        shadowOffsetY: 0,
        shadowOpacity: 0,
        ghostOpacity: 0
      )
    }

    // Pressed but not travelling: the piece stays centred in its square and
    // only lifts. It has not gone anywhere, so it must not look as though it
    // has.
    guard isActive else {
      return DragPresentation(
        position: originCenter,
        scale: dragLiftScale,
        shadowRadius: shadow.radius,
        shadowOffsetY: shadow.offsetY,
        shadowOpacity: shadow.opacity,
        ghostOpacity: 0
      )
    }

    let offset = liftsAboveFinger ? fingerOffset(squareSide: squareSide) : 0
    return DragPresentation(
      position: CGPoint(x: touch.x, y: touch.y - offset),
      scale: dragLiftScale,
      shadowRadius: shadow.radius,
      shadowOffsetY: shadow.offsetY,
      shadowOpacity: shadow.opacity,
      ghostOpacity: dragGhost
    )
  }

  // MARK: - Deselection stagger

  /// Gap between successive rings of legal-move dots as they leave.
  public static let staggerStep: Double = 0.020

  /// How long a dot takes to fade once its turn comes.
  public static let staggerFade: Double = 0.12

  /// Delay before the mark on `square` leaves, radiating out from `origin`.
  ///
  /// Selection feedback is instantaneous — dots appear on touch-down with no
  /// animation at all — so this only ever applies to *removal*. The 20ms
  /// spacing is small enough that it never reads as waiting and large enough
  /// that the wipe is visible; it is the difference between the dots
  /// disappearing and the selection being put down.
  ///
  /// Distance is king-move distance, which is the metric a chess board actually
  /// radiates in: every square a knight can reach is one ring out, so all eight
  /// of its dots leave together, which is correct — they are equidistant.
  public static func staggerDelay(
    from origin: Square?,
    to square: Square,
    step: Double = staggerStep
  ) -> Double {
    guard let origin, origin != square else { return 0 }
    return Double(Square.distance(origin, square) - 1) * step
  }

  // MARK: - Coordinates

  /// Point size for a coordinate glyph inside an edge square.
  ///
  /// Targets ~9pt on a phone-sized board. Clamped at the top so the largest
  /// Dynamic Type settings enlarge the labels without a glyph swallowing its
  /// square, and at the bottom so a thumbnail's labels stay legible rather than
  /// becoming grey lint.
  public static func coordinateFontSize(squareSide: CGFloat, typeScale: CGFloat = 1) -> CGFloat {
    min(squareSide * 0.30, max(7, squareSide * 0.20 * typeScale))
  }

  /// Opacity of a coordinate glyph drawn in the opposing square's tone.
  public static let coordinateOpacity: Double = 0.40
}
