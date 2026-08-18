//
//  ProfileSnapshot.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// Everything the Profile screen draws, as one immutable value.
///
/// The screen reads three unrelated stores (metrics, games, moments) and one
/// pure domain function per section. Assembling them into a single value off
/// the main actor — rather than letting each section fetch for itself — is what
/// keeps the screen from rendering a rating from one instant next to a leak
/// table from another.
struct ProfileSnapshot: Sendable, Hashable {

    var currentRung: Int

    /// Every point the data layer has, per metric, unwindowed. The chart
    /// windows them; keeping the full history here means changing the time
    /// range is free rather than another round trip to SQLite.
    var series: [ProfileChartMetric: [ProfileSeriesPoint]]

    var ladder: CurriculumLadderState

    /// Sorted by expected points lost, descending. The ordering is the message.
    var leaks: [LeakRow]

    /// Games the leak table actually rests on, for the `Last 23 games` label.
    var leakWindowGames: Int

    /// Whether there is enough play behind the leak table to show it at all.
    var leakState: ProfileMeasurementState

    /// Occurrences keyed by ``CauseTag`` raw value, for the drill-in.
    var occurrences: [String: [LeakOccurrence]]

    var generatedAt: Date

    func points(for metric: ProfileChartMetric) -> [ProfileSeriesPoint] {
        series[metric] ?? []
    }

    func occurrences(for tag: CauseTag) -> [LeakOccurrence] {
        (occurrences[tag.rawValue] ?? []).sorted { $0.playedAt > $1.playedAt }
    }

    /// Assembles the screen from the curriculum layer's output and the chart
    /// data, both of which are read rather than recomputed here.
    ///
    /// Every argument is a `TrainingCore` value, which is what keeps this
    /// assembler — and therefore the whole screen's shape — testable without a
    /// database, a service or a view.
    static func make(
        currentRung: Int,
        metrics: MetricSnapshot,
        blockers: [AdvancementBlocker],
        leaks: [Leak],
        series: [ProfileChartMetric: [ProfileSeriesPoint]],
        occurrences: [String: [LeakOccurrence]],
        leakWindowGames: Int,
        gamesAvailable: Int,
        ladder: [Rung] = Curriculum.default,
        tuning: DomainTuning.Focus = DomainTuning.default.focus,
        now: Date = Date()
    ) -> ProfileSnapshot {
        ProfileSnapshot(
            currentRung: currentRung,
            series: series,
            ladder: CurriculumLadderState(
                ladder: ladder,
                currentRung: currentRung,
                metrics: metrics,
                blockers: blockers
            ),
            leaks: LeakTable.rows(from: leaks),
            leakWindowGames: leakWindowGames,
            // Below the analyser's minimum the per-cause numbers are noise, so
            // the section says how many more games it needs instead of ranking
            // three data points as if they were a diagnosis.
            leakState: .forSamples(have: gamesAvailable, need: tuning.leakMinimumGames),
            occurrences: occurrences,
            generatedAt: now
        )
    }

    /// The state before anything has loaded, and after a failed load: an honest
    /// ladder with nothing measured, rather than a spinner that never resolves.
    static func empty(
        ladder: [Rung] = Curriculum.default,
        currentRung: Int = 1,
        now: Date = Date()
    ) -> ProfileSnapshot {
        ProfileSnapshot(
            currentRung: currentRung,
            series: [:],
            ladder: CurriculumLadderState(
                ladder: ladder,
                currentRung: currentRung,
                metrics: MetricSnapshot(),
                blockers: []
            ),
            leaks: [],
            leakWindowGames: 0,
            leakState: .nothingYet(noun: "games"),
            occurrences: [:],
            generatedAt: now
        )
    }
}
