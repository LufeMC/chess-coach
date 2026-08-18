//
//  PromotionPicker.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// Layer 6 — the inline promotion picker.
///
/// It grows *out of* the promotion square rather than appearing as a sheet: the
/// choice belongs to the move, and a modal here would hide the position the
/// choice depends on. The stack always grows toward the middle of the board, so
/// it never runs off the edge.
struct PromotionPicker: View {

  let pending: BoardModel.PendingPromotion
  let geometry: BoardGeometry
  let style: BoardStyle
  let onChoose: (Piece.Kind) -> Void
  let onCancel: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  /// Queen first: it is the right answer in the overwhelming majority of games,
  /// and it lands directly on the promotion square so it can be picked without
  /// the pointer moving at all.
  private let choices: [Piece.Kind] = [.queen, .rook, .bishop, .knight]

  var body: some View {
    ZStack(alignment: .topLeading) {
      // A tap anywhere else cancels. Scrimming rather than dimming to black
      // keeps the surrounding position legible while the picker is up.
      Rectangle()
        .fill(.black.opacity(0.28))
        .contentShape(Rectangle())
        .onTapGesture { onCancel() }

      ForEach(Array(choices.enumerated()), id: \.element) { index, kind in
        cell(for: kind)
          .position(center(forOffset: index))
      }
    }
    .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
    .transition(.opacity)
  }

  private func cell(for kind: Piece.Kind) -> some View {
    let side = geometry.squareSide
    return Button {
      onChoose(kind)
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
          .fill(style.lightSquare.color(colorScheme))
          .shadow(color: .black.opacity(0.3), radius: side * 0.1, y: side * 0.03)
        PieceView(kind: kind, color: pending.color, renderer: style.pieceSet, size: side * 0.94)
      }
      .frame(width: side, height: side)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Promote to \(kind.description)"))
  }

  /// Whether the stack grows down the board (true) or up it.
  private var growsDown: Bool {
    geometry.row(of: pending.to) < 4
  }

  private func center(forOffset offset: Int) -> CGPoint {
    let base = geometry.center(of: pending.to)
    let delta = CGFloat(offset) * geometry.squareSide * (growsDown ? 1 : -1)
    return CGPoint(x: base.x, y: base.y + delta)
  }
}
