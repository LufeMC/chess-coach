//
//  RatingHistoryTests.swift
//  ChessCoachTests
//

import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// MARK: - Fixtures

/// Midday UTC. Every offset below stays inside one day unless it is meant to
/// cross one, which is what makes the coalescing assertions deterministic.
private let noon = Date(timeIntervalSince1970: 1_784_980_800)

/// UTC rather than the device's zone: a day boundary that moved with whichever
/// machine ran the suite would make "one point a day" flaky twice a year.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A clock the test moves by hand, so "the next morning" costs nothing.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Dates round-trip through SQLite as text, so equality is to the millisecond.
private func expectSameInstant(
    _ lhs: Date?,
    _ rhs: Date?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let lhs, let rhs else {
        #expect(lhs == nil && rhs == nil, sourceLocation: sourceLocation)
        return
    }
    #expect(abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.01,
        sourceLocation: sourceLocation)
}

/// Does what `LadderRatingWriter` does at the end of a rated game: moves the
/// stored rating and stamps the metric row with the moment it moved.
///
/// Written out rather than driving the real writer because the writer needs a
/// finished game with an opponent and a result, and none of that is what these
/// tests are about — what matters is that the metric row carries the game's end
/// time, because that timestamp is the one the chart plots against.
private func applyRating(_ rating: Double, to database: UserDatabase, at date: Date) throws {
    try database.settings.update { $0.userRating = rating }
    try database.metrics.upsert(
        key: MetricKey.ladderRating.rawValue,
        window: MetricWindow.allTime.key,
        value: rating,
        sampleCount: 1,
        updatedAt: date
    )
}

private func ratingSamples(_ database: UserDatabase) throws -> [MetricSample] {
    try database.metrics.samples(
        key: MetricKey.ladderRating.rawValue,
        window: MetricWindow.allTime.key
    )
}

@MainActor
private func makeService(_ database: UserDatabase, clock: TestClock) -> MetricsService {
    MetricsService(
        games: database.games,
        moments: database.moments,
        metrics: database.metrics,
        settings: database.settings,
        calendar: utc,
        clock: { clock.now }
    )
}

// MARK: - Recording

@MainActor
@Suite("Rating history recording")
struct RatingHistoryRecordingTests {

    @Test("A recompute records the rating against the game that moved it")
    func sampleKeepsTheGameTime() async throws {
        // The point must land on the evening the game was played, not on the
        // morning the user next opened the app — otherwise the chart tells a
        // story about app launches.
        let database = try UserDatabase.inMemory()
        let gameEnd = noon
        try applyRating(1187, to: database, at: gameEnd)

        let clock = TestClock(gameEnd.addingTimeInterval(900))
        let service = makeService(database, clock: clock)
        await service.refresh()
        #expect(service.lastError == nil)

        let samples = try ratingSamples(database)
        #expect(samples.map(\.value) == [1187])
        expectSameInstant(samples.first?.recordedAt, gameEnd)
    }

    @Test("Opening Profile fifty times does not draw fifty points")
    func repeatedRefreshesCoalesce() async throws {
        // `MetricsService.refresh()` runs on app foreground and on every
        // Profile load. Without coalescing, the single most-visited screen in
        // the app would be the thing corrupting its own chart.
        let database = try UserDatabase.inMemory()
        try applyRating(1187, to: database, at: noon)

        let clock = TestClock(noon)
        let service = makeService(database, clock: clock)
        for index in 0..<50 {
            clock.now = noon.addingTimeInterval(Double(index) * 60)
            await service.refresh()
        }

        #expect(try ratingSamples(database).count == 1)
    }

    @Test("A rating that holds steady still ticks once a day")
    func flatRatingKeepsTheWindowPopulated() async throws {
        // A fortnight without a game must not empty the one-month window: the
        // rating is perfectly well known on each of those days.
        let database = try UserDatabase.inMemory()
        try applyRating(1187, to: database, at: noon)

        let clock = TestClock(noon)
        let service = makeService(database, clock: clock)
        for day in 0..<3 {
            clock.now = noon.addingTimeInterval(Double(day) * 86_400)
            await service.refresh()
        }

        let samples = try ratingSamples(database)
        #expect(samples.map(\.value) == [1187, 1187, 1187])
        #expect(Set(samples.map(\.day)).count == 3)
    }

    @Test("Each game that moves the rating earns its own point")
    func everyRatingMovementIsPlotted() async throws {
        let database = try UserDatabase.inMemory()
        let clock = TestClock(noon)
        let service = makeService(database, clock: clock)

        let ratings: [Double] = [1187, 1203, 1196]
        for (index, rating) in ratings.enumerated() {
            let gameEnd = noon.addingTimeInterval(Double(index) * 86_400)
            try applyRating(rating, to: database, at: gameEnd)
            clock.now = gameEnd.addingTimeInterval(300)
            await service.refresh()
        }

        let samples = try ratingSamples(database)
        #expect(samples.map(\.value) == ratings)
        expectSameInstant(samples.last?.recordedAt, noon.addingTimeInterval(2 * 86_400))
    }

    @Test("The puzzle rating and its deviation are kept too")
    func puzzleSeriesIsRecorded() async throws {
        // The chart has three segments and the puzzle one draws a confidence
        // band, which needs the deviation in force at each observation.
        let database = try UserDatabase.inMemory()
        try database.settings.update {
            $0.puzzleRating = 1_420
            $0.puzzleRD = 78
        }

        let clock = TestClock(noon)
        await makeService(database, clock: clock).refresh()

        let allTime = MetricWindow.allTime.key
        #expect(try database.metrics
            .samples(key: MetricKey.puzzleRating.rawValue, window: allTime)
            .map(\.value) == [1_420])
        #expect(try database.metrics
            .samples(key: MetricKey.puzzleRatingDeviation.rawValue, window: allTime)
            .map(\.value) == [78])
    }
}

// MARK: - Reading

@MainActor
@Suite("Rating history on the chart")
struct RatingHistoryChartTests {

    /// A fortnight of rated play, recorded exactly as the service records it.
    private func seed(_ database: UserDatabase, days: Int, from start: Double) throws {
        for day in 0..<days {
            let at = noon.addingTimeInterval(Double(day) * 86_400)
            try database.metrics.recordSample(
                key: MetricKey.ladderRating.rawValue,
                window: MetricWindow.allTime.key,
                value: start + Double(day) * 6,
                measuredAt: at,
                now: at,
                calendar: utc
            )
        }
    }

    @Test("Stored samples reach the screen as a plottable series")
    func loaderProducesTheRealSeries() async throws {
        // The bug this whole slice exists for: the chart rendered its
        // "not enough data" placeholder on real data, because the metrics layer
        // stored a current value and no history at all.
        let database = try UserDatabase.inMemory()
        try seed(database, days: 12, from: 1_150)

        let loader = ProfileDataLoader(
            history: database.metrics,
            games: database.games,
            moments: database.moments
        )
        let data = try await loader.load(now: noon.addingTimeInterval(11 * 86_400))
        let points = data.series[.rating] ?? []

        #expect(points.count == 12)
        #expect(points.map(\.date) == points.map(\.date).sorted())
        #expect(points.first?.value == 1_150.0)
        // Written out rather than as `1_150 + 11 * 6`: inside the macro the
        // arithmetic is evaluated as integers and compared against a Double,
        // which fails on a value that is exactly equal.
        #expect(points.last?.value == 1_216.0)
        // No deviation is stored for the playing ladder, so no band is drawn.
        #expect(points.allSatisfy { $0.deviation == nil })
        #expect(ProfileMeasurementState.forSeries(pointCount: points.count) == .measured)
    }

    @Test("The period control filters the series to its own window")
    func periodFiltering() {
        let now = noon.addingTimeInterval(200 * 86_400)
        let samples = (0..<200).map { day -> MetricSample in
            let at = noon.addingTimeInterval(Double(day) * 86_400)
            return MetricSample(
                key: MetricKey.ladderRating.rawValue,
                window: MetricWindow.allTime.key,
                day: DailyLoop.dayKey(for: at, calendar: utc),
                value: 1_100 + Double(day),
                recordedAt: at
            )
        }
        let points = ProfileDataLoader.series(
            rating: samples,
            puzzle: [],
            puzzleDeviation: [],
            games: []
        )[.rating] ?? []

        let month = ProfileChartSeries.make(from: points, range: .oneMonth, now: now)
        let quarter = ProfileChartSeries.make(from: points, range: .threeMonths, now: now)
        let year = ProfileChartSeries.make(from: points, range: .oneYear, now: now)

        #expect(month.points.count == 30)
        #expect(quarter.points.count == 91)
        #expect(year.points.count == 200)
        // Each window ends on the same, most recent observation.
        #expect(month.latest?.value == 1_299)
        #expect(quarter.latest?.value == 1_299)
        #expect(year.latest?.value == 1_299)
        // And the shorter windows start later.
        #expect(month.points.first!.value > quarter.points.first!.value)
    }

    @Test("Period-average segments are computed over the span the data covers")
    func segmentsDescribeRealPeriods() async throws {
        let database = try UserDatabase.inMemory()
        try seed(database, days: 12, from: 1_150)

        let loader = ProfileDataLoader(
            history: database.metrics,
            games: database.games,
            moments: database.moments
        )
        let data = try await loader.load(now: noon.addingTimeInterval(11 * 86_400))
        let series = ProfileChartSeries.make(
            from: data.series[.rating] ?? [],
            range: .oneMonth,
            now: noon.addingTimeInterval(11 * 86_400)
        )

        #expect(series.isPlottable)
        #expect(series.segments.count == 4)
        // Twelve rising points: every bar must sit above the one before it, and
        // every bar after the first must carry a positive delta.
        let averages = series.segments.map(\.average)
        #expect(averages == averages.sorted())
        #expect(series.segments.first?.delta == nil)
        #expect(series.segments.dropFirst().allSatisfy { ($0.delta ?? 0) > 0 })
        // The bars span the data, not the selected window.
        #expect(series.segments.first!.interval.start >= noon.addingTimeInterval(-1))
    }

    @Test("The puzzle series carries the deviation in force at each point")
    func puzzleBandUsesTheDeviationOfItsTime() {
        // A later, narrower deviation carried backwards would draw old points
        // as more certain than they were.
        func sample(_ key: MetricKey, _ value: Double, dayOffset: Int) -> MetricSample {
            let at = noon.addingTimeInterval(Double(dayOffset) * 86_400)
            return MetricSample(
                key: key.rawValue,
                window: MetricWindow.allTime.key,
                day: DailyLoop.dayKey(for: at, calendar: utc),
                value: value,
                recordedAt: at
            )
        }

        let points = ProfileDataLoader.series(
            rating: [],
            puzzle: [
                sample(.puzzleRating, 1_400, dayOffset: 0),
                sample(.puzzleRating, 1_430, dayOffset: 2)
            ],
            puzzleDeviation: [
                sample(.puzzleRatingDeviation, 120, dayOffset: 0),
                sample(.puzzleRatingDeviation, 60, dayOffset: 2)
            ],
            games: []
        )[.puzzles] ?? []

        #expect(points.map(\.deviation) == [120, 60])
    }

    @Test("An empty history still yields the placeholder rather than a fake line")
    func nothingRecordedStaysHonest() async throws {
        let database = try UserDatabase.inMemory()
        let loader = ProfileDataLoader(
            history: database.metrics,
            games: database.games,
            moments: database.moments
        )
        let data = try await loader.load(now: noon)
        let series = ProfileChartSeries.make(
            from: data.series[.rating] ?? [],
            range: .oneMonth,
            now: noon
        )

        #expect(!series.isPlottable)
        #expect(ProfileMeasurementState.forSeries(pointCount: series.points.count)
            == .nothingYet(noun: "games"))
    }
}
