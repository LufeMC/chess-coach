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

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(departing) { token in
        PieceView(
          kind: token.kind,
          color: token.color,
          renderer: style.pieceSet,
          size: geometry.squareSide
        )
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
        .opacity(token.id == draggingTokenID ? 0 : 1)
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

/// Layer 5 — the piece under the finger or cursor.
///
/// Separated from the pieces layer so it can be lifted, scaled and shadowed
/// without disturbing the grid, and so it always draws above every other piece.
struct BoardDragLayer: View {

  let drag: BoardModel.DragState
  let token: PieceToken
  let geometry: BoardGeometry
  let style: BoardStyle

  var body: some View {
    PieceView(
      kind: token.kind,
      color: token.color,
      renderer: style.pieceSet,
      size: geometry.squareSide
    )
    .scaleEffect(drag.isReturning ? 1.0 : 1.12)
    .shadow(color: .black.opacity(0.35), radius: geometry.squareSide * 0.12, x: 0, y: geometry.squareSide * 0.05)
    .position(drag.location)
    .animation(.snappy(duration: 0.18), value: drag.isReturning)
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}
