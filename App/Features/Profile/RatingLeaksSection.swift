//
//  RatingLeaksSection.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Where the user's rating is going.
///
/// **Before changing anything here, read the rules at the top of
/// `Logic/LeakPresentation.swift`.** In particular: there is no red, the bars
/// are one hue fading by rank, and there is no chip on every row. Each of those
/// is a decision, not an omission — the section is a triage list ("this is where
/// the points are"), and every one of those additions turns it back into a
/// scolding.
///
/// ## Shape
///
/// A reading, then the evidence for it. The block on top says how much is going
/// out and whether it is going out through one hole or several; the rows below
/// rank the holes. Row geometry follows Eight Sleep's score contributors: name
/// and chip, a line of plain English saying what the cause actually is, the
/// measurement on the right, and a bar underneath whose length — never its hue —
/// carries magnitude.
struct RatingLeaksSection: View {

    let leaks: [LeakRow]
    let windowGames: Int
    let state: ProfileMeasurementState

    /// Per-cause history, keyed by cause tag raw value. Absent for a cause with
    /// too little behind it to make a shape.
    var trends: [String: LeakTrend] = [:]

    let onSelect: (LeakRow) -> Void

    /// Opens training for a cause. The section's whole argument is that the top
    /// row is worth a fortnight, and an argument with no way to act on it is an
    /// observation.
    var onTrain: (LeakRow) -> Void = { _ in }

    private var diagnosis: LeakDiagnosis? {
        LeakDiagnosis.make(rows: leaks, windowGames: windowGames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                title: "Rating leaks",
                // Only once the table is real. "Last 5 games" above a body that
                // says there are not enough games yet is the section
                // contradicting itself, on a screen whose authority rests on
                // its numbers agreeing.
                qualifier: state.isMeasured && windowGames > 0 ? "Last \(windowGames) games" : nil
            )
            .padding(.bottom, 14)

            if let message = state.message {
                MeasurementPlaceholder(message: message, symbol: "chart.bar.doc.horizontal")
                    .padding(.vertical, 4)
            } else if leaks.isEmpty {
                MeasurementPlaceholder(
                    message: "No repeated causes in this window.",
                    symbol: "checkmark.circle"
                )
                .padding(.vertical, 4)
            } else {
                if let diagnosis {
                    DiagnosisBlock(diagnosis: diagnosis)
                        .padding(.bottom, 6)
                }

                ForEach(Array(leaks.enumerated()), id: \.element.id) { index, leak in
                    if index > 0 {
                        Rectangle()
                            .fill(Palette.hairline.dynamic)
                            .frame(height: 1)
                    }
                    LeakRowView(
                        leak: leak,
                        rank: index,
                        trend: trends[leak.causeTag.rawValue],
                        onSelect: { onSelect(leak) }
                    )
                }

                trainAction
            }
        }
    }

    /// The screen's single filled button, and the only place its accent is spent
    /// on an action.
    ///
    /// Absent when the top row is noise: a filled CTA proposing a fortnight of
    /// work against 0.04 expected points a game teaches the user that the app's
    /// urgency is decorative.
    ///
    /// Also absent when the cause has no habit behind it. The handoff carries
    /// the habit and nothing else, so a habitless cause switches to the Train
    /// tab with no session opened — a filled button that silently does nothing
    /// is worse than no button, and "Train this pattern" was the copy that
    /// promised it.
    @ViewBuilder
    private var trainAction: some View {
        if let focus = leaks.first, focus.impact != .low,
           let title = LeakTable.trainActionTitle(for: focus) {
            Button {
                onTrain(focus)
            } label: {
                Text(title)
            }
            .buttonStyle(.primaryAction)
            .padding(.top, 16)
            .accessibilityHint("Opens a training set built around this habit")
        }
    }
}

// MARK: - The reading

/// The block above the table: how much, and what shape it is in.
private struct DiagnosisBlock: View {

    let diagnosis: LeakDiagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // A tier below the chart's headline on purpose: the screen has
                // one hero number and it is the rating. Two 44pt figures on one
                // scroll makes the reader choose which one the screen is about.
                DenominatorText(
                    Denominator(
                        value: diagnosis.formattedPoints,
                        denominator: LeakDiagnosis.unitDenominator
                    ),
                    role: .title
                )
                Spacer(minLength: 8)
                Text(diagnosis.shape.word)
                    .typeRole(.headline, appliesForeground: false)
                    .foregroundStyle(Palette.accent.dynamic)
            }

            Text(diagnosis.headline)
                .typeRole(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(diagnosis.explanation)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One cause

private struct LeakRowView: View {

    let leak: LeakRow
    /// Position in the table, which sets the bar's alpha and nothing else.
    let rank: Int
    let trend: LeakTrend?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(leak.title)
                                .typeRole(.headline)
                            if let chip = leak.impact.chipTitle {
                                ProfileChip(
                                    text: chip,
                                    // Amber for high, plain grey for medium.
                                    // Never red: impact says where the leverage
                                    // is, not that the user is failing.
                                    tint: leak.impact == .high
                                        ? Palette.caution.dynamic
                                        : Color.secondary
                                )
                            }
                        }

                        Text(leak.detail)
                            .typeRole(.caption)
                            .fixedSize(horizontal: false, vertical: true)

                        if let typical = leak.typicalCount {
                            // A measurement next to a reference makes a leak
                            // measurable rather than judged. Rendered only when
                            // the reference is real — see `LeakRow.typicalCount`.
                            Text("\(typical) typical at your rating")
                                .typeRole(.label, monospacedDigits: true)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(points)
                            .typeRole(.headline, monospacedDigits: true)
                        Text("\(leak.count) time\(leak.count == 1 ? "" : "s")")
                            .typeRole(.caption, monospacedDigits: true)
                    }

                    Image(systemName: "chevron.right")
                        .typeRole(.caption, appliesForeground: false)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }

                bar

                if let trend {
                    SparkBars(trend: trend)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Shows every position where this happened")
    }

    private var points: String {
        String(format: "−%.2f", leak.epLostPerGame)
    }

    private var spokenLabel: String {
        // The gloss rides along, because the row is combined into one element:
        // a VoiceOver user hears this string and never reaches the diagnosis
        // paragraph that defines the unit for everyone else.
        """
        \(leak.title). \(points) points of result a game — \(LeakDiagnosis.unitGloss) — \
        across \(leak.count) occurrences. \(leak.detail)
        """
    }

    /// Length is magnitude; alpha is rank. One hue all the way down, because a
    /// second hue would invent a severity scale nobody encoded.
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceSunken.dynamic)
                Capsule()
                    .fill(Palette.accent.dynamic.opacity(LeakTable.barOpacity(rank: rank)))
                    // Never narrower than its own cap radius, or the smallest
                    // leak renders as a dot and reads as a rendering fault.
                    .frame(
                        width: max(
                            proxy.size.width * leak.magnitude,
                            ProfileStyle.leakBarHeight
                        )
                    )
            }
        }
        .frame(height: ProfileStyle.leakBarHeight)
        .accessibilityHidden(true)
    }
}

/// The one element on this screen that can say *it is working*.
///
/// Drawn in plain grey with no trend line and no verdict: the shape falling away
/// is the whole message, and a colour on top of it would be the app claiming
/// credit for a change the user made.
private struct SparkBars: View {

    let trend: LeakTrend

    private let barWidth: CGFloat = 4
    private let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(trend.buckets.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(Palette.inactiveMark.dynamic)
                        .frame(width: barWidth, height: height(for: value))
                }
            }
            .frame(height: maxHeight, alignment: .bottom)

            Text(trend.spanLabel)
                .typeRole(.label, monospacedDigits: true)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend for this cause")
        // The shape is the whole message, so a reader who cannot see it needs
        // the direction stated. The bar heights themselves are not read out:
        // six expected-point subtotals is a list nobody can hold in their head.
        .accessibilityValue(trend.directionLabel)
    }

    private func height(for value: Double) -> CGFloat {
        guard trend.peak > 0 else { return barWidth }
        return max(barWidth, CGFloat(value / trend.peak) * maxHeight)
    }
}

// MARK: - Drill-in

/// Every position where this leak actually happened.
///
/// The chevron's promise. A leak row is an aggregate, and an aggregate the user
/// cannot open is an accusation they cannot check.
struct LeakDetailScreen: View {

    let leak: LeakRow
    let occurrences: [LeakOccurrence]
    var onTrain: () -> Void = {}

    /// Opens the review board at the exact ply. The list's whole argument is
    /// "Better: Qe2", and an assertion about a move the user cannot look at is
    /// the same accusation the aggregate above it was.
    var onOpen: (LeakOccurrence) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(
                        title: "Where it happened",
                        qualifier: occurrences.isEmpty ? nil : "\(occurrences.count)"
                    )
                    .padding(.bottom, 10)

                    if occurrences.isEmpty {
                        MeasurementPlaceholder(
                            message: "The positions for these moves are no longer stored.",
                            symbol: "tray"
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Palette.hairline.dynamic)
                                        .frame(height: 1)
                                }
                                OccurrenceRow(
                                    occurrence: occurrence,
                                    onOpen: { onOpen(occurrence) }
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                        .elevation(.raised, cornerRadius: CornerRadius.card)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle(leak.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            DenominatorText(
                Denominator(
                    value: String(format: "−%.2f", leak.epLostPerGame),
                    denominator: LeakDiagnosis.unitDenominator
                ),
                role: .display
            )

            // This screen is reachable without passing the diagnosis block, so
            // it cannot borrow that paragraph's definition of the unit. The one
            // sentence is cheaper than a reader who takes "−0.42" for rating
            // points and concludes the habit is trivial.
            Text(LeakDiagnosis.unitSentence)
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            // `LeakTable.detail` is two clauses: what happened, then the
            // question that catches it next time. The second clause is the
            // reason this screen is allowed to list refutations at all — a
            // verdict with no method is the accusation the section exists to
            // avoid — so it must not be trimmed to fit.
            Text(leak.detail)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Same rule as the section's own button: the handoff carries the
            // habit, so a cause with none behind it would switch tabs and open
            // nothing.
            if let title = LeakTable.trainActionTitle(for: leak) {
                Button {
                    onTrain()
                } label: {
                    Text(title)
                }
                .buttonStyle(.primaryAction)
                .padding(.top, 4)
                .accessibilityHint("Opens a training set built around this habit")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}

/// One position where the leak happened, and the way into it.
///
/// The row asserts a refutation — "Better: Qe2" — in four characters of
/// notation. Read on its own that is the app claiming a move was wrong and
/// declining to show why, which is the shape of thing this whole screen is
/// built to avoid. The moment ID is already stored beside the ply, so the board
/// with its explanation is one tap away and there is no reason not to offer it.
private struct OccurrenceRow: View {

    let occurrence: LeakOccurrence
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Move \(occurrence.moveNumber): \(occurrence.playedSAN)")
                        .typeRole(.body, monospacedDigits: true)
                    // Only where there is a move to name. `bestSAN` is written
                    // by the analysis pass and can be empty — a moment stored
                    // before the engine returned a line, or by a build that did
                    // not record one — and "Better:" followed by nothing is the
                    // app asserting a refutation it does not have.
                    if !occurrence.bestSAN.isEmpty {
                        Text("Better: \(occurrence.bestSAN)")
                            .typeRole(.caption, monospacedDigits: true)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "−%.2f", occurrence.epLost))
                        .typeRole(.body, monospacedDigits: true, appliesForeground: false)
                        .foregroundStyle(.secondary)
                    Text(occurrence.playedAt.formatted(.dateTime.day().month(.abbreviated)))
                        .typeRole(.label, monospacedDigits: true)
                }

                Image(systemName: "chevron.right")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the board at this move")
    }
}
