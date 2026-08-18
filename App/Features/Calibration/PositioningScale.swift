//
//  PositioningScale.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Where the calibration result sits on the scale, as pure numbers.
///
/// ## Why the band is not optional
///
/// The estimate comes from five games and twenty puzzles.
/// `CalibrationCombiner` reports its standard error precisely *because* a number
/// from a sample that small is not a point — a 5-game estimate carries a sigma
/// near 180, and a clean sweep near 250. Drawing a bare marker would take a
/// range two hundred points wide and present it as a fact, and the user would
/// then reasonably feel misled the first time a game went against it.
///
/// So the marker is drawn inside a lighter region spanning ±1σ. That is not
/// decoration: it is the difference between "you are 1240" and "you are around
/// 1240, give or take", and only one of those is true.
struct PositioningScaleGeometry: Sendable, Hashable {

    /// The scale's endpoints.
    var range: ClosedRange<Double>
    var estimate: Double
    /// Standard error of the estimate.
    var sigma: Double

    init(
        range: ClosedRange<Double> = 600...2000,
        estimate: Double,
        sigma: Double
    ) {
        self.range = range
        self.estimate = estimate
        self.sigma = max(0, sigma)
    }

    private var span: Double { max(1, range.upperBound - range.lowerBound) }

    /// Position of a rating on the track, clamped to 0...1.
    func fraction(of value: Double) -> Double {
        min(1, max(0, (value - range.lowerBound) / span))
    }

    var markerFraction: Double { fraction(of: estimate) }

    /// The ±1σ region, clamped to the visible scale.
    ///
    /// Clamping rather than letting it run off the end: an estimate near the
    /// floor with a wide sigma would otherwise produce a negative start, and a
    /// band that visually leaves the track is a drawing bug the reader will
    /// interpret as data.
    var bandStartFraction: Double { fraction(of: estimate - sigma) }
    var bandEndFraction: Double { fraction(of: estimate + sigma) }
    var bandWidthFraction: Double { max(0, bandEndFraction - bandStartFraction) }

    /// The band the chip names.
    func bandName(tuning: DomainTuning.Calibration = DomainTuning.default.calibration) -> String {
        let names = ["Beginner", "Improver", "Club", "Strong club"]
        var index = 0
        for boundary in tuning.rungBoundaries where estimate >= boundary { index += 1 }
        return names[min(index, names.count - 1)]
    }
}

/// The positioning scale.
///
/// Binance's asset-positioning bar: a horizontal gradient with its endpoints
/// labelled, a circular marker, and a floating chip naming the band. One visual
/// on the whole reveal screen — the rest is a sentence and a ladder section,
/// because a placement result is one number and dressing it up would suggest
/// otherwise.
struct PositioningScale: View {

    let geometry: PositioningScaleGeometry
    var lowLabel: String
    var highLabel: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width

                ZStack(alignment: .topLeading) {
                    // Chip, floating above the marker. `position` centres it on
                    // the point, so it tracks the marker without an alignment
                    // guide; the inset keeps it inside the track at the extremes.
                    Text(geometry.bandName())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
                        .fixedSize()
                        .position(x: chipCentre(in: width), y: 12)

                    track(width: width)
                        .position(x: width / 2, y: 40)
                }
            }
            .frame(height: 52)

            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Half the widest band name at `.caption`, near enough. Only used to keep
    /// the chip on screen at the extremes.
    private static let chipHalfWidth: CGFloat = 44

    private func chipCentre(in width: CGFloat) -> CGFloat {
        let ideal = width * geometry.markerFraction
        return min(max(Self.chipHalfWidth, ideal), max(Self.chipHalfWidth, width - Self.chipHalfWidth))
    }

    private func track(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.25),
                            Color.accentColor.opacity(0.85)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 10)

            // The ±1σ region.
            Capsule()
                .fill(.white.opacity(colorScheme == .dark ? 0.28 : 0.55))
                .frame(width: max(2, width * geometry.bandWidthFraction), height: 10)
                .offset(x: width * geometry.bandStartFraction)

            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(.background, lineWidth: 2.5))
                .frame(width: 16, height: 16)
                .offset(x: width * geometry.markerFraction - 8)
        }
        .frame(width: width, height: 16)
    }
}

#Preview {
    PositioningScale(
        geometry: PositioningScaleGeometry(estimate: 1240, sigma: 150),
        lowLabel: "600",
        highLabel: "2000"
    )
    .padding(32)
}
