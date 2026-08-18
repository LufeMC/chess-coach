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

        // The whole point of two measurements: the fused error bar is tighter
        // than either input's.
        #expect(estimate.sigma < estimate.gameSigma)
        #expect(estimate.sigma < estimate.puzzleSigma)

        #expect(abs(estimate.rating - 1133.1291775249174) < 1e-9)
        #expect(abs(estimate.sigma - 88.81626133859152) < 1e-9)
    }

    @Test("The more certain measurement pulls harder")
    func weightFollowsCertainty() {
        // The puzzle side has the smaller sigma here (about 102 vs 180), so the
        // combined estimate must land closer to it.
        let estimate = CalibrationCombiner.estimate(
            games: games([.win, .win, .win, .loss, .loss]),
            puzzles: puzzles(solved: 14, of: 20)
        )
        #expect(estimate.puzzleSigma < estimate.gameSigma)
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
