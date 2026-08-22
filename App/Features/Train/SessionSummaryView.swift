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

    /// What the filled button actually does next.
    ///
    /// The button used to say `Continue`, which named neither destination. In
    /// the endgame case it was worse than vague: dismissing the set handed a
    /// twenty-move drill to the Train screen, which opened it as a second
    /// full-screen board the user had not been told about.
    enum NextStep: Equatable {
        case backToTrain
        case drill(title: String, positions: Int, moveBudget: Int)
    }

    let progress: SessionProgress
    let missed: [MissedItem]
    var nextStep: NextStep = .backToTrain
    /// Whether this was the calculation set. Only ``ratingNote`` cares, and it
    /// cares a great deal: the reason a daily set's rating can end flat is not
    /// the reason a calculation set's can.
    var isCalculationSet = false
    let onContinue: () -> Void
    /// Leaves without the drill. Nil when there is nothing to defer.
    var onDefer: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 0) {
                    SummaryRow(symbol: "checkmark.circle", label: "Solved", value: progress.solvedLabel)
                    Divider().padding(.leading, 34)
                    // Only when something actually came back. A permanent
                    // `0/0 clean` row would be four-fifths of a scoreboard
                    // about nothing.
                    if let retries = progress.retriesLabel {
                        SummaryRow(symbol: "arrow.counterclockwise", label: "Second looks", value: retries)
                        Divider().padding(.leading, 34)
                    }
                    SummaryRow(symbol: "lightbulb", label: "Hints", value: progress.hintsLabel)
                    Divider().padding(.leading, 34)
                    SummaryRow(symbol: "clock", label: "Time", value: progress.timeLabel)
                    Divider().padding(.leading, 34)
                    SummaryRow(
                        symbol: ratingSymbol,
                        label: "Puzzle rating",
                        value: isRatingSettled ? progress.ratingLabel : "settling"
                    )
                }
                .padding(.horizontal, 16)
                .elevation(.raised, cornerRadius: CornerRadius.card)

                // Not the game rating the user is chasing, and the two are easy
                // to confuse when the row says only "Rating". A zero is worth a
                // sentence too: a set of reviews counts half and a position
                // mined from the user's own game carries no rating at all, so
                // "0" after ten honest puzzles otherwise reads as "none of that
                // counted".
                if let note = ratingNote {
                    Text(note)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button(continueTitle, action: onContinue)
                        .buttonStyle(.primaryAction)

                    if let onDefer {
                        Button("Not now", action: onDefer)
                            .buttonStyle(.secondaryAction)
                    }
                }

                if !missed.isEmpty {
                    missedSection
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Set done")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var continueTitle: String {
        switch nextStep {
        case .backToTrain:
            return "Back to Train"
        case let .drill(title, positions, budget):
            let count = positions == 1 ? "1 position" : "\(positions) positions"
            return "Play the \(title) drill · \(count), up to \(budget) moves"
        }
    }

    /// Below this the rating is settled enough for a session's change to mean
    /// something.
    ///
    /// Glicko's deviation is the app's own uncertainty about the number, in the
    /// same units. A new user starts at 350, where a single set can move the
    /// rating a hundred points in either direction for reasons that have
    /// nothing to do with how they played — so a signed `+12` there is noise
    /// dressed as progress, and reading it as progress is exactly the habit a
    /// rating row teaches. Around 150 the swings are small enough that the sign
    /// is evidence.
    static let settledDeviation = 150.0

    private var isRatingSettled: Bool { progress.ratingDeviation < Self.settledDeviation }

    private var ratingSymbol: String {
        guard isRatingSettled else { return "hourglass" }
        if progress.ratingDelta > 0 { return "arrow.up.right" }
        if progress.ratingDelta < 0 { return "arrow.down.right" }
        return "equal"
    }

    /// The sentence under the rows, when the number needs one.
    private var ratingNote: String? {
        if !isRatingSettled {
            return "Your puzzle rating is still finding its level. A few more sets and a session's change will mean something."
        }
        guard progress.ratingDelta == 0 else { return nil }
        // The daily set's explanation is the half-weight one, and it is simply
        // untrue of a calculation set: every item in it is a full-weight fresh
        // corpus puzzle. What flattens the number there is the expected score —
        // Glicko already knows a puzzle 200 points above you is one you will
        // usually miss, so missing it costs almost nothing. That is worth saying
        // outright, because it is the reason attempting them is safe.
        if isCalculationSet {
            return "Puzzle rating unchanged — missing a puzzle rated above you costs almost nothing, "
                + "which is what makes these safe to attempt."
        }
        return "Puzzle rating unchanged — reviews and positions from your own games count less."
    }

    private var missedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Missed")
                .typeRole(.label, appliesForeground: false)
                // The heading is the only coloured thing here.
                .foregroundStyle(Palette.caution.dynamic)

            FlowChips(items: missed)

            // A list of pattern names is a list of things to look up. The one
            // that came up most is worth defining here, in the same
            // name-and-define breath the result banner uses, so the summary
            // leaves the reader with an idea rather than a scoreboard.
            if let lesson = recurringLesson {
                Text(lesson)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The most-missed concept, defined.
    ///
    /// Only when it came up more than once — one miss is a puzzle, two is a
    /// pattern — and only where the concept has a definition worth giving:
    /// `rook endgame` is a kind of position rather than an idea, and glossing
    /// it would be filler. No advice is invented on top of the definition;
    /// how to *find* a pin and how to find a back-rank mate are different
    /// instructions, and one sentence that covers both covers neither.
    private var recurringLesson: String? {
        let counts = missed.reduce(into: [String: Int]()) { $0[$1.concept, default: 0] += 1 }
        guard let worst = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), worst.value > 1,
            let definition = PuzzleConcept.definition(for: worst.key)
        else { return nil }
        let name = worst.key.prefix(1).uppercased() + worst.key.dropFirst()
        return "\(name) came up \(worst.value) times — \(definition)."
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
