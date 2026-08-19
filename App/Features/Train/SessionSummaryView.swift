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
/// and the chips stay neutral — a list where every chip is amber is a list of
/// accusations, and the design conventions call that out by name (a badge on
/// 100% of rows conveys tone, not data).
///
/// The rating row is **not tinted**. A signed monospaced `+12` already says
/// which way it went, and the two tokens that could carry it are both spoken
/// for: green is the eval bar's "advantage gained" and amber is "note this",
/// neither of which is what a session's rating delta means. The direction is
/// encoded in the row's glyph instead, which is also the rule about never
/// encoding with colour alone, applied honestly rather than in reverse.
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
                    SummaryRow(symbol: ratingSymbol, label: "Rating", value: progress.ratingLabel)
                }
                .padding(.horizontal, 16)
                .elevation(.raised, cornerRadius: CornerRadius.card)

                Button("Continue", action: onContinue)
                    .buttonStyle(.primaryAction)

                if !missed.isEmpty {
                    missedSection
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Session")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var ratingSymbol: String {
        if progress.ratingDelta > 0 { return "arrow.up.right" }
        if progress.ratingDelta < 0 { return "arrow.down.right" }
        return "equal"
    }

    private var missedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Missed")
                .typeRole(.label, appliesForeground: false)
                // The heading is the only coloured thing here.
                .foregroundStyle(Palette.caution.dynamic)

            FlowChips(items: missed)
        }
    }
}

/// One result row.
private struct SummaryRow: View {

    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            Text(label)
                .typeRole(.body)

            Spacer(minLength: 12)

            Text(value)
                .typeRole(.body, monospacedDigits: true)
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
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.surfaceSunken.dynamic))
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
