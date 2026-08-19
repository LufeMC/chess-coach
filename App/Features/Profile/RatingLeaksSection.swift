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
                qualifier: windowGames > 0 ? "Last \(windowGames) games" : nil
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
    @ViewBuilder
    private var trainAction: some View {
        if let focus = leaks.first, focus.impact != .low {
            Button {
                onTrain(focus)
            } label: {
                Text(LeakTable.trainActionTitle(for: focus))
            }
            .buttonStyle(.primaryAction)
            .padding(.top, 16)
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
                    Denominator(value: diagnosis.formattedPoints, denominator: "pts / game"),
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
        "\(leak.title). \(points) expected points per game across \(leak.count) occurrences. \(leak.detail)"
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
        .accessibilityLabel("Last \(trend.spanLabel)")
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
                                OccurrenceRow(occurrence: occurrence)
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
                    denominator: "pts / game"
                ),
                role: .display
            )

            Text(leak.detail)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onTrain()
            } label: {
                Text(LeakTable.trainActionTitle(for: leak))
            }
            .buttonStyle(.primaryAction)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}

private struct OccurrenceRow: View {

    let occurrence: LeakOccurrence

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Move \(occurrence.moveNumber): \(occurrence.playedSAN)")
                    .typeRole(.body, monospacedDigits: true)
                Text("Better: \(occurrence.bestSAN)")
                    .typeRole(.caption, monospacedDigits: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "−%.2f", occurrence.epLost))
                    .typeRole(.body, monospacedDigits: true, appliesForeground: false)
                    .foregroundStyle(.secondary)
                Text(occurrence.playedAt.formatted(.dateTime.day().month(.abbreviated)))
                    .typeRole(.label, monospacedDigits: true)
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
