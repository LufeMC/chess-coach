import BoardUI
import SwiftUI

/// The move table.
///
/// Structured like a set table rather than a chess score sheet: a leading label,
/// an optional chip, then right-aligned monospaced number columns separated by
/// hairlines. Two consequences worth stating —
///
/// * **Only classified moves carry a chip.** Most rows are bare. A game where
///   four moves of sixty are badged reads as a diagnosis; one where all sixty are
///   badged reads as a heat map.
/// * **One column is coloured, never two.** The eval carries the row's weight in
///   primary; the delta beside it is smaller and takes the semantic colour, so
///   the row keeps a single anchor.
///
/// Built out of rows rather than a `List` because on iPhone this sits inside the
/// screen's scroll view, and a nested scrolling `List` there would fight the
/// outer one for the gesture.
struct ReviewMoveList: View {

    let rows: [ReviewMoveRow]
    /// The ply the board is standing on.
    let currentPly: Int?
    let style: BoardStyle
    var onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOVES")
                .typeRole(.label)

            if rows.isEmpty {
                Text("No moves recorded for this game.")
                    .typeRole(.caption)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 {
                            Divider()
                                .padding(.leading, 14)
                        }
                        rowView(row)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary)
                )
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ReviewMoveRow) -> some View {
        let isCurrent = row.ply == currentPly

        HStack(spacing: 10) {
            Text(row.label)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: 96, alignment: .leading)

            if let chip = row.chip {
                ClassificationBadge(kind: chip, size: .regular, style: style)
            }

            Spacer(minLength: 0)

            Text(row.evalAfter ?? "—")
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(row.evalAfter == nil ? .tertiary : .primary)
                .frame(width: 52, alignment: .trailing)

            Text(row.loss ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(lossColor(for: row))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(row.ply) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// The delta takes the row's semantic colour when there is one, and
    /// `.secondary` otherwise — an uncoloured number next to a coloured chip is
    /// the pairing the conventions ask for.
    private func lossColor(for row: ReviewMoveRow) -> Color {
        guard let chip = row.chip else { return .secondary }
        return chip.color(in: style).color(colorScheme)
    }
}

#Preview("Move list") {
    let rows: [ReviewMoveRow] = [
        ReviewMoveRow(
            id: UUID(), ply: 45, moveNumber: 23, isWhite: true, label: "23. Nf3", san: "Nf3",
            chip: nil, evalAfter: "+0.4", loss: nil, isMoment: false
        ),
        ReviewMoveRow(
            id: UUID(), ply: 46, moveNumber: 23, isWhite: false, label: "23… Nxe5", san: "Nxe5",
            chip: .blunder, evalAfter: "+2.8", loss: "−2.4", isMoment: true
        ),
        ReviewMoveRow(
            id: UUID(), ply: 47, moveNumber: 24, isWhite: true, label: "24. Rxe5", san: "Rxe5",
            chip: .great, evalAfter: "+2.9", loss: nil, isMoment: true
        ),
    ]

    return ScrollView {
        ReviewMoveList(
            rows: rows,
            currentPly: 46,
            style: .default,
            onSelect: { _ in }
        )
        .padding()
    }
}
