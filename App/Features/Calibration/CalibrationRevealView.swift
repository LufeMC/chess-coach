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
/// saying what it means, the scale it sits on, whose scale that is, what the
/// starting rung trains, and one filled button. Read in that order it answers
/// "what am I?" and then "so what?", which is the order those questions arrive
/// in.
struct CalibrationRevealView: View {

    let progress: CalibrationProgress
    let estimate: CalibrationEstimate
    /// False when the result could not be written to the database, which the
    /// user is told here rather than discovering as a second calibration on the
    /// next launch.
    var wasSaved: Bool = true
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

                scaleNote

                rungCard

                if !wasSaved { notSavedNotice }

                // Names where this lands and what is on it. "Start training"
                // was a verb with no destination attached, on the one tap that
                // leaves calibration for a screen the user has never seen.
                Button("See today's plan", action: onStart)
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

            Text(marginNote)
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Text(interpretation)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spokenReading). \(interpretation)")
    }

    private var ratingPoints: Int { Int(estimate.rating.rounded()) }
    private var ratingText: String { "\(ratingPoints)" }

    /// Which scale this number is on, said next to the track that invites the
    /// comparison.
    ///
    /// Anyone arriving here with a Lichess or Chess.com rating in their head
    /// will read a bare 600–2000 track as that scale, and the calibration
    /// document (`Docs/humanizer-calibration.md`) is explicit that nobody has
    /// ever compared the two: the self-play measurement fixes the *spacing*
    /// between opponents and says nothing about where the whole ladder sits as a
    /// block. So the app can honestly claim the number moves the right way by
    /// the right amount, and cannot honestly claim it transfers. This sentence
    /// is the difference between those two claims, and it goes away the day the
    /// anchoring in that document is done.
    static let scaleCaveat = "This is Rookly's own scale. It has never been lined up against a Lichess or Chess.com rating, so read it as where you stand here rather than as a number to carry elsewhere."

    private var scaleNote: some View {
        Text(Self.scaleCaveat)
            .typeRole(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The ± as it is displayed: the standard error rounded **up** to the
    /// nearest 25 points.
    ///
    /// Both halves are deliberate. The raw figure lands on numbers like 112,
    /// whose final digit is arithmetic rather than measurement — nothing about
    /// five games and twenty puzzles resolves a single rating point, and a
    /// screen that prints one is claiming otherwise. And rounding up rather than
    /// to the nearest means the displayed bar can only ever be wider than the
    /// computed one, which is the same direction the rung banding already errs
    /// in and the only direction in which being wrong here is cheap.
    private var marginPoints: Int {
        max(25, Int((estimate.sigma / 25).rounded(.up)) * 25)
    }

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
        return Denominator(value: ratingText, denominator: "± \(marginPoints)")
    }

    /// What the ± means, spelled out rather than left as a symbol.
    ///
    /// "± 125" is a shape most readers skip past on the way to the big number,
    /// which is exactly the misreading the margin exists to prevent. The range
    /// states the same fact in numbers that need no decoding, and the odds are
    /// the actual content of a one-standard-error bar: about two runs in three
    /// land inside it. Said as odds because that is the form a club player can
    /// do something with — it is the difference between "1240" and "somewhere in
    /// this 250-point window, probably".
    private var marginNote: String {
        let games = progress.required.first ?? 5
        let puzzles = progress.required.last ?? 20
        if estimate.ceilingNotFound || estimate.floorNotFound {
            return "Measured over \(games) games and \(puzzles) puzzles."
        }
        return "Most likely between \(ratingPoints - marginPoints) and \(ratingPoints + marginPoints) — roughly a two-in-three chance your real strength is inside that range. Measured over \(games) games and \(puzzles) puzzles, and it narrows as you play."
    }

    private var spokenReading: String {
        if estimate.ceilingNotFound { return "At least \(ratingText)" }
        if estimate.floorNotFound { return "Around \(ratingText) or lower" }
        return "\(ratingText), give or take \(marginPoints)"
    }

    /// What the number means and where training starts.
    ///
    /// The band and the rung are *not* the same reading, and the sentence used
    /// to imply they were: the chip names the band the estimate falls in, while
    /// the rung is banded on `r − 0.5σ`, so anything within half a sigma above a
    /// boundary was shown "that is the club band, and it puts you on rung 2" —
    /// two placements, one of them contradicting the chip a centimetre above it.
    /// Widening σ to include the puzzle-to-playing conversion made that window
    /// wider still. So when the two disagree the sentence says so and says why,
    /// which is also the only place the deliberate pessimism in the placement
    /// ever gets explained to the person it is being applied to.
    private var interpretation: String {
        let rungCount = Curriculum.default.count
        if estimate.ceilingNotFound {
            return "You won every calibration game, so that is a floor rather than a reading: your starting point is set at the strongest opponent you beat, on rung \(estimate.startingRung) of \(rungCount). Expect the first games here to be harder than those were."
        }
        if estimate.floorNotFound {
            return "Those games were harder than they needed to be. Training starts below that number, on rung \(estimate.startingRung) of \(rungCount), and moves up the moment the results say to."
        }

        let band = scaleGeometry.bandName().lowercased()
        guard estimate.startingRung < scaleGeometry.bandRung() else {
            return "That is the \(band) band, and it is where training starts: rung \(estimate.startingRung) of \(rungCount), the ladder the training follows. The number moves after every game you play here."
        }
        return "That is the \(band) band, but training starts lower, on rung \(estimate.startingRung) of \(rungCount). You are close enough to the line between two rungs that \(progress.required.first ?? 5) games and \(progress.required.last ?? 20) puzzles cannot say which side you are on — and starting a rung low costs a couple of easy weeks, where starting a rung high stalls the ladder entirely. The number moves after every game you play here."
    }

    /// The write failed.
    ///
    /// Stated rather than swallowed: the completion marker is what closes the
    /// calibration gate, so a user who is not told this meets all five games and
    /// twenty puzzles again on the next launch with no explanation for it.
    private var notSavedNotice: some View {
        Text("This result could not be saved on this device, so calibration will ask for it again next time you open the app. Nothing you did was lost.")
            .typeRole(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    private var scaleGeometry: PositioningScaleGeometry {
        PositioningScaleGeometry(estimate: estimate.rating, sigma: estimate.sigma)
    }

    // MARK: Starting rung

    /// What the rung trains, as plain rows, which is also where "rung" gets
    /// defined: the word arrives for the first time two lines above this card,
    /// and a reader who meets it here sees a title and the skills it holds
    /// rather than a term of art.
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

/// The case the sentence used to contradict itself on: 1420 is in the club band,
/// but `1420 − 0.5 × 150` bands to rung 2.
#Preview("Just over a boundary") {
    CalibrationRevealView(
        progress: CalibrationProgress(required: [5, 20], completed: [5, 20], phaseIndex: 1),
        estimate: CalibrationEstimate(
            rating: 1420,
            sigma: 150,
            gameEstimate: 1480,
            gameSigma: 180,
            puzzleEstimate: 1360,
            puzzleSigma: 105,
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
