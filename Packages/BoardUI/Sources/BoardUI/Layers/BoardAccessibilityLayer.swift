//
//  BoardAccessibilityLayer.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// The input layer's accessibility half — one element per square.
///
/// The pointer surface is a single transparent rectangle, which VoiceOver reads
/// as one enormous unlabelled control: a reader can be told there is a chess
/// board, and nothing else. These 64 empty cells give the rotor something to
/// walk and something to activate, and because they carry no gesture of their
/// own the drag gesture on their parent still receives every touch.
///
/// Laid out as a real grid rather than positioned individually, so each
/// element's accessibility frame is its own square and the reading order runs
/// the way the board is drawn — top rank first, left to right.
struct BoardAccessibilityLayer: View {

  let model: BoardModel
  let geometry: BoardGeometry
  let interaction: BoardInteraction

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<8, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<8, id: \.self) { column in
            cell(at: column, row: row)
          }
        }
      }
    }
    .frame(width: geometry.side, height: geometry.side)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func cell(at column: Int, row: Int) -> some View {
    if let square = geometry.square(column: column, row: row) {
      let hint = model.accessibilityHint(for: square, interaction: interaction)

      Color.clear
        .frame(width: geometry.squareSide, height: geometry.squareSide)
        .accessibilityElement()
        .accessibilityLabel(Text(model.accessibilityLabel(for: square)))
        // Only squares that would actually do something announce themselves as
        // controls; on a locked board every square stays readable but inert.
        .accessibilityAddTraits(hint == nil ? [] : .isButton)
        .accessibilityAddTraits(square == model.selection ? .isSelected : [])
        .accessibilityHint(Text(hint ?? ""))
        .accessibilityAction {
          // Activation is a tap: a VoiceOver user selects and moves with the
          // same two gestures a sighted user does, one square at a time.
          model.tap(square, interaction: interaction)
        }
    }
  }
}
