//
//  MomentFilmstrip.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// One card in the review filmstrip.
public struct MomentThumbnail: Identifiable, Sendable {

  public var id: UUID
  /// The position as it stood at the moment.
  public var position: Position
  /// Board orientation for the thumbnail — the reader's own colour.
  public var orientation: Piece.Color
  /// Full-move number, as shown to the reader.
  public var moveNumber: Int
  /// SAN of the move that created the moment, e.g. `"Nxe5?"`.
  public var san: String
  public var classification: MoveClassification
  /// One line on what was at stake. Kept to a phrase — the card is a teaser for
  /// the commentary below, not a substitute for it.
  public var stake: String?
  /// Squares to mark on the thumbnail.
  public var highlights: [SquareHighlight]

  public init(
    id: UUID = UUID(),
    position: Position,
    orientation: Piece.Color = .white,
    moveNumber: Int,
    san: String,
    classification: MoveClassification,
    stake: String? = nil,
    highlights: [SquareHighlight] = []
  ) {
    self.id = id
    self.position = position
    self.orientation = orientation
    self.moveNumber = moveNumber
    self.san = san
    self.classification = classification
    self.stake = stake
    self.highlights = highlights
  }
}

/// The horizontal strip of review moments.
///
/// Capped visually rather than structurally: the caller decides how many
/// moments matter, but the card width is sized so roughly three fit a phone
/// screen, because a game with fifteen "key moments" has none.
public struct MomentFilmstrip: View {

  private let moments: [MomentThumbnail]
  private let style: BoardStyle
  private let cardWidth: CGFloat
  @Binding private var selection: UUID?

  @Environment(\.colorScheme) private var colorScheme

  public init(
    moments: [MomentThumbnail],
    selection: Binding<UUID?>,
    style: BoardStyle = .default,
    cardWidth: CGFloat = 150
  ) {
    self.moments = moments
    self._selection = selection
    self.style = style
    self.cardWidth = cardWidth
  }

  public var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 12) {
        ForEach(moments) { moment in
          card(moment)
            .id(moment.id)
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, 16)
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollIndicators(.hidden)
  }

  private func card(_ moment: MomentThumbnail) -> some View {
    Button {
      // Select-only, deliberately not a toggle. The screen that owns this strip
      // drives a board and a coach card off the selection, so deselecting would
      // take the most valuable content on the page away; the host therefore
      // ignores a nil, and a tap that toggled to nil read as a broken tap — the
      // ring blinked and nothing else moved.
      selection = moment.id
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        BoardView(
          position: moment.position,
          orientation: moment.orientation,
          interaction: .locked,
          highlights: moment.highlights,
          style: style
        )
        .frame(width: cardWidth, height: cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topLeading) {
          // The move number rides on the thumbnail corner rather than sitting in
          // the text block: it identifies the picture, so it belongs on it.
          Text(verbatim: "\(moment.moveNumber)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(6)
        }

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(moment.san)
              .font(.system(.footnote, design: .monospaced))
              .foregroundStyle(.primary)
            Spacer(minLength: 0)
          }
          ClassificationBadge(kind: moment.classification, size: .compact, style: style)
          if let stake = moment.stake {
            Text(stake)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2, reservesSpace: true)
              .multilineTextAlignment(.leading)
          }
        }
        .frame(width: cardWidth, alignment: .leading)
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.quaternary.opacity(selection == moment.id ? 0.9 : 0.5))
      )
      .overlay {
        // Selection is a ring, not a colour change — the card already carries a
        // classification colour and a second one would compete with it.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(
            style.accent.color(colorScheme).opacity(selection == moment.id ? 0.9 : 0),
            lineWidth: 2
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .animation(.snappy(duration: 0.18), value: selection)
    .accessibilityLabel(Text("Move \(moment.moveNumber), \(moment.san), \(moment.classification.title)"))
  }
}

// MARK: - Previews

private func sampleMoments() -> [MomentThumbnail] {
  let openings = [
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
    "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R b KQkq - 6 5",
    "rnbqkbnr/ppp2ppp/8/3pp3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 3"
  ]
  let data: [(Int, String, MoveClassification, String, Square, Square)] = [
    (12, "Nxe5?", .blunder, "Drops a piece to the pin.", .f3, .e5),
    (18, "Qd2?!", .inaccuracy, "Lets the knight settle on d4.", .d1, .d2),
    (23, "Rfd1", .best, "The only move that holds the file.", .f1, .d1)
  ]
  return zip(openings, data).map { fen, item in
    MomentThumbnail(
      position: Position(fen: fen)!,
      moveNumber: item.0,
      san: item.1,
      classification: item.2,
      stake: item.3,
      highlights: SquareHighlight.lastMove(from: item.4, to: item.5)
        + [SquareHighlight(item.5, .momentSquare)]
    )
  }
}

#Preview("Moment filmstrip") {
  @Previewable @State var selection: UUID?

  VStack(alignment: .leading, spacing: 10) {
    Text("MOMENTS")
      .font(.caption.weight(.semibold))
      .textCase(.uppercase)
      .tracking(0.6)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
    MomentFilmstrip(moments: sampleMoments(), selection: $selection)
  }
  .padding(.vertical)
}
