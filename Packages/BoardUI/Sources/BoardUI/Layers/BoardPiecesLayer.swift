//
//  BoardPiecesLayer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Layer 4 — the pieces.
///
/// One view per piece, positioned by its square and animated on `.position`.
/// Explicit positioning beats `matchedGeometryEffect` here because the source
/// and destination are the *same* view: the token keeps its identity across the
/// move (see ``PieceLayout``), so SwiftUI already has both ends of the
/// animation and only needs to be told to interpolate.
struct BoardPiecesLayer: View {

  let tokens: [PieceToken]
  /// Captured pieces still finishing their exit. Drawn first so the piece that
  /// took them slides over the top rather than under.
  let departing: [PieceToken]
  let geometry: BoardGeometry
  let style: BoardStyle
  /// Token currently held by the pointer — drawn by the drag layer instead.
  let draggingTokenID: PieceToken.ID?
  /// What is left of that token on its origin square: a ghost once the piece is
  /// actually travelling, nothing while it is merely pressed.
  var ghostOpacity: Double = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(departing) { token in
        DepartingPieceView(token: token, style: style, side: geometry.squareSide)
          .position(geometry.center(of: token.square))
      }

      ForEach(tokens) { token in
        PieceView(
          kind: token.kind,
          color: token.color,
          renderer: style.pieceSet,
          size: geometry.squareSide
        )
        .position(geometry.center(of: token.square))
        // An empty origin square during a drag reads as the piece having been
        // deleted. A quarter-strength ghost says "this is where it came from",
        // which is also the answer to "what happens if I let go out here".
        .opacity(token.id == draggingTokenID ? ghostOpacity : 1)
        // A move should feel like the piece was pushed, not thrown: a short
        // spring with almost no bounce lands in ~180ms and stops dead.
        .animation(.smooth(duration: 0.2, extraBounce: 0.05), value: token.square)
        .animation(.easeOut(duration: 0.1), value: draggingTokenID)
        .transition(.opacity.animation(.easeOut(duration: 0.12)))
      }
    }
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}

/// A piece on its way off the board.
///
/// Capture as instant disappearance is one of the most reliable tells of an
/// unfinished app: the most consequential event in the game is the only one with
/// no animation at all. Scaling down and fading over 0.18s costs a fifth of a
/// second and is the difference between a piece being *taken* and a piece
/// blinking out of existence.
private struct DepartingPieceView: View {

  let token: PieceToken
  let style: BoardStyle
  let side: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var gone = false

  var body: some View {
    PieceView(
      kind: token.kind,
      color: token.color,
      renderer: style.pieceSet,
      size: side
    )
    .scaleEffect(gone ? BoardMetrics.captureFadeScale : 1)
    .opacity(gone ? 0 : 1)
    .onAppear {
      // A beat before it starts, so the capturing piece is already arriving and
      // the square is never seen standing empty.
      withAnimation(
        .easeOut(duration: BoardMetrics.captureFadeDuration)
          .delay(reduceMotion ? 0 : BoardMetrics.captureFadeDelay)
      ) {
        gone = true
      }
    }
  }
}

/// Layer 5 — the piece under the finger or cursor.
///
/// Separated from the pieces layer so it can be lifted, scaled and shadowed
/// without disturbing the grid, and so it always draws above every other piece.
///
/// This is the one place on the board where a drop shadow is correct. Everything
/// else is flat by design; this piece is genuinely off the surface, held up by a
/// finger, and the shadow is what says so.
struct BoardDragLayer: View {

  let drag: BoardModel.DragState
  let token: PieceToken
  let geometry: BoardGeometry
  let style: BoardStyle

  var body: some View {
    let presentation = BoardMetrics.dragPresentation(
      squareSide: geometry.squareSide,
      originCenter: geometry.center(of: drag.origin),
      touch: drag.location,
      isActive: drag.isActive,
      isReturning: drag.isReturning,
      liftsAboveFinger: liftsAboveFinger
    )

    PieceView(
      kind: token.kind,
      color: token.color,
      renderer: style.pieceSet,
      size: geometry.squareSide
    )
    .scaleEffect(presentation.scale)
    .shadow(
      color: .black.opacity(presentation.shadowOpacity),
      radius: presentation.shadowRadius,
      x: 0,
      y: presentation.shadowOffsetY
    )
    .position(presentation.position)
    // Only the return is a spring — while the finger is down the piece tracks
    // it exactly, because anything else is a piece lagging behind the hand.
    .animation(drag.isReturning ? .boardGentle : nil, value: drag.isReturning)
    .animation(drag.isReturning ? .boardGentle : nil, value: presentation.position)
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    .allowsHitTesting(false)
  }

  /// A fingertip hides the square it is on; a mouse pointer hides nothing, so
  /// lifting the piece away from it on a Mac would just make the piece hover
  /// mysteriously above the cursor.
  private var liftsAboveFinger: Bool {
    #if os(iOS) || os(visionOS)
      return true
    #else
      return false
    #endif
  }
}
