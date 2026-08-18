//
//  BoardAnnotationOverlay.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import SwiftUI

/// The puzzle-specific marks drawn over `BoardView`.
///
/// ## Why this is an overlay and not a `SquareHighlight`
///
/// `BoardUI` owns the marks the *board* needs — selection, legal moves, check,
/// last move — and its `HighlightKind` palette is fixed by design so two callers
/// cannot give the same shape two meanings. Correct/wrong feedback is a training
/// concept, not a board concept, so it is drawn here rather than by widening a
/// shared enum that Play and Review would then inherit.
///
/// The geometry is still `BoardUI`'s: `BoardGeometry` and `ArrowGeometry` are
/// public precisely so an overlay can line up with the squares underneath
/// without re-deriving the grid.
struct BoardAnnotationOverlay: View {

    let orientation: Piece.Color
    /// Ring on a destination square.
    var ring: BoardRing?
    /// Thin origin→destination hint arrow.
    var hint: (from: Square, to: Square)?
    var style: BoardStyle = .default

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let geometry = BoardGeometry(containerSize: proxy.size, orientation: orientation)

            Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                if let hint { draw(hint: hint, geometry: geometry, into: &context) }
                if let ring { draw(ring: ring, geometry: geometry, into: &context) }
            }
            .frame(width: geometry.side, height: geometry.side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.18), value: ring)
    }

    // MARK: Ring

    /// Two concentric strokes rather than one.
    ///
    /// A single ring at this weight is easy to mistake for `BoardUI`'s
    /// legal-capture ring; the doubled stroke reads as a target and stays
    /// distinguishable from it even at thumbnail size.
    private func draw(ring: BoardRing, geometry: BoardGeometry, into context: inout GraphicsContext) {
        let side = geometry.squareSide
        guard side > 0 else { return }
        let centre = geometry.center(of: ring.square)
        let color = tone(ring.tone).color(colorScheme)

        for (radius, width, opacity) in [
            (side * 0.42, side * 0.070, 0.95),
            (side * 0.28, side * 0.045, 0.55)
        ] {
            let rect = CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color.opacity(opacity)),
                lineWidth: width
            )
        }
    }

    /// Green for correct, orange for wrong.
    ///
    /// Orange, never red. Red belongs to Review, where it labels the severity of
    /// a blunder in a game that has already been played. A failed puzzle is a
    /// scheduling event — the card comes back sooner — and colouring it the same
    /// as a lost game would be a claim about the stakes that is simply untrue.
    private func tone(_ tone: BoardRing.Tone) -> DualColor {
        switch tone {
        case .correct: style.success
        case .wrong: style.warning
        }
    }

    // MARK: Hint arrow

    /// A thin shaft with a small head, in `.tertiary` grey.
    ///
    /// Explicitly not the accent colour and not `ArrowStyle.hint`'s amber: an
    /// arrow the user asked for is not a recommendation the app is making, and
    /// drawing it as loudly as an engine's best move would make the two
    /// indistinguishable in a screenshot.
    private func draw(
        hint: (from: Square, to: Square),
        geometry: BoardGeometry,
        into context: inout GraphicsContext
    ) {
        var metrics = ArrowGeometry.Metrics()
        metrics.shaftWidth = 0.045
        metrics.sourceInset = 0.34
        metrics.targetInset = 0.14
        metrics.headLength = 0.20
        metrics.headHalfWidth = 0.11

        guard
            let shape = ArrowGeometry.make(
                from: hint.from,
                to: hint.to,
                in: geometry,
                metrics: metrics
            )
        else { return }

        var shaft = Path()
        shaft.move(to: shape.start)
        if shape.isCurved {
            shaft.addQuadCurve(to: shape.shaftEnd, control: shape.control)
        } else {
            shaft.addLine(to: shape.shaftEnd)
        }
        context.stroke(
            shaft,
            with: .style(HierarchicalShapeStyle.tertiary),
            style: StrokeStyle(lineWidth: shape.shaftWidth, lineCap: .round, lineJoin: .round)
        )

        var head = Path()
        head.move(to: shape.tip)
        head.addLine(to: shape.headLeft)
        head.addLine(to: shape.headRight)
        head.closeSubpath()
        context.fill(head, with: .style(HierarchicalShapeStyle.tertiary))
    }
}
