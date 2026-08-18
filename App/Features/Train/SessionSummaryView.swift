//
//  SessionSummaryView.swift
//  ChessCoach
//

import SwiftUI

/// What the session amounted to.
///
/// Uxcel Go's result *rows*, and none of the rest of that screen: no confetti,
/// no stars, no donut. Four rows, each a leading symbol, a label and a
/// right-aligned monospaced value, then one filled action. A number in a row is
/// read faster than the same number in the middle of a ring, and the ring adds
/// nothing but a second thing to look at.
///
/// The `Missed` section sits *below* the action deliberately: it is material to
/// come back to, not a gate on leaving. The heading carries the semantic colour
/// and the chips stay neutral — a list where every chip is orange is a list of
/// accusations, and the design conventions call that out by name (a badge on
/// 100% of rows conveys tone, not data).
struct SessionSummaryView: View {

    let progress: SessionProgress
    let missed: [MissedItem]
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 0) {
                    SummaryRow(symbol: "checkmark.circle", label: "Solved", value: progress.solvedLabel)
                    Divider().padding(.leading, 34)
                    SummaryRow(symbol: "lightbulb", label: "Hints", value: progress.hintsLabel)
                    Divider().padding(.leading, 34)
                    SummaryRow(symbol: "clock", label: "Time", value: progress.timeLabel)
                    Divider().padding(.leading, 34)
                    SummaryRow(
                        symbol: "chart.line.uptrend.xyaxis",
                        label: "Rating",
                        value: progress.ratingLabel,
                        valueTint: ratingTint
                    )
                }

                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !missed.isEmpty {
                    missedSection
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle("Session")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var ratingTint: Color? {
        if progress.ratingDelta > 0 { return .green }
        if progress.ratingDelta < 0 { return .orange }
        return nil
    }

    private var missedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Missed")
                .font(.subheadline.weight(.semibold))
                // The heading is the only coloured thing here.
                .foregroundStyle(.orange)

            FlowChips(items: missed)
        }
    }
}

/// One result row.
private struct SummaryRow: View {

    let symbol: String
    let label: String
    let value: String
    var valueTint: Color?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            Text(label)
                .font(.body)

            Spacer(minLength: 12)

            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(valueTint ?? .primary)
        }
        .padding(.vertical, 11)
    }
}

/// The missed concepts, wrapped across as many lines as they need.
///
/// Neutral fill and neutral text: these are things to look at again, and the
/// heading above them has already said which kind of thing they are.
private struct FlowChips: View {

    let items: [MissedItem]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { item in
                Text(item.concept)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }
}

/// Minimal wrapping layout.
///
/// `LazyVGrid` cannot do this — chips are different widths and a grid would
/// column-align them, leaving ragged gaps between short and long concept names.
struct FlowLayout: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, availableWidth: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, availableWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if projected > availableWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    NavigationStack {
        SessionSummaryView(
            progress: SessionProgress(
                index: 9,
                completed: 10,
                total: 10,
                solved: 8,
                hinted: 1,
                elapsed: 252,
                ratingDelta: 12
            ),
            missed: [
                MissedItem(concept: "pin"),
                MissedItem(concept: "back-rank mate")
            ],
            onContinue: {}
        )
    }
}
