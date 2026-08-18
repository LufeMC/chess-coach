//
//  ArrowGeometry.swift
//  BoardUI
//

import ChessKit
import CoreGraphics

/// The resolved point set for one board arrow.
///
/// Kept separate from the drawing code so the shape can be asserted in tests —
/// arrows are easy to get subtly wrong (heads that drift off the shaft, arrows
/// that cover the piece they start from) and impossible to regression-test once
/// they only exist as a `Path`.
public struct ArrowGeometry: Equatable, Sendable {

  /// Where the shaft begins — inset from the source square's centre so the
  /// piece being recommended stays visible underneath.
  public var start: CGPoint
  /// Quadratic control point for the shaft.
  public var control: CGPoint
  /// Where the shaft stops and the head begins.
  public var shaftEnd: CGPoint
  /// The point of the arrow head.
  public var tip: CGPoint
  /// Left corner of the head, looking along the arrow.
  public var headLeft: CGPoint
  /// Right corner of the head, looking along the arrow.
  public var headRight: CGPoint
  /// Stroke width of the shaft.
  public var shaftWidth: CGFloat
  /// Whether the shaft bows — true only for knight moves.
  public var isCurved: Bool

  /// Proportions of an arrow, expressed as fractions of one square's edge.
  public struct Metrics: Equatable, Sendable {
    public var shaftWidth: CGFloat = 0.14
    /// Distance from the source centre to the start of the shaft.
    public var sourceInset: CGFloat = 0.30
    /// Distance from the destination centre back to the tip.
    public var targetInset: CGFloat = 0.08
    public var headLength: CGFloat = 0.36
    public var headHalfWidth: CGFloat = 0.25
    /// Perpendicular bow applied to knight arrows.
    public var knightCurvature: CGFloat = 0.55

    public init() {}
  }

  /// Builds the geometry for an arrow between two squares.
  ///
  /// Returns `nil` for a zero-length arrow (same square, or a degenerate board),
  /// which has no meaningful direction.
  public static func make(
    from: Square,
    to: Square,
    in geometry: BoardGeometry,
    metrics: Metrics = Metrics()
  ) -> ArrowGeometry? {
    let squareSide = geometry.squareSide
    guard squareSide > 0, from != to else { return nil }

    let a = geometry.center(of: from)
    let b = geometry.center(of: to)
    let dx = b.x - a.x
    let dy = b.y - a.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length > 0 else { return nil }

    let ux = dx / length
    let uy = dy / length

    // On a one-square arrow the nominal insets would consume the whole shaft,
    // so both ends are capped to a share of the available length.
    let sourceInset = min(metrics.sourceInset * squareSide, length * 0.35)
    let targetInset = min(metrics.targetInset * squareSide, length * 0.15)

    let start = CGPoint(x: a.x + ux * sourceInset, y: a.y + uy * sourceInset)
    let tip = CGPoint(x: b.x - ux * targetInset, y: b.y - uy * targetInset)

    let isCurved = Square.isKnightMove(from: from, to: to)
    let mid = CGPoint(x: (start.x + tip.x) / 2, y: (start.y + tip.y) / 2)
    // Perpendicular to the travel direction; the sign is fixed so the same move
    // always bows the same way and repeated renders do not flip.
    let bow = isCurved ? metrics.knightCurvature * squareSide : 0
    let control = CGPoint(x: mid.x - uy * bow, y: mid.y + ux * bow)

    // For a quadratic curve the tangent at t = 1 is parallel to (tip - control),
    // so the head must align with that rather than with the straight a→b line.
    let tangentX = tip.x - control.x
    let tangentY = tip.y - control.y
    let tangentLength = (tangentX * tangentX + tangentY * tangentY).squareRoot()
    let dirX = tangentLength > 0 ? tangentX / tangentLength : ux
    let dirY = tangentLength > 0 ? tangentY / tangentLength : uy

    let shaftSpan = max(0, length - sourceInset - targetInset)
    let headLength = min(metrics.headLength * squareSide, shaftSpan * 0.6)
    let headHalfWidth = metrics.headHalfWidth * squareSide

    let shaftEnd = CGPoint(x: tip.x - dirX * headLength, y: tip.y - dirY * headLength)
    let headLeft = CGPoint(
      x: shaftEnd.x - dirY * headHalfWidth,
      y: shaftEnd.y + dirX * headHalfWidth
    )
    let headRight = CGPoint(
      x: shaftEnd.x + dirY * headHalfWidth,
      y: shaftEnd.y - dirX * headHalfWidth
    )

    return ArrowGeometry(
      start: start,
      control: control,
      shaftEnd: shaftEnd,
      tip: tip,
      headLeft: headLeft,
      headRight: headRight,
      shaftWidth: metrics.shaftWidth * squareSide,
      isCurved: isCurved
    )
  }
}
