//
//  CaptureFlourishLayer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Layer 6 — what a capture was worth.
///
/// Concentric rings radiating from the square, green when the reader came out
/// ahead and red when they came out behind, with the signed material delta
/// floating up out of the square in the same colour.
///
/// This is the single highest-value thing on the board for a *training* app.
/// Every other chess app treats a capture as a piece disappearing; counting
/// material before a trade is the hardest habit for an improving player to
/// build, and a number that shows up on the board every time material changes
/// hands teaches it on every capture rather than in a lesson nobody opens.
///
/// It is loud on purpose and it is short on purpose: ~0.6 seconds, once, no
/// loop, and gone. It is also the only place on the board that shows a number,
/// which is what keeps it from becoming wallpaper.
struct CaptureFlourishLayer: View {

  let flourish: BoardModel.CaptureFlourish
  let geometry: BoardGeometry
  let style: BoardStyle

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var expanded = false

  var body: some View {
    let side = geometry.squareSide
    let center = geometry.center(of: flourish.square)

    ZStack(alignment: .topLeading) {
      ForEach(0..<BoardMetrics.captureFlourishRings, id: \.self) { ring in
        Circle()
          .strokeBorder(tint.opacity(0.85), lineWidth: side * 0.07)
          .frame(width: side, height: side)
          .scaleEffect(expanded ? BoardMetrics.captureFlourishScale(ring: ring) : 0.34)
          .opacity(expanded ? 0 : 0.95)
          .position(center)
          .animation(
            .easeOut(duration: BoardMetrics.captureFlourishDuration)
              .delay(BoardMetrics.captureFlourishDelay(ring: ring)),
            value: expanded
          )
      }

      // A few sparks, thrown outward on the diagonals so they never sit under
      // the number. Pure delight, no information — which is exactly why they
      // are small, few, and over before they are consciously noticed.
      ForEach(0..<4, id: \.self) { index in
        let angle = Double(index) * .pi / 2 + .pi / 4
        Circle()
          .fill(tint.opacity(0.9))
          .frame(width: side * 0.075, height: side * 0.075)
          .offset(
            x: expanded ? cos(angle) * side * 0.66 : 0,
            y: expanded ? sin(angle) * side * 0.66 : 0
          )
          .opacity(expanded ? 0 : 1)
          .position(center)
          .animation(.easeOut(duration: 0.5).delay(0.04), value: expanded)
      }

      Text(flourish.delta.label)
        .font(.system(size: side * 0.44, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(tint)
        // The number carries a shadow and the board does not, because it is the
        // one thing here drawn over the pieces rather than among them.
        .shadow(color: .black.opacity(0.25), radius: side * 0.04, x: 0, y: side * 0.015)
        .offset(y: expanded ? -side * 0.95 : -side * 0.45)
        .opacity(expanded ? 0 : 1)
        .position(center)
        .animation(.easeOut(duration: 0.62).delay(0.05), value: expanded)
    }
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear {
      guard !reduceMotion else { return }
      expanded = true
    }
  }

  /// Green for a gain, red for a loss.
  ///
  /// This is the one place green means something other than "this was the
  /// answer", and it does not collide: material gained *is* the good outcome,
  /// and red already means exactly "advantage lost" everywhere else in the app.
  /// The sign on the number carries the same meaning independently, so nothing
  /// here is encoded by colour alone.
  private var tint: Color {
    (flourish.delta.isGain ? style.success : style.danger).color(colorScheme)
  }
}
