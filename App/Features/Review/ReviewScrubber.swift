import BoardUI
import Charts
import ChessKit
import SwiftUI

/// The evaluation curve, doubling as the screen's scrubber.
///
/// Not `EvalGraphView`. That component is a 190pt *chart* with a numeric-free
/// but judgemental axis ("Winning / Equal / Losing"), tooltips, and a curve that
/// flips to the reader's colour. This is a 94pt *control*: it is dragged, it is
/// read from a fixed White-at-top perspective so the shape of the game is the
/// same object every time, and it carries the phase segments that tell you which
/// part of the game you are looking at. Same data type (`EvalPoint`), different
/// instrument.
struct ReviewScrubber: View {

    let points: [EvalPoint]
    let segments: [ReviewPhaseSegment]
    /// Position index → grade, for the dots on the curve.
    let moments: [Int: BoardUI.MoveClassification]
    @Binding var index: Int
    let style: BoardStyle

    @Environment(\.colorScheme) private var colorScheme

    /// Curve height. The whole control lands at 94pt, inside the 88–104 band the
    /// layout budget allows between a pinned board and the scrolling content.
    private let curveHeight: CGFloat = 70
    private let phaseHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            axisLabels
            VStack(spacing: 6) {
                curve
                    .frame(height: curveHeight)
                phaseStrip
                    .frame(height: phaseHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Evaluation"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index += 1
            case .decrement: index -= 1
            @unknown default: break
            }
        }
    }

    // MARK: - Axis

    /// Two words, no numbers. Which side is ahead is the only question this axis
    /// has to answer; "+1.4" belongs in the move table, where it can be compared
    /// against the move that caused it.
    private var axisLabels: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("White")
            Spacer(minLength: 0)
            Text("Black")
        }
        .typeRole(.caption, appliesForeground: false)
        .foregroundStyle(.tertiary)
        .frame(width: 42, height: curveHeight, alignment: .leading)
    }

    // MARK: - Curve

    private var curve: some View {
        Chart {
            // The "effectively equal" band: anything inside half a pawn. Without
            // it every quiet game looks like a mountain range, because the curve
            // is autoscaled and 0.2 pawns of engine noise fills the frame.
            RectangleMark(
                xStart: .value("Start", domain.lowerBound),
                xEnd: .value("End", domain.upperBound),
                yStart: .value("Low", -ReviewEvalFormat.equalBandWinPercent),
                yEnd: .value("High", ReviewEvalFormat.equalBandWinPercent)
            )
            .foregroundStyle(.quaternary)

            ForEach(points) { point in
                AreaMark(
                    x: .value("Ply", point.ply),
                    y: .value("Advantage", advantage(point))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [accent.opacity(0.28), accent.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Ply", point.ply),
                    y: .value("Advantage", advantage(point))
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .foregroundStyle(accent)
            }

            // Hairline, solid, no label: it is a reference, not a data series.
            RuleMark(y: .value("Equal", 0))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(.secondary.opacity(0.45))

            ForEach(momentMarks) { mark in
                PointMark(
                    x: .value("Ply", mark.point.ply),
                    y: .value("Advantage", advantage(mark.point))
                )
                .symbolSize(46)
                .foregroundStyle(mark.classification.color(in: style).color(colorScheme))
            }

            RuleMark(x: .value("Selected", clampedIndex))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(.secondary.opacity(0.7))

            if let selected = points.first(where: { $0.ply == clampedIndex }) {
                PointMark(
                    x: .value("Ply", selected.ply),
                    y: .value("Advantage", advantage(selected))
                )
                .symbolSize(70)
                .foregroundStyle(accent)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: -50...50)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        // Hiding both axes makes the plot area the full frame, which is what lets
        // the phase strip below line up with the curve by simple proportion.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { scrub(to: $0.location, proxy: proxy, geometry: geometry) }
                    )
            }
        }
        .animation(.snappy(duration: 0.16), value: clampedIndex)
    }

    // MARK: - Phases

    /// Opening / Middlegame / Endgame as proportional spans under the curve.
    ///
    /// A chip inside the span rather than a legend beside it: a legend would make
    /// the reader map three colours onto three words, and the spans are already
    /// where the words belong.
    private var phaseStrip: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(segments) { segment in
                    let width = max(0, proxy.size.width * fraction(of: segment) - 3)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: width)
                        .overlay(alignment: .leading) {
                            // Dropped rather than truncated when the span is
                            // short: "Ope…" is noise, and the neighbours already
                            // establish the order.
                            if width > 76 {
                                Text(segment.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 7)
                            }
                        }
                }
            }
        }
    }

    private func fraction(of segment: ReviewPhaseSegment) -> Double {
        let total = Double(max(1, domain.upperBound - domain.lowerBound + 1))
        return Double(segment.range.count) / total
    }

    // MARK: - Helpers

    private var accent: Color { style.accent.color(colorScheme) }

    private var domain: ClosedRange<Int> {
        let high = max(points.last?.ply ?? 1, 1)
        return 0...high
    }

    private var clampedIndex: Int {
        min(max(index, domain.lowerBound), domain.upperBound)
    }

    /// Distance from equality, −50…+50, positive meaning White. `EvalPoint` is
    /// already White-relative (`ReviewEvalTrack` did the conversion), so there is
    /// no sign flip here — deliberately. Flipping to the reader's colour would
    /// make two games with the same shape look different depending on which side
    /// they were played from.
    private func advantage(_ point: EvalPoint) -> Double {
        min(100, max(0, point.winPercent)) - 50
    }

    private struct MomentMark: Identifiable {
        var point: EvalPoint
        var classification: BoardUI.MoveClassification
        var id: Int { point.ply }
    }

    private var momentMarks: [MomentMark] {
        points.compactMap { point in
            guard let classification = moments[point.ply] else { return nil }
            return MomentMark(point: point, classification: classification)
        }
    }

    private func scrub(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let x = location.x - geometry[plotFrame].origin.x
        guard let raw: Double = proxy.value(atX: x) else { return }
        let snapped = Int(raw.rounded())
        let bounded = min(max(snapped, domain.lowerBound), domain.upperBound)
        if bounded != index { index = bounded }
    }

    private var accessibilityValue: String {
        let moveNumber = (clampedIndex + 1) / 2
        guard let percent = points.first(where: { $0.ply == clampedIndex })?.winPercent else {
            return "Move \(moveNumber)"
        }
        let side = percent >= 50 ? "White" : "Black"
        return "Move \(moveNumber), \(side) \(Int(abs(percent - 50) * 2)) percent"
    }
}

#Preview("Scrubber") {
    @Previewable @State var index = 18

    let shape: [Double] = [
        50, 52, 51, 54, 53, 55, 58, 56, 60, 59, 62, 61, 64, 63, 66, 40, 42, 41,
        44, 43, 46, 45, 30, 32, 31, 34, 33, 36, 12, 14, 13, 16, 15, 18, 17, 8,
    ]

    return ReviewScrubber(
        points: shape.enumerated().map { EvalPoint(ply: $0.offset, winPercent: $0.element) },
        segments: [
            ReviewPhaseSegment(phase: .opening, range: 0...20),
            ReviewPhaseSegment(phase: .middlegame, range: 21...30),
            ReviewPhaseSegment(phase: .endgame, range: 31...35),
        ],
        moments: [15: .blunder, 22: .mistake, 28: .inaccuracy],
        index: $index,
        style: .default
    )
    .padding()
}
