//
//  CalibrationTests.swift
//  ChessCoachTests
//

import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// MARK: - Seeding

@Suite("Calibration seeding")
struct CalibrationSeedTests {

    /// The whole point of asking before testing: the two ends of the
    /// distribution skip ahead instead of spending games discovering something
    /// the user already told us.
    @Test("The self-assessment moves the starting opponent in both directions")
    func seedSpansTheDistribution() {
        #expect(CalibrationSeed.opponentRating(for: nil) == 1100)
        #expect(CalibrationSeed.opponentRating(for: .new) == 800)
        #expect(CalibrationSeed.opponentRating(for: .knowsTheMoves) == 1000)
        #expect(CalibrationSeed.opponentRating(for: .playsRegularly) == 1200)
        #expect(CalibrationSeed.opponentRating(for: .competitive) == 1500)
    }

    @Test("The seed is monotone in the answer")
    func seedIsMonotone() {
        let seeds = ChessExperience.allCases.map { CalibrationSeed.opponentRating(for: $0) }
        #expect(seeds == seeds.sorted())
        #expect(ChessExperience.allCases.map(\.bars) == [1, 2, 3, 4])
    }

    /// Puzzle ratings run hot relative to playing strength, so the puzzle seed
    /// sits above the playing seed by exactly the offset the combiner uses to
    /// convert back.
    @Test("The puzzle seed is the playing seed converted onto the puzzle scale")
    func puzzleSeedUsesTheCombinersOffset() {
        let offset = DomainTuning.default.calibration.puzzleRatingOffset
        #expect(CalibrationSeed.puzzleRating(for: .playsRegularly) == 1200 - Int(offset))
        #expect(offset < 0)
    }

    @Test("The opponent ladder moves a hundred points per decisive result")
    func ladderStep() {
        #expect(CalibrationSeed.nextOpponentRating(current: 1100, outcome: .win) == 1200)
        #expect(CalibrationSeed.nextOpponentRating(current: 1100, outcome: .loss) == 1000)
    }

    /// A draw is the one result saying the two sides are already close; moving
    /// the ladder would throw that away.
    @Test("A draw holds the ladder still")
    func drawHolds() {
        #expect(CalibrationSeed.nextOpponentRating(current: 1100, outcome: .draw) == 1100)
    }

    /// The floor is where the *measured* profiles stop, not an arbitrary low
    /// number. `Humanizer.Profile.anchors` starts at 800 and clamps below it, so
    /// a ladder that walked to 600 would show "Opponent 600" and feed 600 into
    /// `mean(opponentRatings)` while the 800 profile played every move.
    @Test("The opponent ladder floors at the weakest profile the engine has")
    func ladderFloor() {
        #expect(CalibrationSeed.weakestOpponent == 800)
        #expect(CalibrationSeed.nextOpponentRating(current: 900, outcome: .loss) == 800)
        #expect(CalibrationSeed.nextOpponentRating(current: 800, outcome: .loss) == 800)
        // The gentlest seed and the floor are the same number by construction.
        #expect(CalibrationSeed.opponentRating(for: .new) == CalibrationSeed.weakestOpponent)
        #expect(CalibrationSeed.nextPuzzleRating(current: 420, solved: false) == 400)
    }
}

// MARK: - Phase progression

@Suite("Calibration progress")
struct CalibrationProgressTests {

    private func progress(games: Int = 0, puzzles: Int = 0, phase: Int = 0) -> CalibrationProgress {
        CalibrationProgress(required: [5, 20], completed: [games, puzzles], phaseIndex: phase)
    }

    @Test("The header counts the item being worked on, inside its phase")
    func headerCounter() {
        #expect(progress().counterLabel == "Game 1 of 5")
        #expect(progress(games: 2).counterLabel == "Game 3 of 5")
        #expect(progress(games: 5, puzzles: 8, phase: 1).counterLabel == "Puzzle 9 of 20")
    }

    /// The sectioned bar's entire job: "most of the way through part 1" and
    /// "there are 2 parts", read from one glance.
    @Test("Only the current section fills")
    func sectionFractions() {
        #expect(progress(games: 4).sectionFractions == [0.8, 0])
        #expect(progress(games: 5, puzzles: 5, phase: 1).sectionFractions == [1, 0.25])
    }

    @Test("Sections are equal width regardless of item count")
    func equalWeights() {
        #expect(progress().sectionWeights == [1, 1])
    }

    @Test("Filling a phase advances to the next one")
    func phaseAdvances() {
        var value = progress()
        for _ in 0..<5 { value.recordItem() }
        #expect(value.phaseIndex == 1)
        #expect(value.phase == .puzzles)
        #expect(value.sectionFractions == [1, 0])
        #expect(!value.isComplete)
    }

    @Test("The last phase does not advance past itself")
    func lastPhaseHolds() {
        var value = progress(games: 5, phase: 1)
        for _ in 0..<20 { value.recordItem() }
        #expect(value.phaseIndex == 1)
        #expect(value.isComplete)
        #expect(value.sectionFractions == [1, 1])
    }
}

// MARK: - Positioning scale

@Suite("Positioning scale")
struct PositioningScaleTests {

    @Test("The marker sits proportionally along the track")
    func markerPosition() {
        let geometry = PositioningScaleGeometry(range: 600...2000, estimate: 1300, sigma: 0)
        #expect(abs(geometry.markerFraction - 0.5) < 0.0001)
    }

    /// Drawing a bare point for an estimate with a ±180 standard error would
    /// overstate a five-game measurement. The band is the honest part.
    @Test("The band spans one sigma either side of the estimate")
    func bandSpansOneSigma() {
        let geometry = PositioningScaleGeometry(range: 600...2000, estimate: 1300, sigma: 140)
        #expect(abs(geometry.bandStartFraction - 0.4) < 0.0001)
        #expect(abs(geometry.bandEndFraction - 0.6) < 0.0001)
        #expect(abs(geometry.bandWidthFraction - 0.2) < 0.0001)
    }

    @Test("A band running past the ends is clamped rather than drawn off-track")
    func bandClamps() {
        let low = PositioningScaleGeometry(range: 600...2000, estimate: 650, sigma: 250)
        #expect(low.bandStartFraction == 0)
        #expect(low.bandWidthFraction > 0)

        let high = PositioningScaleGeometry(range: 600...2000, estimate: 1950, sigma: 250)
        #expect(high.bandEndFraction == 1)
        #expect(high.markerFraction <= 1)
    }

    @Test("A zero-sigma estimate produces no band")
    func noSigmaNoBand() {
        let geometry = PositioningScaleGeometry(range: 600...2000, estimate: 1300, sigma: 0)
        #expect(geometry.bandWidthFraction == 0)
    }

    @Test("The chip names the band the rung boundaries define")
    func bandNames() {
        #expect(PositioningScaleGeometry(estimate: 900, sigma: 0).bandName() == "Beginner")
        #expect(PositioningScaleGeometry(estimate: 1100, sigma: 0).bandName() == "Improver")
        #expect(PositioningScaleGeometry(estimate: 1500, sigma: 0).bandName() == "Club")
        #expect(PositioningScaleGeometry(estimate: 1900, sigma: 0).bandName() == "Strong club")
    }

    /// The chip and the starting rung are cut on the same boundaries, so any
    /// disagreement between them is the `r − 0.5σ` shading and never a second
    /// opinion about the rating. The reveal leans on exactly that to decide
    /// whether it has one placement to report or two.
    @Test("The band's rung and the placed rung part company only where sigma shades it")
    func bandRungTracksTheSameBoundaries() {
        #expect(PositioningScaleGeometry(estimate: 900, sigma: 0).bandRung() == 1)
        #expect(PositioningScaleGeometry(estimate: 1000, sigma: 0).bandRung() == 2)
        #expect(PositioningScaleGeometry(estimate: 1400, sigma: 0).bandRung() == 3)
        #expect(PositioningScaleGeometry(estimate: 1800, sigma: 0).bandRung() == 4)

        // The case the reveal used to contradict itself on: 1420 is inside the
        // club band, and 1420 − 0.5 × 150 bands down to rung 2.
        #expect(PositioningScaleGeometry(estimate: 1420, sigma: 150).bandRung() == 3)
        #expect(CalibrationCombiner.startingRung(rating: 1420, sigma: 150) == 2)

        // Comfortably inside a band, the two agree and the reveal reports one
        // placement.
        #expect(PositioningScaleGeometry(estimate: 1600, sigma: 150).bandRung() == 3)
        #expect(CalibrationCombiner.startingRung(rating: 1600, sigma: 150) == 3)
    }
}

// MARK: - Flow

@MainActor
@Suite("Calibration flow")
struct CalibrationFlowTests {

    private func makeModel() -> (CalibrationModel, InMemoryAppSettingsStore, InMemoryMetricStore) {
        let settings = InMemoryAppSettingsStore()
        let metrics = InMemoryMetricStore()
        let model = CalibrationModel(
            store: StoredCalibrationOutcome(settings: settings, metrics: metrics),
            clock: { Date(timeIntervalSince1970: 1_000) }
        )
        return (model, settings, metrics)
    }

    @Test("The flow opens on the question, not on a board")
    func opensOnTheQuestion() {
        let (model, _, _) = makeModel()
        #expect(model.stage == .intro)
        #expect(model.opponentRating == CalibrationSeed.defaultOpponentRating)
    }

    @Test("Answering the question seeds both ladders")
    func answerSeeds() {
        let (model, _, _) = makeModel()
        model.select(.competitive)
        #expect(model.experience == .competitive)
        #expect(model.opponentRating == 1500)
        #expect(model.puzzleRating == CalibrationSeed.puzzleRating(for: .competitive))
    }

    /// The count was always there; the minutes were not, and the minutes are
    /// what a first-run user is being asked to commit. The first person went
    /// with them: no other screen has a narrating "I".
    @Test("The framing line is said once, states the cost, and does not console")
    func framingLine() {
        #expect(CalibrationModel.framingLine.contains("measurement, not a test"))
        #expect(!CalibrationModel.framingLine.contains("Don't worry"))
        #expect(CalibrationModel.framingLine.contains("15-minute"))
        #expect(!CalibrationModel.framingLine.contains("I'll"))
    }

    /// Drafts have always survived a quit. Nothing said so, which left the flow
    /// reading as an hour that has to be spent in one sitting.
    @Test("The cost line names the hour and says leaving is safe")
    func costLine() {
        #expect(CalibrationModel.costLine.contains("hour"))
        #expect(CalibrationModel.costLine.contains("picks up where you left off"))
    }

    /// "Why am I doing this" was answered for the first time by the reveal, an
    /// hour after it was asked.
    @Test("Step one says what the rating buys")
    func payoffLine() {
        #expect(CalibrationModel.payoffLine.contains("review"))
        #expect(CalibrationModel.payoffLine.contains("puzzles"))
    }

    /// `Docs/humanizer-calibration.md` measures the *spacing* between opponent
    /// profiles and explicitly cannot say where the ladder sits as a block, so
    /// until the anchoring described there is done the reveal must not let a
    /// 600–2000 track be read as a Lichess or Chess.com number. This is the one
    /// sentence standing between those two readings; deleting it is the
    /// regression.
    @Test("The reveal names whose scale the number is on")
    func revealNamesTheScale() {
        #expect(CalibrationRevealView.scaleCaveat.contains("Rookly's own scale"))
        #expect(CalibrationRevealView.scaleCaveat.contains("Lichess"))
        #expect(CalibrationRevealView.scaleCaveat.contains("Chess.com"))
    }

    @Test("Games are recorded against the opponent that was actually played")
    func gamesRecordTheirOpponent() {
        let (model, _, _) = makeModel()
        model.select(.knowsTheMoves)
        model.beginMeasurement()
        #expect(model.stage == .games)

        model.record(gameOutcome: .win)
        #expect(model.games.first?.opponentRating == 1000)
        #expect(model.opponentRating == 1100)

        model.record(gameOutcome: .loss)
        #expect(model.games.last?.opponentRating == 1100)
        #expect(model.opponentRating == 1000)
    }

    @Test("The flow moves to puzzles when the games are done")
    func gamesThenPuzzles() {
        let (model, _, _) = makeModel()
        model.beginMeasurement()
        for _ in 0..<5 { model.record(gameOutcome: .win) }

        #expect(model.stage == .puzzles)
        #expect(model.games.count == 5)
        #expect(model.progress.phase == .puzzles)
    }

    @Test("Answering the last puzzle produces the estimate")
    func completingProducesAnEstimate() {
        let (model, _, _) = makeModel()
        model.beginMeasurement()
        for _ in 0..<5 { model.record(gameOutcome: .win) }
        for index in 0..<20 {
            model.record(puzzleRating: 1200, solved: index.isMultiple(of: 2))
        }

        guard let estimate = model.estimate else {
            Issue.record("the flow should end in a reveal")
            return
        }
        #expect(model.progress.isComplete)
        #expect(estimate.sigma > 0)
        #expect((1...4).contains(estimate.startingRung))
    }

    /// Persisted the moment the measurement finishes, not on the reveal's CTA:
    /// a user who force-quits on the result screen must not be made to sit
    /// through calibration twice.
    @Test("The outcome is persisted as soon as it is measured")
    func persistsOnCompletion() throws {
        let (model, settings, metrics) = makeModel()
        model.beginMeasurement()
        for _ in 0..<5 { model.record(gameOutcome: .win) }
        for _ in 0..<20 { model.record(puzzleRating: 1200, solved: true) }

        let estimate = try #require(model.estimate)
        let stored = try settings.current()

        #expect(stored.userRating == estimate.rating)
        #expect(stored.currentRung == estimate.startingRung)
        #expect(metrics.counter(StoredCalibrationOutcome.completedKey) != nil)
    }

    /// The combiner reports the puzzle estimate already shifted onto the
    /// *playing* scale. Storing that number as the puzzle rating would move
    /// every future puzzle a hundred points out of band.
    @Test("The stored puzzle rating is on the puzzle scale, not the playing scale")
    func puzzleRatingIsStoredUnshifted() throws {
        let (model, settings, _) = makeModel()
        model.beginMeasurement()
        for _ in 0..<5 { model.record(gameOutcome: .draw) }
        for index in 0..<20 { model.record(puzzleRating: 1200, solved: index < 10) }

        let estimate = try #require(model.estimate)
        let stored = try settings.current()
        let offset = DomainTuning.default.calibration.puzzleRatingOffset
        #expect(abs(stored.puzzleRating - (estimate.puzzleEstimate - offset)) < 0.001)
    }

    @Test("A clean sweep is reported as a floor, not as a number")
    func sweepIsFlagged() {
        let (model, _, _) = makeModel()
        model.select(.competitive)
        model.beginMeasurement()
        for _ in 0..<5 { model.record(gameOutcome: .win) }
        for _ in 0..<20 { model.record(puzzleRating: 2000, solved: true) }

        #expect(model.estimate?.ceilingNotFound == true)
    }

    /// The bug: `restore` moved to the games stage only when the question had
    /// been answered. A user who skipped it, played two games and was then
    /// interrupted came back to the self-assessment screen with two games
    /// banked, and answering it there re-seeded the ladder those games had
    /// already walked.
    @Test("A calibration resumed without an answer lands on the games, not back on the question")
    func resumesWithoutAnAnswer() {
        let drafts = InMemoryCalibrationDraftStore(
            draft: CalibrationDraft(
                experience: nil,
                opponentRating: 1300,
                puzzleRating: 1400,
                games: [
                    .init(opponentRating: 1100, outcome: .win),
                    .init(opponentRating: 1200, outcome: .win)
                ],
                puzzles: []
            )
        )
        let model = CalibrationModel(drafts: drafts)

        #expect(model.stage == .games)
        #expect(model.games.count == 2)
        // The ladder is where the games left it, not where the question would
        // have put it.
        #expect(model.opponentRating == 1300)
        #expect(model.didResume)
    }

    /// The other half of the same fix: the answer is a seed, and a seed cannot
    /// be planted after something has grown from it.
    @Test("Answering the question after a game has been played does not re-seed the ladder")
    func lateAnswerDoesNotReseedTheLadder() {
        let (model, _, _) = makeModel()
        model.beginMeasurement()
        model.record(gameOutcome: .win)
        #expect(model.opponentRating == 1200)

        model.select(.new)
        // Recorded, because a re-test wants to know that someone who said
        // "beginner" measured 1600 — but not acted on.
        #expect(model.experience == .new)
        #expect(model.opponentRating == 1200)
    }

    @Test("Results arriving out of phase are ignored")
    func recordsAreGatedByPhase() {
        let (model, _, _) = makeModel()
        model.beginMeasurement()
        model.record(puzzleRating: 1200, solved: true)
        #expect(model.puzzles.isEmpty)

        for _ in 0..<5 { model.record(gameOutcome: .win) }
        model.record(gameOutcome: .win)
        #expect(model.games.count == 5)
    }
}
