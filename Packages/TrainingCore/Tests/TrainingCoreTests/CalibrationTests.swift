import Foundation
import Testing

@testable import TrainingCore

@Suite("Calibration combiner")
struct CalibrationTests {

    let opponents: [Double] = [1200, 1200, 1300, 1200, 1250]

    func games(_ outcomes: [GameOutcome]) -> [CalibrationGame] {
        zip(opponents, outcomes).map { CalibrationGame(opponentRating: $0, outcome: $1) }
    }

    func puzzles(solved: Int, of total: Int, rating: Double = 1100) -> [PuzzleResult] {
        (0..<total).map { PuzzleResult(puzzleRating: rating, solved: $0 < solved) }
    }

    // MARK: - Game side

    @Test("A mixed record produces mean-opponent plus the score term")
    func mixedRecord() {
        let result = CalibrationCombiner.gameSideEstimate(
            games: games([.win, .win, .win, .loss, .loss]),
            tuning: .default
        )
        // mean 1230, (3-2)/5 * 400 = +80
        #expect(abs(result.rating - 1310) < 1e-9)
        #expect(result.sigma == 180)
        #expect(!result.ceilingNotFound)
        #expect(!result.floorNotFound)
    }

    @Test("A 5-0 sweep anchors to the last opponent and flags that no ceiling was found")
    func cleanSweep() {
        let estimate = CalibrationCombiner.estimate(
            games: games([.win, .win, .win, .win, .win]),
            puzzles: puzzles(solved: 20, of: 20)
        )
        // The score term saturates at 5/5 and stops carrying information, so
        // the estimate is anchored to the strongest opponent actually beaten.
        #expect(abs(estimate.gameEstimate - (1250 + 200)) < 1e-9)
        #expect(estimate.gameSigma == 250)
        #expect(estimate.ceilingNotFound)
        #expect(!estimate.floorNotFound)
    }

    @Test("A 0-5 sweep is symmetric and flags that no floor was found")
    func cleanLoss() {
        let estimate = CalibrationCombiner.estimate(
            games: games([.loss, .loss, .loss, .loss, .loss]),
            puzzles: puzzles(solved: 0, of: 20)
        )
        #expect(abs(estimate.gameEstimate - (1250 - 200)) < 1e-9)
        #expect(estimate.gameSigma == 250)
        #expect(estimate.floorNotFound)
        #expect(!estimate.ceilingNotFound)
    }

    @Test("A draw-heavy record sets neither flag")
    func drawsAreNotASweep() {
        let estimate = CalibrationCombiner.estimate(
            games: games([.draw, .draw, .draw, .draw, .draw]),
            puzzles: puzzles(solved: 10, of: 20)
        )
        #expect(!estimate.ceilingNotFound)
        #expect(!estimate.floorNotFound)
        // No wins and no losses: the estimate is just the mean opponent.
        #expect(abs(estimate.gameEstimate - 1230) < 1e-9)
    }

    @Test("Game estimates are clamped to what five games can actually demonstrate")
    func gameEstimateClamps() {
        let weak = CalibrationCombiner.gameSideEstimate(
            games: [
                CalibrationGame(opponentRating: 800, outcome: .loss),
                CalibrationGame(opponentRating: 800, outcome: .loss),
                CalibrationGame(opponentRating: 800, outcome: .loss),
                CalibrationGame(opponentRating: 800, outcome: .loss),
                CalibrationGame(opponentRating: 800, outcome: .draw)
            ],
            tuning: .default
        )
        // 800 - 320 = 480, clamped up to the floor of the credible range.
        #expect(weak.rating == 700)

        let absurd = CalibrationCombiner.gameSideEstimate(
            games: [
                CalibrationGame(opponentRating: 2_200, outcome: .win),
                CalibrationGame(opponentRating: 2_200, outcome: .win),
                CalibrationGame(opponentRating: 2_200, outcome: .win),
                CalibrationGame(opponentRating: 2_200, outcome: .win),
                CalibrationGame(opponentRating: 2_200, outcome: .loss)
            ],
            tuning: .default
        )
        // 2200 + 240 = 2440, clamped down to the ceiling.
        #expect(absurd.rating == 2_000)
    }

    @Test("The ceiling is the top of the curriculum, so a strong placement is not shaved")
    func ceilingReachesTheCurriculumsTop() {
        // The calibration ladder walks +100 a win from the *competitive* seed of
        // 1500, so this is the strongest record the flow can actually produce
        // without sweeping. It scores out at 1940, and the old 1900 ceiling
        // clipped it — leaving the diagnostic unable to express the rating the
        // curriculum's top rung runs to, while the clean-sweep branch happily
        // reported higher by another route.
        let strong = CalibrationCombiner.gameSideEstimate(
            games: [
                CalibrationGame(opponentRating: 1_500, outcome: .win),
                CalibrationGame(opponentRating: 1_600, outcome: .win),
                CalibrationGame(opponentRating: 1_700, outcome: .win),
                CalibrationGame(opponentRating: 1_800, outcome: .win),
                CalibrationGame(opponentRating: 1_900, outcome: .loss)
            ],
            tuning: .default
        )
        // mean 1700, (4-1)/5 * 400 = +240.
        #expect(abs(strong.rating - 1_940) < 1e-9)
        #expect(!strong.ceilingNotFound)

        // And the ceiling is the top of rung 4's band, not a number of its own.
        let ceiling = DomainTuning.default.calibration.gameRatingRange.upperBound
        #expect(ceiling == Double(Curriculum.default[3].ratingBand.upperBound))
    }

    // MARK: - Puzzle side

    @Test("The puzzle estimate is shifted onto the playing scale")
    func puzzleOffset() {
        let withOffset = CalibrationCombiner.puzzleSideEstimate(
            puzzles: puzzles(solved: 14, of: 20),
            tuning: .default
        )
        let glicko = Glicko1()
        let raw = glicko.update(GlickoRating.start(), with: puzzles(solved: 14, of: 20))

        #expect(abs(withOffset.rating - (raw.rating - 100)) < 1e-9)
        #expect(abs(withOffset.sigma - raw.deviation) < 1e-9)
        // Puzzle ratings run hot: the conversion must move downward.
        #expect(withOffset.rating < raw.rating)
    }

    // MARK: - Fusion

    /// Converting a puzzle rating into a statement about playing strength is
    /// itself uncertain, and the fusion used to be told it was exact.
    @Test("The puzzle side enters the fusion carrying the conversion's error too")
    func conversionUncertaintyIsAdded() {
        let widened = CalibrationCombiner.playingScaleSigma(puzzleSigma: 100, conversionSigma: 100)
        // Quadrature, not addition: 100 and 100 make 141, not 200.
        #expect(abs(widened - 141.4213562373095) < 1e-9)
        #expect(widened > 100)

        // An exact conversion would leave the puzzle side untouched, which is
        // what the code did before and what this guards against returning to.
        #expect(CalibrationCombiner.playingScaleSigma(puzzleSigma: 100, conversionSigma: 0) == 100)
        #expect(CalibrationCombiner.puzzleConversionSigma > 0)
    }

    @Test("The combined estimate sits between the two inputs and is more certain than either")
    func precisionWeighting() {
        let estimate = CalibrationCombiner.estimate(
            games: games([.win, .win, .win, .loss, .loss]),
            puzzles: puzzles(solved: 14, of: 20)
        )

        let low = min(estimate.gameEstimate, estimate.puzzleEstimate)
        let high = max(estimate.gameEstimate, estimate.puzzleEstimate)
        #expect(estimate.rating > low)
        #expect(estimate.rating < high)

        // The point of two measurements: the fused error bar is tighter than
        // either of the two the fusion was actually given. `puzzleSigma` is not
        // one of those — it is the Glicko deviation on the puzzle scale, and the
        // number that entered the fusion is that widened by the conversion's own
        // error. So the fused sigma beats the game side and legitimately comes
        // out above the raw puzzle deviation.
        let fusedPuzzleSigma = CalibrationCombiner.playingScaleSigma(puzzleSigma: estimate.puzzleSigma)
        #expect(estimate.sigma < estimate.gameSigma)
        #expect(estimate.sigma < fusedPuzzleSigma)
        #expect(estimate.sigma > estimate.puzzleSigma)

        #expect(abs(estimate.rating - 1166.6103536093365) < 1e-9)
        #expect(abs(estimate.sigma - 111.92998934838272) < 1e-9)
    }

    @Test("The more certain measurement pulls harder")
    func weightFollowsCertainty() {
        // The puzzle side still enters more certain than the games (about 143
        // after the conversion's error is folded in, against 180), so the
        // combined estimate must land closer to it.
        let estimate = CalibrationCombiner.estimate(
            games: games([.win, .win, .win, .loss, .loss]),
            puzzles: puzzles(solved: 14, of: 20)
        )
        #expect(CalibrationCombiner.playingScaleSigma(puzzleSigma: estimate.puzzleSigma) < estimate.gameSigma)
        let toPuzzle = abs(estimate.rating - estimate.puzzleEstimate)
        let toGame = abs(estimate.rating - estimate.gameEstimate)
        #expect(toPuzzle < toGame)
    }

    @Test("Missing inputs degrade gracefully rather than fabricating a number")
    func missingInputs() {
        let puzzlesOnly = CalibrationCombiner.estimate(games: [], puzzles: puzzles(solved: 14, of: 20))
        #expect(abs(puzzlesOnly.rating - puzzlesOnly.puzzleEstimate) < 1e-9)

        let gamesOnly = CalibrationCombiner.estimate(games: games([.win, .win, .win, .loss, .loss]), puzzles: [])
        #expect(abs(gamesOnly.rating - gamesOnly.gameEstimate) < 1e-9)
    }

    // MARK: - Rung banding

    @Test("Rung banding lands correctly on every boundary")
    func rungBoundaries() {
        func rung(_ rating: Double) -> Int {
            CalibrationCombiner.startingRung(rating: rating, sigma: 0)
        }
        #expect(rung(0) == 1)
        #expect(rung(999.99) == 1)
        #expect(rung(1000) == 2)
        #expect(rung(1399.99) == 2)
        #expect(rung(1400) == 3)
        #expect(rung(1799.99) == 3)
        #expect(rung(1800) == 4)
        #expect(rung(2500) == 4)
    }

    @Test("Banding uses r − 0.5σ, so uncertainty shades the placement downward")
    func bandingIsConservative() {
        // Starting a user too high means every skill gate fails and the
        // curriculum stalls; starting too low costs a couple of easy weeks.
        #expect(CalibrationCombiner.startingRung(rating: 1050, sigma: 0) == 2)
        #expect(CalibrationCombiner.startingRung(rating: 1050, sigma: 200) == 1)
        #expect(CalibrationCombiner.startingRung(rating: 1450, sigma: 0) == 3)
        #expect(CalibrationCombiner.startingRung(rating: 1450, sigma: 200) == 2)
    }

    @Test("A full calibration run places a mid-strength user on rung 2")
    func endToEnd() {
        let estimate = CalibrationCombiner.estimate(
            games: games([.win, .win, .win, .loss, .loss]),
            puzzles: puzzles(solved: 14, of: 20)
        )
        #expect(estimate.startingRung == 2)
        #expect(Curriculum.default[estimate.startingRung - 1].title == "Tactical Vision")
    }
}
