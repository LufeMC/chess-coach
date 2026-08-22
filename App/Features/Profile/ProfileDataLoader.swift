//
//  ProfileDataLoader.swift
//  ChessCoach
//

import Database
import Foundation
import TrainingCore

/// The half of the Profile screen's data that `MetricsService` does not produce.
///
/// `MetricsService` owns the curriculum half — the metric snapshot, the
/// advancement decision, and the leak table — and this type deliberately does
/// **not** duplicate any of it. What it adds is the chart's history and the
/// per-occurrence detail behind a leak row's chevron, both of which are plain
/// reads.
struct ProfileChartData: Sendable {

    var series: [ProfileChartMetric: [ProfileSeriesPoint]]

    /// Occurrences keyed by `Moment.causeTag` raw value.
    var occurrences: [String: [LeakOccurrence]]

    /// Games the leak table actually rests on, for the `Last 23 games` label.
    var leakWindowGames: Int

    /// Analysed games available at all, for the leak section's empty state.
    var gamesAvailable: Int

    /// The start of the oldest game ``occurrences`` were read from, and
    /// therefore the earliest moment any of them could have happened.
    ///
    /// Carried because the sparklines need to know how far back the app
    /// actually looked. Without it they assume a fixed ninety days, and a leak
    /// read from twenty games of daily play draws four empty buckets followed
    /// by two full ones — a habit that looks like it is getting rapidly worse
    /// when nothing about it changed at all. `nil` when there is nothing to
    /// look at.
    var occurrenceWindowStart: Date?

    static let empty = ProfileChartData(
        series: [:], occurrences: [:], leakWindowGames: 0, gamesAvailable: 0
    )
}

/// Reads the Profile screen's chart history and leak detail off the main actor.
///
/// An actor for the same reason `GamePersistence` is one: the repositories are
/// synchronous `Sendable` structs (GRDB serialises access itself), so this type
/// exists purely to give `@MainActor` views somewhere to `await` that is not the
/// UI thread. Twenty `moments(forGame:)` reads is a handful of dropped frames
/// if it happens on the main actor.
///
/// It computes no metrics. Every number it returns is stored.
actor ProfileDataLoader {

    /// How far back the accuracy series looks.
    ///
    /// The longest chart range is a year; four hundred games is more than a
    /// year of daily play, and the rows are tiny.
    static let historyGameLimit = 400

    /// How many stored observations of one metric the chart reads.
    ///
    /// The coalescing in `MetricsRepository.recordSample` caps a metric at
    /// roughly one row per day its value stood still plus one per time it
    /// moved, so this is a decade of daily play. The cap counts back from the
    /// newest, so a user who somehow passed it would lose the distant past
    /// rather than this week.
    static let historySampleLimit = 4_000

    private let history: any MetricHistoryStore
    private let games: any GameStore
    private let moments: any MomentStore
    private let ladder: [Rung]
    private let tuning: DomainTuning

    init(
        history: any MetricHistoryStore,
        games: any GameStore,
        moments: any MomentStore,
        ladder: [Rung] = Curriculum.default,
        tuning: DomainTuning = .default
    ) {
        self.history = history
        self.games = games
        self.moments = moments
        self.ladder = ladder
        self.tuning = tuning
    }

    /// The shared loader, or `nil` when the database could not be opened.
    static let shared: ProfileDataLoader? = AppDatabase.sharedIfAvailable.map {
        ProfileDataLoader(history: $0.metrics, games: $0.games, moments: $0.moments)
    }

    func load(now: Date = Date()) throws -> ProfileChartData {
        let recent = try games.recent(limit: Self.historyGameLimit)
        let rating = try samples(of: .ladderRating)
        let puzzle = try samples(of: .puzzleRating)
        let puzzleDeviation = try samples(of: .puzzleRatingDeviation)

        // The leak half looks at exactly the games `MetricsService` fed to
        // `LeakAnalyzer`, so the `Last N games` label and the numbers under it
        // describe the same sample. Reading a different slice here would put a
        // truthful-looking label on a table it does not describe.
        //
        // "Exactly" is load-bearing and was not true before: this filtered on
        // `endedAt != nil` while `MetricsService` filters on `analysis ==
        // .complete`, and the two differ for every game that has finished but
        // not yet been analysed — which, since the queue drains in the
        // background, is most often the game the user just played. The label
        // counted it and the rows could not.
        //
        // Both bounds are mirrored, not just the filter. `MetricsService` looks
        // no further back than three windows of raw history before filtering,
        // so a user with a long analysis backlog gets a deliberately smaller
        // sample there — and a loader that kept digging until it found twenty
        // analysed games would label that smaller table with a bigger number.
        // See `MetricsService.recompute` for the four lines this mirrors.
        let horizon = MetricsService.maximumWindowGames(in: ladder)
        let leakHorizon = Array(
            recent
                .prefix(horizon * MetricsService.unanalysedGameAllowance)
                .filter { $0.analysis == .complete }
                .prefix(horizon)
        )

        var occurrences: [String: [LeakOccurrence]] = [:]
        for game in leakHorizon {
            // `startedAt`, like `MetricsService`, and not `endedAt`: the window
            // label, the bucketing behind the sparkline and the dates on the
            // occurrence rows all have to be on one clock, or a game that began
            // one side of a cutoff and ended the other is counted by one of
            // them and not the others.
            let playedAt = game.startedAt
            for moment in try moments.moments(forGame: game.id) {
                occurrences[moment.causeTag, default: []].append(
                    LeakOccurrence(
                        id: moment.id,
                        gameID: game.id,
                        playedAt: playedAt,
                        ply: moment.ply,
                        playedSAN: moment.playedSAN,
                        bestSAN: moment.bestSAN,
                        // Stored as a signed loss; the table speaks in
                        // magnitudes and renders the sign itself.
                        epLost: abs(moment.deltaEP),
                        opponentRating: game.opponentRating,
                        result: game.result
                    )
                )
            }
        }

        let gameRecords = leakHorizon.map {
            TrainingCore.GameRecord(id: $0.id.uuidString, playedAt: $0.startedAt)
        }

        return ProfileChartData(
            series: Self.series(
                rating: rating,
                puzzle: puzzle,
                puzzleDeviation: puzzleDeviation,
                games: recent
            ),
            occurrences: occurrences,
            leakWindowGames: LeakTable.windowSize(games: gameRecords, now: now, tuning: tuning.focus),
            gamesAvailable: leakHorizon.count,
            // The oldest game in the horizon, not the oldest occurrence: the
            // sparkline's span is how far back the app *looked*, so an empty
            // stretch at the left of it means "we looked and found nothing",
            // which is the improvement the sparkline exists to show.
            occurrenceWindowStart: leakHorizon.last?.startedAt
        )
    }

    // MARK: - Chart series

    /// Every stored observation of one metric, oldest first.
    private func samples(of key: MetricKey) throws -> [MetricSample] {
        try history.samples(
            key: key.rawValue,
            window: MetricWindow.allTime.key,
            limit: Self.historySampleLimit
        )
    }

    /// Builds the three plotted series from stored values only.
    ///
    /// * **Accuracy** is a genuine per-game time series already: `userAccuracy`
    ///   is written by the analysis pipeline and stamped with the game's end
    ///   time, so it needs no history table.
    /// * **Rating** and **Puzzles** come from `metricSamples`, the append-only
    ///   history `MetricsService` writes. They used to be read off `skillMetrics`
    ///   instead, which holds one row per `(key, window)` — a *current value*,
    ///   not a series — so the chart could only ever render its empty state, on
    ///   real data, permanently.
    ///
    /// Nothing here fabricates intermediate points, and nothing re-derives a
    /// rating from game results: that is `MetricsService`'s job, and two
    /// implementations would eventually disagree.
    static func series(
        rating: [MetricSample],
        puzzle: [MetricSample],
        puzzleDeviation: [MetricSample],
        games: [Game]
    ) -> [ProfileChartMetric: [ProfileSeriesPoint]] {

        let accuracy: [ProfileSeriesPoint] = games
            .compactMap { game in
                guard let value = game.userAccuracy, let endedAt = game.endedAt else { return nil }
                return ProfileSeriesPoint(date: endedAt, value: value, deviation: nil)
            }
            .sorted { $0.date < $1.date }

        // The Glicko deviation in force at each puzzle-rating observation. Only
        // a deviation recorded at or before the point is used — carrying a later,
        // narrower one backwards would understate the uncertainty of old points.
        let deviations = puzzleDeviation.sorted { $0.recordedAt < $1.recordedAt }

        func points(_ samples: [MetricSample], withDeviation: Bool) -> [ProfileSeriesPoint] {
            samples
                .sorted { $0.recordedAt < $1.recordedAt }
                .map { sample in
                    ProfileSeriesPoint(
                        date: sample.recordedAt,
                        value: sample.value,
                        deviation: withDeviation
                            ? deviations.last { $0.recordedAt <= sample.recordedAt }?.value
                            : nil
                    )
                }
        }

        return [
            // No deviation is stored for the playing ladder, so no band is drawn
            // for it. Inventing one from a constant would be a fabricated error
            // bar, which is worse than no error bar at all.
            .rating: points(rating, withDeviation: false),
            .accuracy: accuracy,
            .puzzles: points(puzzle, withDeviation: true)
        ]
    }
}
