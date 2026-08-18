//
//  RatingLeaksSection.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Where the user's rating is going.
///
/// **Before changing anything here, read the rules at the top of
/// `Logic/LeakPresentation.swift`.** In particular: there are no bars, there is
/// no red, and there is no chip on every row. Each of those is a decision, not
/// an omission — the section is a triage list ("this is where the points are"),
/// and every one of those three additions turns it back into a scolding.
///
/// Row geometry follows Oura's Contributors list: name and chip on the first
/// line, the measurement on the second, a chevron on the right, and a hairline
/// rule beneath whose *width* — never its colour — carries magnitude.
struct RatingLeaksSection: View {

    let leaks: [LeakRow]
    let windowGames: Int
    let state: ProfileMeasurementState
    let onSelect: (LeakRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rating leaks")
                    .font(.headline)
                Spacer()
                if windowGames > 0 {
                    Text("Last \(windowGames) games")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

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
                ForEach(Array(leaks.enumerated()), id: \.element.id) { index, leak in
                    LeakRowView(
                        leak: leak,
                        // The unit is spelled out once, on the top row, and
                        // abbreviated below it. Repeating "expected points per
                        // game" five times turns the column into wallpaper.
                        spellOutUnit: index == 0,
                        onSelect: { onSelect(leak) }
                    )
                }
            }
        }
    }
}

private struct LeakRowView: View {

    let leak: LeakRow
    let spellOutUnit: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(leak.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let chip = leak.impact.chipTitle {
                        ProfileChip(
                            text: chip,
                            // Amber for high, plain grey for medium. Never red:
                            // impact says where the leverage is, not that the
                            // user is failing.
                            tint: leak.impact == .high ? ProfileStyle.impactAmber : .secondary
                        )
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(measurement)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                if let typical = leak.typicalCount {
                    // Superpower's markers grid: a measurement next to a
                    // reference makes a leak measurable rather than judged.
                    // Rendered only when the reference is real — see
                    // `LeakRow.typicalCount`.
                    Text("\(typical) typical at your rating")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                hairline
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var measurement: String {
        let points = String(format: "%.2f", leak.epLostPerGame)
        let occurrences = "\(leak.count) occurrence\(leak.count == 1 ? "" : "s")"
        return spellOutUnit
            ? "−\(points) expected points per game · \(occurrences)"
            : "−\(points) · \(occurrences)"
    }

    /// The one permitted visual encoding: 2pt, one desaturated colour, width
    /// proportional to magnitude. A full-width saturated bar would read as an
    /// alarm and would encode nothing the ordering does not already carry.
    private var hairline: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                Rectangle()
                    .fill(ProfileStyle.hairline)
                    .frame(width: proxy.size.width * leak.magnitude, height: 2)
            }
            .frame(height: 2, alignment: .center)
        }
        .frame(height: 2)
        .padding(.top, 3)
    }
}

/// The drill-in: every position where this leak actually happened.
///
/// The chevron's promise. A leak row is an aggregate, and an aggregate the user
/// cannot open is an accusation they cannot check.
struct LeakDetailScreen: View {

    let leak: LeakRow
    let occurrences: [LeakOccurrence]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "−%.2f expected points per game", leak.epLostPerGame))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("\(leak.count) occurrence\(leak.count == 1 ? "" : "s") in this window")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let habit = leak.habit {
                        // Names the fix, not the failure.
                        Text(habit.microGoalTitle)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.quaternary))
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Where it happened") {
                if occurrences.isEmpty {
                    Text("The positions for these moves are no longer stored.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(occurrences) { occurrence in
                        OccurrenceRow(occurrence: occurrence)
                    }
                }
            }
        }
        .navigationTitle(leak.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct OccurrenceRow: View {

    let occurrence: LeakOccurrence

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Move \(occurrence.moveNumber): \(occurrence.playedSAN)")
                    .font(.subheadline.monospacedDigit())
                Text("Better: \(occurrence.bestSAN)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "−%.2f", occurrence.epLost))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(occurrence.playedAt.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
