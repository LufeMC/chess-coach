//
//  PositioningScale.swift
//  ChessCoach
//

import BoardUI
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
        return names[min(bandIndex(tuning: tuning), names.count - 1)]
    }

    /// The rung the band name corresponds to, 1-based.
    ///
    /// The names and the rungs are cut on the *same* boundaries, so this is the
    /// rung the user would start on if the placement were read straight off the
    /// estimate. It exists because the placement is **not** read straight off:
    /// ``CalibrationCombiner/startingRung(rating:sigma:tuning:)`` bands
    /// `r − 0.5σ` instead, which near a boundary lands a rung lower than the
    /// chip says. The reveal compares the two so it can say which happened,
    /// rather than asserting both placements in one breath and leaving the
    /// reader to notice they disagree.
    func bandRung(tuning: DomainTuning.Calibration = DomainTuning.default.calibration) -> Int {
        bandIndex(tuning: tuning) + 1
    }

    private func bandIndex(tuning: DomainTuning.Calibration) -> Int {
        var index = 0
        for boundary in tuning.rungBoundaries where estimate >= boundary { index += 1 }
        return index
    }
}

/// The positioning scale.
///
/// Binance's asset-positioning bar: a recessed track with its endpoints
/// labelled, a circular marker, and a floating chip naming the band. One visual
/// on the whole reveal screen — the rest is a number, a sentence and the rung,
/// because a placement result is one measurement and dressing it up would
/// suggest otherwise.
///
/// The track carries no gradient. A colour ramp along it would say "right is
/// better", which the endpoint labels already say in numbers, and would spend
/// the screen's accent on the two thirds of the scale the user is not on. All
/// the colour goes to the one thing being reported: where they are, and how
/// wide that is.
struct PositioningScale: View {

    let geometry: PositioningScaleGeometry
    var lowLabel: String
    var highLabel: String

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width

                ZStack(alignment: .topLeading) {
                    // Chip, floating above the marker. `position` centres it on
                    // the point, so it tracks the marker without an alignment
                    // guide; the inset keeps it inside the track at the extremes.
                    Text(geometry.bandName())
                        .typeRole(.label, appliesForeground: false)
                        .foregroundStyle(Palette.accent.dynamic)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.accent.opacity(0.14).dynamic))
                        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.4).dynamic, lineWidth: 1))
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
            .typeRole(.caption, monospacedDigits: true)
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
                .fill(Palette.surfaceSunken.dynamic)
                .frame(height: 10)

            // The ±1σ region. Tinted rather than lightened: on a recessed track
            // a white overlay is the same value as the ground in one appearance
            // and invisible in the other, and the band is the honest half of
            // this drawing — it cannot be the half that disappears.
            Capsule()
                .fill(Palette.accent.opacity(0.28).dynamic)
                .frame(width: max(2, width * geometry.bandWidthFraction), height: 10)
                .offset(x: width * geometry.bandStartFraction)

            Circle()
                .fill(Palette.accent.dynamic)
                .overlay(Circle().strokeBorder(Palette.surfaceGround.dynamic, lineWidth: 2.5))
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
    .background(Palette.surfaceGround.dynamic)
}
