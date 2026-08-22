//
//  ProfileNarrative.swift
//  ChessCoach
//

import Foundation

/// The plain-language reading of the chart, in the user's own terms.
///
/// ## Why the screen writes this out
///
/// A rating chart asks the reader to do three things at once: find the trend
/// through the noise, compare the recent stretch against the earlier one, and
/// decide whether either is worth caring about. Every one of those is work the
/// screen already did to draw the line, and leaving the reader to redo it by eye
/// is how a chart becomes decoration — looked at, never read.
///
/// So the sentence states the movement, and the sentence after it states what
/// the movement means. It never congratulates and never warns: it is a reading,
/// not a verdict, and a user who suspects the chart of cheerleading stops
/// believing the numbers under it.
enum ProfileNarrative {

    /// Which way a series moved, once noise is discounted.
    enum Direction: Sendable, Hashable {
        case up
        case down
        case level

        /// Classifies a change against the threshold below which the series is
        /// only breathing.
        static func of(_ change: Double, threshold: Double) -> Direction {
            if change > threshold { return .up }
            if change < -threshold { return .down }
            return .level
        }
    }

    /// The paragraph under the headline number.
    ///
    /// `nil` when there is not enough plotted to say anything true, in which
    /// case the card shows its measurement placeholder instead — an
    /// interpretation of two data points would be the most confident wrong
    /// sentence on the screen.
    static func interpretation(
        for series: ProfileChartSeries,
        metric: ProfileChartMetric,
        range: ProfileTimeRange
    ) -> String? {
        guard series.isPlottable,
              let first = series.points.first,
              let last = series.points.last
        else { return nil }

        // Two points is a line between two measurements, not a trend, and the
        // sentence this function writes is stated with total confidence. The
        // chart may still draw them — a line between two dots claims nothing —
        // but the prose under it has to wait until there is something to say.
        guard series.points.count >= Self.minimumPointsToInterpret else { return nil }

        // The window the user picked is not the period the data covers. A
        // rating measured yesterday and again today sits inside the 3M window,
        // and "down 11 rating points over the last three months" would be a
        // sentence about a quarter that never happened — the reader has no way
        // to tell it apart from a real three-month slide. Say what the data
        // actually spans.
        let coveredDays = last.date.timeIntervalSince(first.date) / 86_400
        guard coveredDays >= Self.minimumDaysToInterpret else { return nil }

        let change = last.value - first.value
        let overall = Direction.of(change, threshold: metric.levelThreshold)
        var sentences = [
            movement(
                change: change,
                direction: overall,
                metric: metric,
                span: spokenSpan(days: coveredDays, range: range)
            )
        ]

        if let recent = series.segments.last?.delta {
            sentences.append(recentStretch(delta: recent, overall: overall))
        }

        return sentences.joined(separator: " ")
    }

    // MARK: - Clauses

    /// What to say when there is no trend to state yet.
    ///
    /// Never nothing. The alternative to a sentence here is a gap in the card
    /// where a sentence used to be, and a gap reads as a bug rather than as an
    /// answer — the same reason `RungPresentation` carries an `unmeasuredNote`
    /// instead of drawing a 0% bar. It names the specific thing that is missing,
    /// so the reader knows what would fill it.
    static func pendingNote(
        for series: ProfileChartSeries,
        metric: ProfileChartMetric
    ) -> String? {
        // The card has its own empty state below two points; this is only for
        // the window where there is a line but nothing true to say about it.
        guard series.isPlottable, let first = series.points.first, let last = series.points.last
        else { return nil }

        let missing = minimumPointsToInterpret - series.points.count
        if missing > 0 {
            let noun = missing == 1 ? metric.trendNounSingular : metric.trendNoun
            return "\(missing) more \(noun) before this is a trend."
        }

        let coveredDays = last.date.timeIntervalSince(first.date) / 86_400
        if coveredDays < minimumDaysToInterpret {
            return "All of this is from the last few days — a couple of weeks of play and it becomes a trend."
        }
        return nil
    }

    /// Below this the line is two measurements, not a trend.
    static let minimumPointsToInterpret = 4

    /// Below this the change happened too recently to describe as a period.
    ///
    /// Two weeks, because the unit the sentence would otherwise reach for is a
    /// month: a claim about "the last month" built from four days of play is
    /// the same error as one built from two points, just harder to notice.
    static let minimumDaysToInterpret = 14.0

    /// How to say the period the data actually covers.
    ///
    /// Rounded down to the unit below what it reaches, never up: a series
    /// spanning 25 days is "three weeks", not "a month". Overstating the span
    /// makes a change look slower and steadier than it was, which is the
    /// flattering direction and therefore the one to guard against.
    static func spokenSpan(days: Double, range: ProfileTimeRange) -> String {
        // Never claim more than the window the user is looking at, whatever the
        // data spans — the chart is clipped to the window and the sentence has
        // to describe the same picture.
        let capped = min(days, Double(range.days))
        switch capped {
        case ..<21: return "two weeks"
        case ..<30: return "three weeks"
        case ..<60: return "month"
        case ..<90: return "two months"
        case ..<180: return "three months"
        case ..<365: return "six months"
        default: return "year"
        }
    }

    static func movement(
        change: Double,
        direction: Direction,
        metric: ProfileChartMetric,
        span: String
    ) -> String {
        let magnitude = String(format: "%.0f", abs(change))
        switch direction {
        case .up:
            return "Up \(magnitude) \(metric.changeNoun) over the last \(span)."
        case .down:
            return "Down \(magnitude) \(metric.changeNoun) over the last \(span)."
        case .level:
            return "Level over the last \(span)."
        }
    }

    /// What the most recent period says about the whole window.
    ///
    /// The two facts are deliberately combined into one sentence rather than
    /// listed: "up 62, last period down 7%" is two numbers the reader has to
    /// reconcile, and reconciling them is the sentence's job.
    ///
    /// "Period", not "stretch". The bars on the plot are period averages and the
    /// caption under them says so, which makes the sentence and the picture the
    /// same object; "stretch" named nothing on screen and left the reader to
    /// work out that the four labelled bars were what it meant.
    static func recentStretch(delta: Double, overall: Direction) -> String {
        let percent = (delta * 100).rounded()
        let recent = Direction.of(percent, threshold: 1)
        let size = String(format: "%.0f%%", abs(percent))

        switch (overall, recent) {
        case (.up, .up):
            return "The latest period averages \(size) above the one before it, so the climb is current rather than history."
        case (.up, .down):
            return "The latest period averages \(size) below the one before it, so most of that gain is older than it looks."
        case (.up, .level):
            return "The latest period averages level with the one before it, so the climb has paused rather than reversed."
        case (.down, .up):
            return "The latest period averages \(size) above the one before it, so the fall has already turned."
        case (.down, .down):
            return "The latest period averages \(size) below the one before it, so it has not turned yet."
        case (.down, .level):
            return "The latest period averages level with the one before it, so the fall has stopped."
        case (.level, .up):
            return "The latest period averages \(size) above the one before it, so the flat line is ending on the up side."
        case (.level, .down):
            return "The latest period averages \(size) below the one before it, so the flat line is ending on the down side."
        case (.level, .level):
            // Not "a point or two": the level band is a 1% delta, which on a
            // 1200 rating is a dozen points and on an accuracy percentage is
            // not points at all.
            return "Each period averages within 1% of the last — a plateau rather than a swing."
        }
    }
}
