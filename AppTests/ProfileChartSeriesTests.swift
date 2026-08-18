import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

@Suite("Rating chart series")
struct ProfileChartSeriesTests {

    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func point(daysAgo: Double, value: Double, deviation: Double? = nil) -> ProfileSeriesPoint {
        ProfileSeriesPoint(
            date: now.addingTimeInterval(-daysAgo * 86_400),
            value: value,
            deviation: deviation
        )
    }

    // MARK: - Windowing

    @Test("A range keeps only the points inside it")
    func windowing() {
        let all = [
            Self.point(daysAgo: 200, value: 900),
            Self.point(daysAgo: 100, value: 1000),
            Self.point(daysAgo: 20, value: 1100),
            Self.point(daysAgo: 2, value: 1150)
        ]
        let month = ProfileChartSeries.make(from: all, range: .oneMonth, now: Self.now)
        #expect(month.points.map(\.value) == [1100, 1150])

        let sixMonths = ProfileChartSeries.make(from: all, range: .sixMonths, now: Self.now)
        #expect(sixMonths.points.map(\.value) == [1000, 1100, 1150])
    }

    @Test("Points come out oldest first regardless of input order")
    func sorted() {
        let all = [
            Self.point(daysAgo: 2, value: 3),
            Self.point(daysAgo: 20, value: 1),
            Self.point(daysAgo: 10, value: 2)
        ]
        let series = ProfileChartSeries.make(from: all, range: .oneMonth, now: Self.now)
        #expect(series.points.map(\.value) == [1, 2, 3])
        #expect(series.latest?.value == 3)
    }

    @Test("Stepping back one window shows the previous window, not an overlap")
    func offsetPaging() {
        let all = [
            Self.point(daysAgo: 45, value: 1000),
            Self.point(daysAgo: 10, value: 1100)
        ]
        let current = ProfileChartSeries.make(from: all, range: .oneMonth, offset: 0, now: Self.now)
        #expect(current.points.map(\.value) == [1100])

        let previous = ProfileChartSeries.make(from: all, range: .oneMonth, offset: 1, now: Self.now)
        #expect(previous.points.map(\.value) == [1000])

        // The two windows must abut, not overlap: `‹` means "the previous
        // month", and a shared day would double-count a point.
        #expect(previous.interval.end == current.interval.start)
    }

    @Test("Each range spans its own number of days")
    func rangeSpans() {
        for range in ProfileTimeRange.allCases {
            let interval = range.interval(offset: 0, now: Self.now)
            #expect(Int(interval.duration / 86_400) == range.days)
            #expect(interval.end == Self.now)
        }
    }

    // MARK: - Summary values

    @Test("Average is the mean of the plotted points only")
    func average() throws {
        let all = [
            Self.point(daysAgo: 200, value: 0),   // outside the window
            Self.point(daysAgo: 20, value: 1000),
            Self.point(daysAgo: 10, value: 1100),
            Self.point(daysAgo: 1, value: 1200)
        ]
        let series = ProfileChartSeries.make(from: all, range: .oneMonth, now: Self.now)
        let average = try #require(series.average)
        #expect(abs(average - 1100) < 0.0001)
    }

    @Test("Typical range is the middle 80% and needs five points")
    func typicalRange() throws {
        #expect(ProfileChartSeries.typicalRange(of: [1, 2, 3, 4]) == nil)

        let range = try #require(ProfileChartSeries.typicalRange(of: [10, 20, 30, 40, 50]))
        // 10th percentile of a 5-point series interpolates between 10 and 20.
        #expect(abs(range.lowerBound - 14) < 0.0001)
        #expect(abs(range.upperBound - 46) < 0.0001)
    }

    @Test("The y-domain covers the uncertainty band, not just the line")
    func domainIncludesBand() throws {
        let all = [
            Self.point(daysAgo: 20, value: 1000, deviation: 100),
            Self.point(daysAgo: 10, value: 1000, deviation: 100)
        ]
        let series = ProfileChartSeries.make(from: all, range: .oneMonth, now: Self.now)
        let domain = try #require(series.valueDomain)
        #expect(domain.lowerBound < 1000 - 1.96 * 100)
        #expect(domain.upperBound > 1000 + 1.96 * 100)
    }

    @Test("A flat series still gets a drawable domain")
    func flatSeriesDomain() throws {
        let all = [
            Self.point(daysAgo: 20, value: 1200),
            Self.point(daysAgo: 10, value: 1200)
        ]
        let domain = try #require(
            ProfileChartSeries.make(from: all, range: .oneMonth, now: Self.now).valueDomain
        )
        #expect(domain.lowerBound < domain.upperBound)
    }

    @Test("No deviation means no band — never a fabricated one")
    func noDeviationNoBand() {
        #expect(Self.point(daysAgo: 1, value: 1200).confidenceInterval == nil)
        #expect(Self.point(daysAgo: 1, value: 1200, deviation: 0).confidenceInterval == nil)
        let band = Self.point(daysAgo: 1, value: 1200, deviation: 50).confidenceInterval
        #expect(band?.lowerBound == 1200 - 1.96 * 50)
    }

    // MARK: - Empty states

    @Test("A window with fewer than two points is not plottable")
    func plottability() {
        let empty = ProfileChartSeries.make(from: [], range: .oneMonth, now: Self.now)
        #expect(!empty.isPlottable)
        #expect(empty.latest == nil)
        #expect(empty.average == nil)
        #expect(empty.typicalRange == nil)

        let single = ProfileChartSeries.make(
            from: [Self.point(daysAgo: 3, value: 1200)], range: .oneMonth, now: Self.now
        )
        #expect(!single.isPlottable)
        #expect(single.latest?.value == 1200)

        let pair = ProfileChartSeries.make(
            from: [Self.point(daysAgo: 3, value: 1200), Self.point(daysAgo: 1, value: 1210)],
            range: .oneMonth, now: Self.now
        )
        #expect(pair.isPlottable)
    }

    @Test("An empty window still reports the interval it was asked about")
    func emptyWindowKeepsInterval() {
        let series = ProfileChartSeries.make(from: [], range: .threeMonths, offset: 2, now: Self.now)
        #expect(series.interval == ProfileTimeRange.threeMonths.interval(offset: 2, now: Self.now))
    }

    // MARK: - Formatting

    @Test("Metrics format in their own units")
    func formatting() {
        #expect(ProfileChartMetric.rating.format(1140.4) == "1140")
        #expect(ProfileChartMetric.puzzles.format(1140.6) == "1141")
        #expect(ProfileChartMetric.accuracy.format(84.26) == "84.3%")
        #expect(ProfileChartMetric.accuracy.formatCompact(84.26) == "84%")
    }
}
