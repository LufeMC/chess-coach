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

    /// What the "not a trend yet" note counts.
    ///
    /// Not ``pointNoun``. The rating series is stored one sample per day the
    /// value stood still plus one per time it moved, so three games in an
    /// evening add one point and three days away add three. "1 more game" there
    /// is a promise the data cannot keep — the user plays one and the note does
    /// not move. Accuracy genuinely is one point per game and keeps its noun.
    var trendNoun: String {
        switch self {
        case .rating: return "days of play"
        case .accuracy: return "games"
        case .puzzles: return "days of puzzles"
        }
    }

    /// The same noun for a count of one. Spelled out rather than derived by
    /// trimming an `s`, so an irregular plural added later cannot break it
    /// silently.
    var trendNounSingular: String {
        switch self {
        case .rating: return "day of play"
        case .accuracy: return "game"
        case .puzzles: return "day of puzzles"
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

    /// The digits alone, for a headline whose unit is carried beside it.
    func formatBare(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    /// The grey half of the headline.
    ///
    /// Split off the value because a 44pt `%` is a unit shouting louder than
    /// the measurement it qualifies.
    ///
    /// The playing rating is named for the app because it is the app's own
    /// scale. A club player with a real rating elsewhere otherwise reads "1187
    /// rating" as a claim about the number they already have, and the one
    /// sentence that ever framed it lives on the calibration screen they see
    /// once.
    var unit: String {
        switch self {
        case .rating: return "Rookly rating"
        case .accuracy: return "% accuracy"
        case .puzzles: return "puzzle rating"
        }
    }

    /// The one line that says what scale the number is on.
    ///
    /// `nil` where the unit already carries it: nobody mistakes an accuracy
    /// percentage for a rating they hold somewhere else.
    var scaleNote: String? {
        switch self {
        case .rating:
            return "Measured against Rookly's engine opponents — not your club or online rating."
        case .puzzles:
            return "From the puzzles you solve here. It is not a game rating."
        case .accuracy:
            return nil
        }
    }

    /// What the interpretive line calls a change in this series.
    var changeNoun: String {
        switch self {
        case .rating: return "rating points"
        case .accuracy: return "points of accuracy"
        case .puzzles: return "puzzle points"
        }
    }

    /// Movement smaller than this is the estimate breathing, not a direction.
    ///
    /// Calling a 6-point rating drift a decline is how a chart teaches someone
    /// to read noise as failure, which is the one thing this screen must never
    /// do.
    var levelThreshold: Double {
        switch self {
        case .rating, .puzzles: return 10
        case .accuracy: return 1.5
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

    /// How the interpretive line says this window out loud.
    ///
    /// Spelled rather than abbreviated: `1M` is a control label, and a sentence
    /// that reads "up 62 over the last 1M" is a sentence written by a database.
    var spokenSpan: String {
        switch self {
        case .oneMonth: return "month"
        case .threeMonths: return "three months"
        case .sixMonths: return "six months"
        case .oneYear: return "year"
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

/// One period's average, drawn as a horizontal bar across the period it covers.
///
/// ## Why the chart carries these at all
///
/// A rating line is jagged by construction — every game moves it — and a jagged
/// line answers "what happened on the 14th" when the only question worth asking
/// is "is this going anywhere". Four bars, each sitting at its period's average
/// and labelled with its change against the period before it, turn the same
/// data into a sentence: *up, up, flat, up*. The line stays underneath because
/// the bars are a reading of it, not a replacement for it.
struct ProfileChartSegment: Sendable, Hashable, Identifiable {

    var interval: DateInterval

    var average: Double

    /// Fractional change against the previous segment. `nil` on the first,
    /// which has nothing behind it to compare against — rendering `0%` there
    /// would claim a flat period that was never measured.
    var delta: Double?

    var id: Date { interval.start }

    /// `+10%` / `−7%`, or `nil` when there is no previous period.
    var deltaLabel: String? {
        guard let delta else { return nil }
        let percent = (delta * 100).rounded()
        guard percent != 0 else { return "0%" }
        return percent > 0
            ? String(format: "+%.0f%%", percent)
            : String(format: "−%.0f%%", abs(percent))
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
    /// Deliberately descriptive rather than normative: where *your* values
    /// usually sit in this window, computed from what is on screen — not a
    /// population norm, because no population data exists in this app and
    /// inventing one would be the single most misleading number the screen
    /// could carry. Labelled "Your range" for that reason; "Typical" beside a
    /// user's own figure invites exactly the comparison against other players
    /// that this range refuses to make.
    var typicalRange: ClosedRange<Double>?

    /// Most recent point in the window: the headline value and its date.
    var latest: ProfileSeriesPoint?

    /// y-domain covering the line and any uncertainty band, with headroom.
    var valueDomain: ClosedRange<Double>?

    /// Period averages across the span the data actually covers, oldest first.
    /// Empty when there is not enough play to divide into comparable periods.
    var segments: [ProfileChartSegment] = []

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
            valueDomain: (low - padding)...(high + padding),
            segments: Self.segments(in: windowed)
        )
    }

    /// How many periods a given number of points can honestly be split into.
    ///
    /// Two points per period is the floor: a one-point "average" is the point
    /// itself wearing a bar, and a delta between two such bars is a delta
    /// between two games.
    static func segmentCount(pointCount: Int) -> Int {
        min(4, pointCount / 2)
    }

    /// Divides the series into equal periods and averages each.
    ///
    /// The periods span the **data**, not the selected window. A 3M window
    /// holding three weeks of play would otherwise produce three bars
    /// describing nothing and one bar describing everything, which reads as a
    /// collapse rather than as a gap in the record.
    static func segments(in points: [ProfileSeriesPoint]) -> [ProfileChartSegment] {
        let count = segmentCount(pointCount: points.count)
        guard count >= 2, let first = points.first?.date, let last = points.last?.date else {
            return []
        }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return [] }

        let width = span / Double(count)
        var segments: [ProfileChartSegment] = []
        var previousAverage: Double?

        for index in 0..<count {
            let start = first.addingTimeInterval(width * Double(index))
            let end = index == count - 1 ? last : first.addingTimeInterval(width * Double(index + 1))
            let inPeriod = points.filter { point in
                point.date >= start && (index == count - 1 ? point.date <= end : point.date < end)
            }
            // An empty period is skipped rather than plotted at zero: a bar on
            // the floor is a claim that the rating went to nothing.
            guard !inPeriod.isEmpty else { continue }

            let average = inPeriod.map(\.value).reduce(0, +) / Double(inPeriod.count)
            let delta: Double? = previousAverage.flatMap { previous in
                previous == 0 ? nil : (average - previous) / abs(previous)
            }
            segments.append(
                ProfileChartSegment(
                    interval: DateInterval(start: start, end: end),
                    average: average,
                    delta: delta
                )
            )
            previousAverage = average
        }

        // One bar is not a comparison, and the whole point of the bars is the
        // comparison between them.
        return segments.count >= 2 ? segments : []
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
