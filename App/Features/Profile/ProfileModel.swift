//
//  ProfileModel.swift
//  ChessCoach
//

import Foundation
import Observation
import TrainingCore

/// View state for the Profile screen.
///
/// Holds one immutable ``ProfileSnapshot`` plus the three things the user can
/// change without touching the database — which metric, which time window, and
/// which rung is open. Re-windowing the chart is therefore a pure recomputation
/// over data already in memory, not another SQLite read.
@Observable
@MainActor
final class ProfileModel {

    private(set) var snapshot: ProfileSnapshot = .empty()
    private(set) var isLoading = false

    /// Non-`nil` when the load failed. Surfaced as a line of text rather than an
    /// alert: a profile that cannot load is not an emergency, and an alert
    /// blocks the user out of a screen that still has a usable ladder on it.
    private(set) var loadError: String?

    var metric: ProfileChartMetric = .rating {
        didSet { if metric != oldValue { rangeOffset = 0 } }
    }

    /// Opens on one month rather than three.
    ///
    /// Three months is the right *habit* window and the wrong *opening* one. A
    /// new account has a few days of history, so a 91-day axis renders about
    /// four points crushed against the right edge of an otherwise empty card —
    /// which reads as a broken chart, not as an early one, and it is the first
    /// thing on the screen. Thirty days is still long enough to show a trend
    /// and short enough that a first week fills a usable share of it. The wider
    /// windows are one tap away and remain the right answer later.
    var range: ProfileTimeRange = .oneMonth {
        didSet { if range != oldValue { rangeOffset = 0 } }
    }

    /// Whole windows back from now. 0 is the current window.
    private(set) var rangeOffset = 0

    private let loader: ProfileDataLoader?

    /// The curriculum half of the screen — metric snapshot, advancement
    /// decision, leak table — comes from here rather than being recomputed.
    /// Two implementations of "how many blunders per 100 moves" would eventually
    /// disagree, and the one on the Profile screen would be the wrong one.
    private let metricsService: MetricsService?

    private let ladder: [Rung]

    init(
        loader: ProfileDataLoader? = ProfileDataLoader.shared,
        metricsService: MetricsService? = ProfileModel.defaultMetricsService(),
        ladder: [Rung] = Curriculum.default
    ) {
        self.loader = loader
        self.metricsService = metricsService
        self.ladder = ladder
    }

    /// Preview/test seam: a model with a fixed snapshot and no database.
    init(snapshot: ProfileSnapshot) {
        self.loader = nil
        self.metricsService = nil
        self.ladder = Curriculum.default
        self.snapshot = snapshot
    }

    static func defaultMetricsService() -> MetricsService? {
        guard let database = AppDatabase.sharedIfAvailable else { return nil }
        return MetricsService(
            games: database.games,
            moments: database.moments,
            metrics: database.metrics,
            settings: database.settings
        )
    }

    // MARK: - Derived

    var series: ProfileChartSeries {
        ProfileChartSeries.make(
            from: snapshot.points(for: metric),
            range: range,
            offset: rangeOffset,
            now: snapshot.generatedAt
        )
    }

    /// Whether the chart has enough plotted points to be worth drawing.
    var seriesState: ProfileMeasurementState {
        .forSeries(pointCount: series.points.count, noun: metric.pointNoun)
    }

    /// The sentence under the headline number, saying what the chart means.
    ///
    /// `nil` when there is not enough plotted to say anything true, in which
    /// case the card shows its measurement placeholder instead.
    var interpretation: String? {
        ProfileNarrative.interpretation(for: series, metric: metric, range: range)
    }

    /// Stands in for the interpretation while the series is too young to carry
    /// one, so the card never shows an empty space where a sentence belongs.
    var interpretationPlaceholder: String? {
        guard interpretation == nil else { return nil }
        return ProfileNarrative.pendingNote(for: series, metric: metric)
    }

    /// Per-cause history for the leak sparklines, keyed by cause tag raw value.
    ///
    /// A fold over the occurrences already in memory rather than another read:
    /// the snapshot holds every occurrence behind the table, and bucketing a few
    /// hundred dates is cheaper than the round trip that would avoid it.
    var leakTrends: [String: LeakTrend] {
        var trends: [String: LeakTrend] = [:]
        for (tag, occurrences) in snapshot.occurrences {
            trends[tag] = LeakTrend.make(from: occurrences, now: snapshot.generatedAt)
        }
        return trends
    }

    /// Stepping back is only offered while there is older data to reach.
    var canStepBack: Bool {
        guard let earliest = snapshot.points(for: metric).map(\.date).min() else { return false }
        return earliest < series.interval.start
    }

    var canStepForward: Bool { rangeOffset > 0 }

    // MARK: - Intents

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Recompute first, then read: the ladder and the leak table must
        // describe the same instant as the numbers behind them.
        await metricsService?.refresh()

        let now = Date()
        let chart: ProfileChartData
        do {
            chart = try await loader?.load(now: now) ?? .empty
            loadError = metricsService?.lastError
        } catch {
            chart = .empty
            loadError = String(describing: error)
        }

        // A pull-to-refresh must not close the section the user just opened —
        // but a *first* load must still open on the rung they are actually on,
        // so only a deliberate toggle is preserved.
        let openRung = hasToggledRung ? snapshot.ladder.expandedRungID : nil

        guard let curriculum = metricsService?.state else {
            // Nothing measured yet, or the service failed. An honest ladder
            // beats a spinner that never resolves.
            snapshot = .empty(ladder: ladder, now: now)
            return
        }

        snapshot = ProfileSnapshot.make(
            currentRung: curriculum.rung,
            metrics: curriculum.snapshot,
            blockers: curriculum.decision.blockers,
            leaks: curriculum.leaks,
            series: chart.series,
            occurrences: chart.occurrences,
            leakWindowGames: chart.leakWindowGames,
            gamesAvailable: chart.gamesAvailable,
            ladder: ladder,
            now: now
        )
        if let openRung, openRung != snapshot.ladder.expandedRungID {
            snapshot.ladder.toggle(openRung)
        }
    }

    /// `+1` walks back in time, `-1` forward. Clamped at both ends so the
    /// steppers can never park the chart on an empty window.
    func step(_ delta: Int) {
        let next = rangeOffset + delta
        guard next >= 0 else { return }
        if delta > 0 && !canStepBack { return }
        rangeOffset = next
    }

    func toggleRung(_ rungID: Int) {
        hasToggledRung = true
        snapshot.ladder.toggle(rungID)
    }

    /// Whether the user has opened or closed a section themselves.
    private var hasToggledRung = false
}
