//
//  BoardSquaresLayer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Layer 1 — the 64 squares, plus optional coordinates.
///
/// Drawn in a single `Canvas` rather than 64 views: the squares never animate
/// and never receive touches, so there is nothing to gain from giving each one
/// an identity, and a board inside a scrolling filmstrip pays for it 3× over.
struct BoardSquaresLayer: View {

  let geometry: BoardGeometry
  let style: BoardStyle

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
      let light = style.lightSquare.color(colorScheme)
      let dark = style.darkSquare.color(colorScheme)
      let side = geometry.squareSide

      for square in Square.allCases {
        var frame = geometry.frame(of: square)
        // Overdraw by a hairline: adjacent rects rounded to different device
        // pixels leave visible seams on non-integral board widths.
        frame.size.width += 0.5
        frame.size.height += 0.5
        context.fill(
          Path(frame),
          with: .color(square.color == .light ? light : dark)
        )
      }

      guard style.showsCoordinates, side > 12 else { return }
      let coordinateColor = style.coordinate.color(colorScheme)
      let fontSize = max(7, side * 0.17)

      for column in 0..<8 {
        guard let square = geometry.square(column: column, row: 7) else { continue }
        let text = Text(square.file.rawValue)
          .font(.system(size: fontSize, weight: .semibold))
          .foregroundStyle(coordinateColor)
        let frame = geometry.frame(of: square)
        context.draw(
          context.resolve(text),
          at: CGPoint(x: frame.maxX - side * 0.14, y: frame.maxY - side * 0.13),
          anchor: .bottomTrailing
        )
      }

      for row in 0..<8 {
        guard let square = geometry.square(column: 0, row: row) else { continue }
        let text = Text(verbatim: "\(square.rank.value)")
          .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
          .foregroundStyle(coordinateColor)
        let frame = geometry.frame(of: square)
        context.draw(
          context.resolve(text),
          at: CGPoint(x: frame.minX + side * 0.12, y: frame.minY + side * 0.10),
          anchor: .topLeading
        )
      }
    }
    .frame(width: geometry.side, height: geometry.side)
    .allowsHitTesting(false)
  }
}
