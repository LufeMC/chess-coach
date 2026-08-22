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
    /// Whether the engine's judgement of each move may be shown.
    ///
    /// False while the self-check is still asking. "Where did you lose
    /// material?" is answered in one tap by expanding this table and reading
    /// the Blunder chip, and a quiz the user learns to shortcut in their first
    /// game removes the most valuable mechanic on the screen.
    var showsJudgement: Bool = true
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
                    headerRow
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        Divider()
                            .padding(.leading, 14)
                            .opacity(offset == 0 ? 0.6 : 1)
                        rowView(row)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary)
                )

                legend
            }
        }
    }

    /// Names the columns.
    ///
    /// Without it the table puts a White-relative evaluation next to a
    /// mover-relative cost with nothing to say they are measured from different
    /// sides, which is how a player of Black ends up reading their own good move
    /// as a number going the wrong way.
    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Move")
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 0)
            Text("After")
                .frame(width: 52, alignment: .trailing)
            if showsJudgement {
                Text("Cost")
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .typeRole(.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        Text(legendText)
            .typeRole(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var legendText: String {
        var text = "After: the position once the move is played, always from White's side."
        if showsJudgement {
            text += " Cost: what the move cost whoever played it, in pawns."
            // A forced mate at one end of a move has no pawn value — inverting
            // the stored curve there returns the clamp, about fourteen pawns —
            // so the cell says "mate" instead of printing a number that means
            // nothing. Explained only when one is actually on screen.
            if rows.contains(where: { $0.loss == ReviewMoveCost.allowedMate.label }) {
                text += " mate: the move turned a forced mate on or off."
            }
        }
        if rows.contains(where: { $0.evalAfter?.hasPrefix("#") == true }) {
            text += " #4 W: White mates in four."
        }
        return text
    }

    @ViewBuilder
    private func rowView(_ row: ReviewMoveRow) -> some View {
        let isCurrent = row.ply == currentPly

        HStack(spacing: 10) {
            Text(row.label)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: 96, alignment: .leading)

            if showsJudgement, let chip = row.chip {
                ClassificationBadge(kind: chip, size: .regular, style: style)
            }

            Spacer(minLength: 0)

            Text(row.evalAfter ?? "—")
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(row.evalAfter == nil ? .tertiary : .primary)
                .frame(width: 52, alignment: .trailing)

            if showsJudgement {
                Text(row.loss ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(lossColor(for: row))
                    .frame(width: 44, alignment: .trailing)
            }
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
