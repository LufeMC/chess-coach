//
//  CalibrationRevealView.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// The result of calibration.
///
/// Restraint, plus one visual. A placement result is a single number with an
/// error bar attached; the temptation to celebrate it is exactly the temptation
/// `Docs/design-conventions.md` rules out — no confetti, no stars, no donut.
///
/// So: one sentence with the number bolded inline, the positioning scale, the
/// starting rung as a ladder section in its resting state, and one filled CTA.
struct CalibrationRevealView: View {

    let estimate: CalibrationEstimate
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headline

                PositioningScale(
                    geometry: scaleGeometry,
                    lowLabel: "\(Int(scaleGeometry.range.lowerBound))",
                    highLabel: "\(Int(scaleGeometry.range.upperBound))"
                )

                ladderSection

                Button(action: onStart) {
                    Text("Start training")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    // MARK: Headline

    /// One sentence, the number bolded inline.
    ///
    /// The `± σ` rides in the same sentence rather than in fine print
    /// underneath. It is not a caveat the app is obliged to disclose — it is
    /// part of the measurement, and a reader who takes the bold number and skips
    /// the small print has been given a wrong impression by the layout.
    private var headline: some View {
        Group {
            if estimate.ceilingNotFound {
                Text("You won every game, so your rating is at least ")
                    + boldRating
                    + Text(" — we'll keep raising the opponent as you play.")
            } else if estimate.floorNotFound {
                Text("These games were too hard. We'll start you around ")
                    + boldRating
                    + Text(" and move up from there.")
            } else {
                Text("You're playing around ")
                    + boldRating
                    + Text(", give or take \(Int(estimate.sigma.rounded())).")
            }
        }
        .font(.title3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var boldRating: Text {
        Text("\(Int(estimate.rating.rounded()))")
            .font(.title3.bold().monospacedDigit())
    }

    private var scaleGeometry: PositioningScaleGeometry {
        PositioningScaleGeometry(estimate: estimate.rating, sigma: estimate.sigma)
    }

    // MARK: Ladder

    /// The starting rung, expanded, in its resting state.
    ///
    /// Reuses Profile's accordion component rather than duplicating it: the
    /// state is built from an **empty** `MetricSnapshot`, which is the truthful
    /// input here — nothing has been measured yet, so every skill reports
    /// "unmeasured" rather than a zero that would read as failure.
    private var ladderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state = ladderState {
                CurriculumLadderSection(state: state, onToggle: { _ in })
            }
        }
    }

    private var ladderState: CurriculumLadderState? {
        guard let rung = Curriculum.rung(estimate.startingRung) else { return nil }
        let full = CurriculumLadderState(
            ladder: [rung],
            currentRung: estimate.startingRung,
            metrics: MetricSnapshot(),
            blockers: []
        )
        return full
    }
}

#Preview {
    CalibrationRevealView(
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
