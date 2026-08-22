//
//  TrainingListScreen.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Everything the sets have covered, and everything still to come.
///
/// ## Why this is not the drill grid again
///
/// The grid that used to live on the Train tab asked "what do you want to
/// practise", which is the question the user is least equipped to answer. This
/// asks nothing. It is a record of ground covered, in the order the app covers
/// it, and the only thing it lets you *do* is go back over something already
/// taught — a different decision from choosing what comes next, and a reasonable
/// one to leave with the reader, since it is also the only way to see a lesson a
/// second time.
///
/// ## Why the focus picker is not here either
///
/// It offered nine habits and asked the user to pick the one they were worst at
/// — precisely the judgement someone on their way to 2000 does not yet have, and
/// the reason they are here. Choosing it wrong spends a whole week's sessions
/// rehearsing something that was already fine. The app computes the week's focus
/// from the user's own leaks and is better at it than they are, so the choice is
/// not offered: what is worth practising is not a preference.
///
/// ## Why it is off the daily surface
///
/// Eighteen rows and growing. Home is the day's work; this is the shelf behind
/// it, reached from Practice more and never in the way of the plan.
struct TrainingListScreen: View {

    @Environment(AppModel.self) private var model
    @State private var home = TrainHomeModel()
    @State private var route: TrainRoute?
    /// Held separately from `route` because the drill is offered *after* the
    /// concept cover closes; one binding cannot present its successor.
    @State private var drillRoute: TrainRoute?
    @State private var pendingDrill: EndgameDrillKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Each set teaches one idea before its puzzles. Tap one to read it again.")
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                // Grouped by family rather than run together as one column.
                // "Openings, endgames, positional ideas" is how the user thinks
                // about what they train, and the grouping makes the rotation
                // legible without promising a set from each family every day —
                // the scheduler still serves exactly one concept per set.
                ForEach(families, id: \.family) { group in
                    familySection(group.family, rows: group.rows)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Your training")
        .task { await home.load() }
        .trainingCover(item: $route) { route in
            if case let .concept(concept) = route, let service = home.makeTrainingService() {
                NavigationStack {
                    // The same drill handoff the daily set does. Without it,
                    // revisiting an endgame technique showed the lesson, said
                    // "Got it", and practised nothing — the one thing the row
                    // advertises.
                    PuzzleSessionScreen(
                        model: PuzzleSessionModel(
                            driver: service,
                            evaluator: EnginePuzzleEvaluator(service: model.engineService),
                            soloConcept: concept
                        )
                    ) { kind in pendingDrill = kind }
                }
            }
        }
        .trainingCover(item: $drillRoute) { route in
            if case let .drill(kind) = route {
                NavigationStack {
                    EndgameDrillScreen(
                        model: EndgameDrillModel(
                            kind: kind,
                            opponent: EngineDrillOpponent(engine: model.engineService),
                            recorder: home.makeTrainingService()
                        )
                    )
                }
            }
        }
        .onChange(of: pendingDrill) { _, kind in
            guard let kind else { return }
            pendingDrill = nil
            drillRoute = .drill(kind)
        }
        .onChange(of: route) { _, newValue in
            guard newValue == nil else { return }
            Task { await home.load() }
        }
    }

    /// The catalogue split by family, computed outside the view builder.
    ///
    /// SwiftUI's result builder cannot type-check the grouping inline in any
    /// reasonable time; a plain array of pairs is the same data and compiles.
    private var families: [(family: TrainingConcept.Family, rows: [TrainHomeModel.CoveredConcept])] {
        TrainingConcept.Family.allCases.compactMap { family in
            let rows = home.covered.filter { $0.concept.family == family }
            return rows.isEmpty ? nil : (family: family, rows: rows)
        }
    }

    private func familySection(_ family: TrainingConcept.Family, rows: [TrainHomeModel.CoveredConcept]) -> some View {
        let taught = rows.filter(\.isTaught)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: familyTitle(family),
                qualifier: "\(taught.count) of \(rows.count)"
            )

            VStack(spacing: 0) {
                ForEach(Array(taught.enumerated()), id: \.element.id) { row in
                    if row.offset > 0 { Divider().padding(.leading, 44) }
                    CoveredConceptRow(row: row.element) {
                        route = .concept(row.element.concept)
                    }
                }

                let untaught = rows.filter { !$0.isTaught }
                if !untaught.isEmpty {
                    if !taught.isEmpty { Divider().padding(.leading, 44) }
                    upcomingRow(untaught, family: family)
                }
            }
            .padding(.horizontal, 16)
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
    }

    private func familyTitle(_ family: TrainingConcept.Family) -> String {
        switch family {
        case .opening: "Opening lines"
        case .endgame: "Endgames"
        case .positional: "Positional ideas"
        }
    }

    /// What is still to come in one family, split by whether it can actually
    /// arrive next or is waiting on rating.
    ///
    /// A locked concept is not queued behind the others — it is not in
    /// `TrainingConcept.available(atRating:)` at all, so no amount of playing
    /// sets brings it closer. Only the rating does, and the row says which.
    private func upcomingRow(_ rows: [TrainHomeModel.CoveredConcept], family: TrainingConcept.Family) -> some View {
        let next = rows.filter(\.isUnlocked)
        let tiers = Dictionary(grouping: rows.filter { !$0.isUnlocked }, by: \.concept.fromRating)
            .sorted { $0.key < $1.key }

        // A positional title is very nearly its own solution — being told "the
        // outpost" is coming hands over most of the exercise. An opening and an
        // endgame are named techniques where the name is the thing being
        // learned, so those are named and positional ideas are counted.
        let nameable = family != .positional

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceSunken.dynamic)
                    .frame(width: 32, height: 32)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if next.isEmpty {
                    Text("Nothing new here until your rating goes up")
                        .typeRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else if nameable {
                    Text(next.map(\.concept.title).joined(separator: ", "))
                        .typeRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(next.count == 1 ? "1 more, revealed with its lesson" : "\(next.count) more, each revealed with its lesson")
                        .typeRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(tiers, id: \.key) { tier in
                    Text(
                        nameable
                            ? "\(tier.key)+ · \(tier.value.map(\.concept.title).joined(separator: ", "))"
                            : "\(tier.key)+ · \(tier.value.count) more"
                    )
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Covered concept row

/// One line of the training list: what it is, whether it has been taught, and
/// how the exercises have gone.
private struct CoveredConceptRow: View {

    let row: TrainHomeModel.CoveredConcept
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                marker

                VStack(alignment: .leading, spacing: 2) {
                    // An untaught concept is named only by its family. The
                    // title of a positional idea is most of the answer to its
                    // own exercise.
                    Text(row.isTaught ? row.concept.title : "\(row.concept.family.label) — not yet")
                        .typeRole(.body, appliesForeground: false)
                        .foregroundStyle(row.isTaught ? .primary : .secondary)
                        .multilineTextAlignment(.leading)

                    if row.isTaught {
                        Text(row.record.map { "\(row.concept.family.label) · \($0)" }
                            ?? row.concept.family.label)
                            .typeRole(.caption)
                    }
                }

                Spacer(minLength: 0)

                if row.isTaught {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isTaught)
        .accessibilityLabel(
            row.isTaught
                ? "\(row.concept.title), \(row.concept.family.label). Practise again."
                : "\(row.concept.family.label), not covered yet"
        )
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(row.isTaught ? Palette.accentWash.dynamic : Palette.surfaceSunken.dynamic)
                .frame(width: 32, height: 32)
            Image(systemName: row.isTaught ? "checkmark" : "lock.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(row.isTaught ? Palette.accent.dynamic : Color.secondary)
        }
    }
}