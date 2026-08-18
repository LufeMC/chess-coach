//
//  BoardArrowLayer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Layer 3 — arrows, drawn as a shaft plus a head.
///
/// A `Canvas` here because arrows are pure paint: they never take a touch, and
/// drawing them all in one pass keeps the head and shaft of the same arrow from
/// ever landing on different frames.
struct BoardArrowLayer: View {

  let arrows: [BoardArrow]
  let geometry: BoardGeometry
  let style: BoardStyle

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
      for arrow in arrows {
        guard let shape = ArrowGeometry.make(from: arrow.from, to: arrow.to, in: geometry) else {
          continue
        }
        let color = arrow.style.color(in: style)
          .color(colorScheme)
          .opacity(arrow.style.opacity)

        var shaft = Path()
        shaft.move(to: shape.start)
        if shape.isCurved {
          shaft.addQuadCurve(to: shape.shaftEnd, control: shape.control)
        } else {
          shaft.addLine(to: shape.shaftEnd)
        }

        context.stroke(
          shaft,
          with: .color(color),
          style: StrokeStyle(lineWidth: shape.shaftWidth, lineCap: .round, lineJoin: .round)
        )

        var head = Path()
        head.move(to: shape.tip)
        head.addLine(to: shape.headLeft)
        head.addLine(to: shape.headRight)
        head.closeSubpath()
        context.fill(head, with: .color(color))
      }
    }
    .frame(width: geometry.side, height: geometry.side)
    .allowsHitTesting(false)
  }
}
