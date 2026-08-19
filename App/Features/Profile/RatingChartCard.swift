//
//  RatingChartCard.swift
//  ChessCoach
//

import Charts
import SwiftUI

/// The rating chart.
///
/// ## Chrome, top to bottom
///
/// Title row with icon → the big current value with its unit and date → **the
/// sentence that says what the number means** → the expected range as text on
/// the right, not a drawn axis → the plot → the metric chips → the range
/// control with steppers.
///
/// Three of those are worth defending.
///
/// The interpretive line is the most valuable element on the card. A chart asks
/// the reader to find the trend, compare the recent stretch against the earlier
/// one, and decide whether either matters — all work the card already did in
/// order to draw itself. Leaving the reader to redo it by eye is how a chart
/// becomes decoration.
///
/// The expected range is text because a labelled y-axis on a personal-history
/// chart spends a column of pixels restating numbers the headline already
/// gives; one line of text says the same thing and leaves the plot area to the
/// data. And the metric chips sit *below* the chart because they select what
/// the chart above them shows — a chip row above the plot reads as a filter
/// applied to the whole screen.
struct RatingChartCard: View {

    @Bindable var model: ProfileModel

    private var series: ProfileChartSeries { model.series }

    /// Tall enough for four period bars and their labels without the labels
    /// landing on the line.
    private let plotHeight: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            plot
            metricControl
            rangeRow
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.metric.symbol)
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
                Eyebrow(text: model.metric.title)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    headlineValue
                    Text(headlineDate)
                        .typeRole(.caption, monospacedDigits: true)
                }

                Spacer(minLength: 12)

                if let typical = series.typicalRange {
                    // Stated, not drawn. "Typical" is descriptive of this
                    // window's own values — see `ProfileChartSeries.typicalRange`
                    // for why it is not a population claim.
                    Text("Typical \(model.metric.formatCompact(typical.lowerBound))–\(model.metric.formatCompact(typical.upperBound))")
                        .typeRole(.caption, monospacedDigits: true)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let interpretation = model.interpretation {
                Text(interpretation)
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let pending = model.interpretationPlaceholder {
                // Says what is missing rather than leaving the sentence's slot
                // blank. Caption weight, because it is an explanation of an
                // absence and must not read as the finding itself.
                Text(pending)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var headlineValue: some View {
        if let latest = series.latest {
            DenominatorText(
                Denominator(
                    value: model.metric.formatBare(latest.value),
                    denominator: model.metric.unit
                ),
                role: .display
            )
        } else {
            Text("—")
                .typeRole(.display)
        }
    }

    private var headlineDate: String {
        guard let latest = series.latest else {
            return series.interval.start.formatted(.dateTime.month(.abbreviated).year())
        }
        return latest.date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    // MARK: - Plot

    @ViewBuilder
    private var plot: some View {
        if series.isPlottable {
            chart
                .frame(height: plotHeight)
        } else {
            // A single point is not a trend, and a chart drawn through one dot
            // invites the reader to imagine the line.
            MeasurementPlaceholder(
                message: model.seriesState.message ?? "Nothing to plot yet",
                symbol: "chart.line.flattrend.xyaxis"
            )
            .frame(height: plotHeight, alignment: .center)
        }
    }

    private var chart: some View {
        Chart {
            // The uncertainty band, where the estimate carries a deviation.
            // A rating is an estimate; drawing it as a bare line claims a
            // precision the number does not have.
            ForEach(series.points) { point in
                if let interval = point.confidenceInterval {
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Low", interval.lowerBound),
                        yEnd: .value("High", interval.upperBound)
                    )
                    .foregroundStyle(Color.primary.opacity(ProfileStyle.plotBandOpacity))
                    .interpolationMethod(.monotone)
                }
            }

            ForEach(series.points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(model.metric.title, point.value)
                )
                .foregroundStyle(Color.primary.opacity(ProfileStyle.plotLineOpacity))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }

            // The narrative layer: one bar per period, each labelled with its
            // average and its change against the period before it. This is what
            // turns a jagged line into "up, up, flat, up".
            ForEach(series.segments) { segment in
                RuleMark(
                    xStart: .value("From", segment.interval.start),
                    xEnd: .value("To", segment.interval.end),
                    y: .value("Period average", segment.average)
                )
                .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                .foregroundStyle(Color.primary)
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    segmentLabel(segment)
                }
            }

            // The ring is the one piece of accent the chart is allowed: it says
            // "here is where you are", which is the only question the card is
            // being asked.
            if let latest = series.latest {
                PointMark(
                    x: .value("Date", latest.date),
                    y: .value(model.metric.title, latest.value)
                )
                .symbolSize(160)
                .foregroundStyle(Palette.accent.dynamic.opacity(0.20))

                PointMark(
                    x: .value("Date", latest.date),
                    y: .value(model.metric.title, latest.value)
                )
                .symbolSize(44)
                .foregroundStyle(Palette.accent.dynamic)
            }
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: plotDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(TypeRole.label.font)
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXScale(domain: series.interval.start...series.interval.end)
        .animation(Motion.contentSwap, value: series)
    }

    /// The y-domain the plot is actually drawn in.
    ///
    /// Wider at the top than ``ProfileChartSeries/valueDomain`` whenever period
    /// bars are drawn, because their labels ride above them and a label clipped
    /// by the top of the card is a number the reader can see half of.
    private var plotDomain: ClosedRange<Double> {
        guard let domain = series.valueDomain else { return 0...1 }
        guard !series.segments.isEmpty else { return domain }
        let headroom = (domain.upperBound - domain.lowerBound) * 0.14
        return domain.lowerBound...(domain.upperBound + headroom)
    }

    /// `1148 +4%`. The delta carries an arrow as well as a colour, because
    /// colour alone fails for the readers who need the encoding most.
    private func segmentLabel(_ segment: ProfileChartSegment) -> some View {
        HStack(spacing: 3) {
            Text(model.metric.formatCompact(segment.average))
                .typeRole(.label, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(.secondary)

            if let delta = segment.delta, let label = segment.deltaLabel {
                let direction = ProfileNarrative.Direction.of(delta * 100, threshold: 1)
                HStack(spacing: 1) {
                    Image(systemName: deltaSymbol(direction))
                        .typeRole(.label, appliesForeground: false)
                        .imageScale(.small)
                    Text(label)
                        .typeRole(.label, monospacedDigits: true, appliesForeground: false)
                }
                .foregroundStyle(deltaStyle(direction))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func deltaSymbol(_ direction: ProfileNarrative.Direction) -> String {
        switch direction {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .level: "minus"
        }
    }

    private func deltaStyle(_ direction: ProfileNarrative.Direction) -> Color {
        switch direction {
        // Rating gained and rating given back, which is the one thing the eval
        // colours are allowed to mean.
        case .up: Palette.evalPositive.dynamic
        case .down: Palette.evalNegative.dynamic
        case .level: Color.secondary
        }
    }

    // MARK: - Which series

    private var metricControl: some View {
        SegmentedChoice(
            options: ProfileChartMetric.allCases,
            selection: model.metric,
            title: { $0.title },
            onSelect: { model.metric = $0 }
        )
    }

    // MARK: - Time range

    private var rangeRow: some View {
        HStack(spacing: 10) {
            SegmentedChoice(
                options: ProfileTimeRange.allCases,
                selection: model.range,
                title: { $0.rawValue },
                onSelect: { model.range = $0 }
            )

            stepper(symbol: "chevron.left", delta: 1, enabled: model.canStepBack)
            stepper(symbol: "chevron.right", delta: -1, enabled: model.canStepForward)
        }
    }

    private func stepper(symbol: String, delta: Int, enabled: Bool) -> some View {
        Button {
            model.step(delta)
        } label: {
            Image(systemName: symbol)
                .typeRole(.caption, appliesForeground: false)
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.secondary.opacity(enabled ? 1 : 0.35))
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .accessibilityLabel(delta > 0 ? "Earlier \(model.range.rawValue)" : "Later \(model.range.rawValue)")
    }
}
