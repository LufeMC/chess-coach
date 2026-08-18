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
/// Title row with icon → the big current value with its date beneath → the
/// expected range as **text on the right**, not a drawn axis → the plot → the
/// metric chips → the time-range row with steppers.
///
/// Two of those are worth defending. The expected range is text because a
/// labelled y-axis on a personal-history chart spends a column of pixels
/// restating numbers the headline already gives; one line of text says the same
/// thing and leaves the plot area to the data. And the metric chips sit *below*
/// the chart because they select what the chart above them shows — a chip row
/// above the plot reads as a filter applied to the whole screen.
struct RatingChartCard: View {

    @Bindable var model: ProfileModel

    private var series: ProfileChartSeries { model.series }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            plot
            metricChips
            rangeRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ProfileStyle.cardCornerRadius, style: .continuous)
                .fill(.quaternary)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.metric.symbol)
                    .font(.caption)
                Eyebrow(text: model.metric.title)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headlineValue)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(headlineDate)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if let typical = series.typicalRange {
                    // Stated, not drawn. "Typical" is descriptive of this
                    // window's own values — see `ProfileChartSeries.typicalRange`
                    // for why it is not a population claim.
                    Text("Typical \(model.metric.formatCompact(typical.lowerBound))–\(model.metric.formatCompact(typical.upperBound))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var headlineValue: String {
        guard let latest = series.latest else { return "—" }
        return model.metric.format(latest.value)
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
                .frame(height: 168)
        } else {
            // A single point is not a trend, and a chart drawn through one dot
            // invites the reader to imagine the line.
            MeasurementPlaceholder(
                message: model.seriesState.message ?? "Nothing to plot yet",
                symbol: "chart.line.flattrend.xyaxis"
            )
            .frame(height: 168, alignment: .center)
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
                    .foregroundStyle(Color.accentColor.opacity(0.13))
                    .interpolationMethod(.monotone)
                }
            }

            ForEach(series.points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(model.metric.title, point.value)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            if let average = series.average {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    // The label rides on the line itself rather than sitting in
                    // a legend: a legend for one dashed rule is chart junk.
                    .annotation(position: .top, alignment: .trailing, spacing: -9) {
                        Text("Avg. \(model.metric.formatCompact(average))")
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.background))
                            .overlay(Capsule().strokeBorder(.quaternary))
                    }
            }
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: series.valueDomain ?? 0...1)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXScale(domain: series.interval.start...series.interval.end)
    }

    // MARK: - Metric chips

    private var metricChips: some View {
        HStack(spacing: 8) {
            ForEach(ProfileChartMetric.allCases) { candidate in
                Button {
                    model.metric = candidate
                } label: {
                    Text(candidate.title)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                candidate == model.metric
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                    : AnyShapeStyle(.quaternary)
                            )
                        )
                        .foregroundStyle(candidate == model.metric ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(candidate == model.metric ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Time range

    private var rangeRow: some View {
        HStack(spacing: 8) {
            ForEach(ProfileTimeRange.allCases) { candidate in
                Button {
                    model.range = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(candidate == model.range ? Color.primary : Color.secondary)
                        .frame(minWidth: 28)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(candidate == model.range ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            stepper(symbol: "chevron.left", delta: 1, enabled: model.canStepBack)
            stepper(symbol: "chevron.right", delta: -1, enabled: model.canStepForward)
        }
    }

    private func stepper(symbol: String, delta: Int, enabled: Bool) -> some View {
        Button {
            model.step(delta)
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(delta > 0 ? "Earlier \(model.range.rawValue)" : "Later \(model.range.rawValue)")
    }
}
