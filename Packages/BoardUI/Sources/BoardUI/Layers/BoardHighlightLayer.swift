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
///
/// ## Instant in, staggered out
///
/// Nothing here fades *in*. Selection feedback that animates on is the single
/// clearest way to make a touch surface feel laggy — the finger is already down
/// and the interface is still deciding. So insertion is `.identity` and the
/// mark is simply there on touch-down.
///
/// Removal is where the craft goes. When a selection is put down, the legal-move
/// dots leave in rings radiating out from the square the piece was standing on,
/// 20ms apart. It costs nothing, it is barely a tenth of a second end to end,
/// and it turns "the dots vanished" into "the piece was put down".
struct BoardHighlightLayer: View {

  let highlights: [SquareHighlight]
  let geometry: BoardGeometry
  let style: BoardStyle
  /// Draw only the marks that belong above the pieces, or only those below.
  let abovePieces: Bool
  /// Square the legal-move marks radiate from as they leave. Captured with the
  /// view, so it is still the right square at the moment the selection clears.
  var staggerOrigin: Square?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(visible) { highlight in
        HighlightMark(kind: highlight.kind, side: geometry.squareSide, style: style)
          .frame(width: geometry.squareSide, height: geometry.squareSide)
          .position(geometry.center(of: highlight.square))
          .transition(transition(for: highlight))
      }
    }
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    // An animation context has to exist for the removal transitions to run at
    // all; every mark overrides it with its own curve, so this is only ever the
    // fallback for a mark that asked for nothing in particular.
    .animation(.boardSnappy, value: visible.map(\.id))
    .allowsHitTesting(false)
  }

  private var visible: [SquareHighlight] {
    highlights.filter { $0.kind.drawsAbovePieces == abovePieces }
  }

  private func transition(for highlight: SquareHighlight) -> AnyTransition {
    switch highlight.kind {
    case .lastMoveFrom, .lastMoveTo:
      // The last move is a fact about the position, not an event. It appears
      // with the position and persists until the next move; animating it would
      // make every arriving position feel like something was happening.
      return .identity

    case .legalMove, .legalCapture:
      let delay = reduceMotion
        ? 0
        : BoardMetrics.staggerDelay(from: staggerOrigin, to: highlight.square)
      return .asymmetric(
        insertion: .identity,
        removal: .opacity.animation(.easeOut(duration: BoardMetrics.staggerFade).delay(delay))
      )

    default:
      return .asymmetric(
        insertion: .identity,
        removal: .opacity.animation(.easeOut(duration: 0.15))
      )
    }
  }
}

/// One highlight, drawn to fill the square it is handed.
struct HighlightMark: View {

  let kind: HighlightKind
  let side: CGFloat
  let style: BoardStyle

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    // The alpha ladder is the readability story of the whole board, and it only
    // works read top to bottom: selection (28%) must beat the last move (14%),
    // and the last move must stay quiet enough that a board wearing it still
    // reads as a position. Marks that sit *over* a piece are shapes rather than
    // washes — a dot or a ring survives at 22% where a wash would not.
    switch kind {
    case .lastMoveFrom, .lastMoveTo:
      Rectangle().fill(lastMove.opacity(BoardMetrics.lastMoveFill))

    case .selected:
      Rectangle().fill(accent.opacity(BoardMetrics.selectionFill))

    case .check:
      CheckGlow(side: side, color: danger)

    case .legalMove:
      // Primary, not the accent: the accent is rationed to the one thing the
      // user is doing — the selection — and spending it again on twenty dots
      // would make the selected square stop being special.
      Circle()
        .fill(hint)
        .frame(
          width: BoardMetrics.legalMoveDotDiameter(squareSide: side),
          height: BoardMetrics.legalMoveDotDiameter(squareSide: side)
        )

    case .legalCapture:
      // A ring rather than a dot or a wash: it frames the piece standing there
      // instead of covering it, so you can still see *what* you would be taking.
      let ring = BoardMetrics.legalCaptureRing(
        squareSide: side,
        increasedContrast: contrast == .increased
      )
      Circle()
        .strokeBorder(hint, lineWidth: ring.lineWidth)
        .padding(ring.inset)

    case .dropTarget:
      // Never a fill. The piece is lifted 24pt above this square with a shadow
      // under it; a wash down here would simply not be seen.
      let ring = BoardMetrics.dropTargetRing(squareSide: side)
      Rectangle()
        .strokeBorder(accent.opacity(0.85), lineWidth: ring.lineWidth)
        .padding(ring.inset)

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
      // The one place green is allowed on a square: "this was the answer" is a
      // distinct state from "good move", and the brief calls for a dashed green
      // target.
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
  private var lastMove: Color { style.lastMove.color(colorScheme) }

  /// Dots and capture rings. Increased contrast raises the alpha rather than
  /// changing the hue, so the marks stay the same marks.
  private var hint: Color {
    .primary.opacity(BoardMetrics.moveHintOpacity(increasedContrast: contrast == .increased))
  }
}

/// The check mark: a red glow *behind* the king's square.
///
/// Not a filled square and not a border — either would be competing directly
/// with the selection wash and the last-move wash for the same 64 pixels, and
/// check is precisely the state that must never be mistaken for one of those.
///
/// It blooms once and then holds. A looping pulse while an engine thinks is one
/// of the most tiring things an interface can do, and it is worse here than
/// elsewhere: the thing it is pulsing about does not change for as long as it
/// pulses.
private struct CheckGlow: View {

  let side: CGFloat
  let color: Color

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var settled = false

  var body: some View {
    RadialGradient(
      colors: [color.opacity(0.85), color.opacity(0.34), color.opacity(0)],
      center: .center,
      startRadius: 0,
      endRadius: BoardMetrics.checkGlowRadius(squareSide: side)
    )
    .scaleEffect(settled ? 1 : BoardMetrics.checkGlowBloomScale)
    .opacity(settled ? BoardMetrics.checkGlowRestOpacity : 1)
    .onAppear {
      guard !reduceMotion else {
        settled = true
        return
      }
      withAnimation(.easeOut(duration: BoardMetrics.checkPulseDuration)) { settled = true }
    }
  }
}
