//
//  CalibrationRevealView.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// The result of calibration.
///
/// ## Instrument panel, not a trophy cabinet
///
/// This is the emotional payload of the whole first run, and the temptation is
/// to treat it as a win: confetti, a modal, a mascot with something encouraging
/// to say. All three are ruled out, and not only on taste grounds — a
/// celebration frames the number as a *verdict the user has received*, and the
/// entire premise of the app is that the number is a starting position they are
/// about to move. Confetti at 900 is condescending and confetti at 1600 is
/// premature.
///
/// So: the number at hero size with its margin dropped a tier, one sentence
/// saying what it means, the scale it sits on, what the starting rung trains,
/// and one filled button. Read in that order it answers "what am I?" and then
/// "so what?", which is the order those questions arrive in.
struct CalibrationRevealView: View {

    let progress: CalibrationProgress
    let estimate: CalibrationEstimate
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CalibrationHeader(progress: progress, step: .result)

                reading

                PositioningScale(
                    geometry: scaleGeometry,
                    lowLabel: "\(Int(scaleGeometry.range.lowerBound))",
                    highLabel: "\(Int(scaleGeometry.range.upperBound))"
                )

                rungCard

                Button("Start training", action: onStart)
                    .buttonStyle(.primaryAction)
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
    }

    // MARK: The number

    /// The number, then what it means.
    ///
    /// The margin rides in the same reading rather than in fine print
    /// underneath. It is not a caveat the app is obliged to disclose — it is
    /// part of the measurement, and a reader who takes the big number and skips
    /// the small print has been given a wrong impression by the layout.
    private var reading: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Your rating", qualifier: scaleGeometry.bandName())

            DenominatorText(margin, role: .display)

            Text(interpretation)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spokenReading). \(interpretation)")
    }

    private var ratingText: String { "\(Int(estimate.rating.rounded()))" }

    /// A clean sweep in either direction is a *bound*, not a point, and the
    /// denominator is where that gets said. `± 250` under a number the games
    /// never actually bracketed would be a precision the measurement does not
    /// have.
    private var margin: Denominator {
        if estimate.ceilingNotFound {
            return Denominator(value: ratingText, denominator: "or better")
        }
        if estimate.floorNotFound {
            return Denominator(value: ratingText, denominator: "or lower")
        }
        return Denominator(value: ratingText, denominator: "± \(Int(estimate.sigma.rounded()))")
    }

    private var spokenReading: String {
        if estimate.ceilingNotFound { return "At least \(ratingText)" }
        if estimate.floorNotFound { return "Around \(ratingText) or lower" }
        return "\(ratingText), give or take \(Int(estimate.sigma.rounded()))"
    }

    private var interpretation: String {
        if estimate.ceilingNotFound {
            return "You won every calibration game, so that is a floor rather than a reading. Opponents keep climbing from here until one of them holds you."
        }
        if estimate.floorNotFound {
            return "Those games were harder than they needed to be. Training starts below that number and moves up the moment the results say to."
        }
        return "That is the \(scaleGeometry.bandName().lowercased()) band, and it puts you on rung \(estimate.startingRung) of \(Curriculum.default.count). The number moves after every rated game from here."
    }

    private var scaleGeometry: PositioningScaleGeometry {
        PositioningScaleGeometry(estimate: estimate.rating, sigma: estimate.sigma)
    }

    // MARK: Starting rung

    /// What the rung trains, as plain rows.
    ///
    /// Deliberately *not* the ladder's checklist. Nothing has been measured yet,
    /// so every skill would render unmet — and a column of empty checkboxes is
    /// the first thing a new user sees presented as a list of things they cannot
    /// do. The same content stated as "this is what you work on" says the same
    /// thing and reads as a plan.
    @ViewBuilder
    private var rungCard: some View {
        if let rung = Curriculum.rung(estimate.startingRung) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Starting here", qualifier: "Rung \(rung.id)")

                VStack(alignment: .leading, spacing: 12) {
                    Text(rung.title)
                        .typeRole(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rung.requiredSkills.prefix(4)) { skill in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .strokeBorder(
                                        Palette.hairlinePending.dynamic,
                                        style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])
                                    )
                                    .frame(width: 7, height: 7)
                                Text(skill.title)
                                    .typeRole(.body, appliesForeground: false)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .elevation(.raised, cornerRadius: CornerRadius.card)
            }
        }
    }
}

#Preview("Measured") {
    CalibrationRevealView(
        progress: CalibrationProgress(required: [5, 20], completed: [5, 20], phaseIndex: 1),
        estimate: CalibrationEstimate(
            rating: 1240,
            sigma: 145,
            gameEstimate: 1300,
            gameSigma: 180,
            puzzleEstimate: 1180,
            puzzleSigma: 190,
            ceilingNotFound: false,
            floorNotFound: false,
            startingRung: 2
        ),
        onStart: {}
    )
}

#Preview("Clean sweep") {
    CalibrationRevealView(
        progress: CalibrationProgress(required: [5, 20], completed: [5, 20], phaseIndex: 1),
        estimate: CalibrationEstimate(
            rating: 1720,
            sigma: 260,
            gameEstimate: 1800,
            gameSigma: 300,
            puzzleEstimate: 1650,
            puzzleSigma: 210,
            ceilingNotFound: true,
            floorNotFound: false,
            startingRung: 4
        ),
        onStart: {}
    )
}
