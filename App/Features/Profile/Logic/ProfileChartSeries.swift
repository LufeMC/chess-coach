//
//  ProfileChartSeries.swift
//  ChessCoach
//

import Foundation

/// Which series the chart is showing.
///
/// Three, because three is what the data layer can honestly produce: the
/// playing rating, per-game accuracy, and the puzzle rating. A fourth chip that
/// renders an empty state every time would be a menu item advertising a feature
/// that does not exist.
enum ProfileChartMetric: String, CaseIterable, Identifiable, Sendable, Hashable {
    case rating
    case accuracy
    case puzzles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rating: return "Rating"
        case .accuracy: return "Accuracy"
        case .puzzles: return "Puzzles"
        }
    }

    /// Icon for the card's title row.
    var symbol: String {
        switch self {
        case .rating: return "chart.line.uptrend.xyaxis"
        case .accuracy: return "target"
        case .puzzles: return "puzzlepiece"
        }
    }

    /// What one point on this series represents, for the axis-free subtitle.
    var pointNoun: String {
        switch self {
        case .rating: return "games"
        case .accuracy: return "games"
        case .puzzles: return "sessions"
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .rating, .puzzles: return String(format: "%.0f", value)
        case .accuracy: return String(format: "%.1f%%", value)
        }
    }

    /// Terser form, for the average pill and the typical-range text where the
    /// unit is already established by the headline.
    func formatCompact(_ value: Double) -> String {
        switch self {
        case .rating, .puzzles: return String(format: "%.0f", value)
        case .accuracy: return String(format: "%.0f%%", value)
        }
    }
}

/// The chart's time window.
enum ProfileTimeRange: String, CaseIterable, Identifiable, Sendable, Hashable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"

    var id: String { rawValue }

    var days: Int {
        switch self {
        case .oneMonth: return 30
        case .threeMonths: return 91
        case .sixMonths: return 182
        case .oneYear: return 365
        }
    }

    /// The window `offset` steps back from `now`.
    ///
    /// Offsets are whole windows rather than free scrolling, which is what makes
    /// the `‹ ›` steppers legible: pressing `‹` on `3M` always means "the
    /// previous three months", not "some earlier three months".
    func interval(offset: Int, now: Date) -> DateInterval {
        let span = Double(days) * 86_400
        let end = now.addingTimeInterval(-span * Double(offset))
        return DateInterval(start: end.addingTimeInterval(-span), end: end)
    }
}

/// One plotted observation.
///
/// `deviation` is optional and load-bearing: a rating is an *estimate*, and the
/// band drawn from its deviation is the difference between a chart that reports
/// what we know and one that overstates its own precision. Where the data layer
/// has no deviation to give (accuracy has none; the playing ladder does not
/// currently store one) the field is `nil` and the band is simply not drawn —
/// never faked with a constant.
struct ProfileSeriesPoint: Sendable, Hashable, Identifiable {
    var date: Date
    var value: Double
    var deviation: Double?

    var id: Date { date }

    /// The conventional 95% interval, matching `GlickoRating.confidenceInterval`.
    var confidenceInterval: ClosedRange<Double>? {
        guard let deviation, deviation > 0 else { return nil }
        return (value - 1.96 * deviation)...(value + 1.96 * deviation)
    }
}

/// A windowed, summarised series, ready to draw.
struct ProfileChartSeries: Sendable, Hashable {

    /// Points inside ``interval``, oldest first.
    var points: [ProfileSeriesPoint]

    var interval: DateInterval

    /// Mean of ``points``, and the y of the dashed average rule.
    var average: Double?

    /// The middle 80% of the plotted values.
    ///
    /// Deliberately descriptive rather than normative. "Typical" here means
    /// "where *your* values usually sit in this window", computed from what is
    /// on screen — not a population norm, because no population data exists in
    /// this app and inventing one would be the single most misleading number
    /// the screen could carry.
    var typicalRange: ClosedRange<Double>?

    /// Most recent point in the window: the headline value and its date.
    var latest: ProfileSeriesPoint?

    /// y-domain covering the line and any uncertainty band, with headroom.
    var valueDomain: ClosedRange<Double>?

    /// A single point cannot show a trend, and a chart is a trend instrument.
    var isPlottable: Bool { points.count >= 2 }

    /// Builds the series for one window.
    ///
    /// - Parameter all: Every point the data layer has, in any order.
    static func make(
        from all: [ProfileSeriesPoint],
        range: ProfileTimeRange,
        offset: Int = 0,
        now: Date = Date()
    ) -> ProfileChartSeries {
        let interval = range.interval(offset: offset, now: now)
        let windowed = all
            .filter { interval.start <= $0.date && $0.date <= interval.end }
            .sorted { $0.date < $1.date }

        guard !windowed.isEmpty else {
            return ProfileChartSeries(
                points: [],
                interval: interval,
                average: nil,
                typicalRange: nil,
                latest: nil,
                valueDomain: nil
            )
        }

        let values = windowed.map(\.value)
        let average = values.reduce(0, +) / Double(values.count)

        var low = values.min() ?? 0
        var high = values.max() ?? 0
        for point in windowed {
            guard let band = point.confidenceInterval else { continue }
            low = min(low, band.lowerBound)
            high = max(high, band.upperBound)
        }
        // Flat series would otherwise collapse to a zero-height domain, which
        // Charts renders as a line pinned to the frame edge.
        let padding = max((high - low) * 0.12, max(abs(high) * 0.01, 1))

        return ProfileChartSeries(
            points: windowed,
            interval: interval,
            average: average,
            typicalRange: Self.typicalRange(of: values),
            latest: windowed.last,
            valueDomain: (low - padding)...(high + padding)
        )
    }

    /// 10th–90th percentile, linearly interpolated.
    ///
    /// Requires five points. Below that the "middle 80%" is a restatement of
    /// the min and the max wearing a statistical hat, and the honest answer is
    /// to show nothing.
    static func typicalRange(of values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 5 else { return nil }
        let sorted = values.sorted()
        let low = percentile(sorted, 0.10)
        let high = percentile(sorted, 0.90)
        guard low <= high else { return nil }
        return low...high
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
