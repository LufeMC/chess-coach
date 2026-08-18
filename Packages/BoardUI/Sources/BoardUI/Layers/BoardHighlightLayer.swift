//
//  BoardHighlightLayer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Layer 2 — square treatments.
///
/// Individual views rather than a `Canvas`: highlights appear and disappear
/// constantly (every selection changes half of them) and each one wants its own
/// transition. A canvas would redraw all 64 squares for a single dot.
struct BoardHighlightLayer: View {

  let highlights: [SquareHighlight]
  let geometry: BoardGeometry
  let style: BoardStyle
  /// Draw only the marks that belong above the pieces, or only those below.
  let abovePieces: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(visible) { highlight in
        HighlightMark(kind: highlight.kind, side: geometry.squareSide, style: style)
          .frame(width: geometry.squareSide, height: geometry.squareSide)
          .position(geometry.center(of: highlight.square))
          .transition(.opacity.combined(with: .scale(scale: 0.86)))
      }
    }
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    .animation(.snappy(duration: 0.16), value: visible.map(\.id))
    .allowsHitTesting(false)
  }

  private var visible: [SquareHighlight] {
    highlights.filter { $0.kind.drawsAbovePieces == abovePieces }
  }
}

/// One highlight, drawn to fill the square it is handed.
struct HighlightMark: View {

  let kind: HighlightKind
  let side: CGFloat
  let style: BoardStyle

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // Saturation lives here and nowhere else on the board. Marks that sit *over*
    // a piece (dots, rings, borders) run at ≥60% opacity so they read at a
    // glance; full-square washes run lower, because at 60% a wash stops being an
    // overlay and starts being a repaint of the square.
    switch kind {
    case .lastMoveFrom:
      Rectangle().fill(accent.opacity(0.20))
    case .lastMoveTo:
      Rectangle().fill(accent.opacity(0.30))
    case .selected:
      Rectangle().fill(accent.opacity(0.36))
    case .check:
      // A glow rather than a fill: the king has to stay the most readable thing
      // on a checked square.
      RadialGradient(
        colors: [danger.opacity(0.9), danger.opacity(0.35), danger.opacity(0)],
        center: .center,
        startRadius: 0,
        endRadius: side * 0.55
      )
    case .legalMove:
      Circle()
        .fill(accent.opacity(0.65))
        .frame(width: side * 0.30, height: side * 0.30)
    case .legalCapture:
      Circle()
        .strokeBorder(accent.opacity(0.70), lineWidth: side * 0.09)
        .padding(side * 0.03)
    case .hint:
      // A framed square, deliberately *not* a ring: a coach hint and a legal
      // capture would otherwise be the same teal circle, and the hint ladder
      // depends on the user reading "look here" as its own thing.
      Rectangle()
        .strokeBorder(accent.opacity(0.9), lineWidth: side * 0.08)
        .background(accent.opacity(0.18))
    case .momentSquare:
      Rectangle()
        .strokeBorder(
          accent.opacity(0.75),
          style: StrokeStyle(lineWidth: side * 0.05, dash: [side * 0.16, side * 0.11])
        )
    case .correctAnswer:
      // The one place green is allowed: "this was the answer" is a distinct
      // state from "good move", and the brief calls for a dashed green target.
      Rectangle()
        .strokeBorder(
          success.opacity(0.9),
          style: StrokeStyle(lineWidth: side * 0.055, dash: [side * 0.14, side * 0.10])
        )
        .background(success.opacity(0.12))
    }
  }

  private var accent: Color { style.accent.color(colorScheme) }
  private var danger: Color { style.danger.color(colorScheme) }
  private var success: Color { style.success.color(colorScheme) }
}
