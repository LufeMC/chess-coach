import Foundation
import Testing

@testable import TrainingCore

@Suite("Glicko-1 puzzle rating")
struct GlickoTests {

    let glicko = Glicko1()
    let tolerance = 1e-9

    @Test("Constants match the published Glicko-1 definitions")
    func constants() {
        #expect(abs(Glicko1.q - 0.005756462732485115) < tolerance)
        #expect(abs(Glicko1.g(50) - 0.9876424005852659) < tolerance)
        #expect(abs(Glicko1.g(350) - 0.6690693971819845) < tolerance)
        // g is a decreasing function of uncertainty.
        #expect(Glicko1.g(50) > Glicko1.g(350))
    }

    @Test("Expected score is 0.5 against an equal-rated puzzle and falls as the puzzle gets harder")
    func expectedScore() {
        #expect(abs(glicko.expectedScore(rating: 1000, puzzleRating: 1000) - 0.5) < tolerance)
        #expect(abs(glicko.expectedScore(rating: 1000, puzzleRating: 1200) - 0.24285957650277093) < tolerance)
        #expect(glicko.expectedScore(rating: 1000, puzzleRating: 1200)
            < glicko.expectedScore(rating: 1000, puzzleRating: 1000))
    }

    @Test("Known input produces known output")
    func knownUpdate() {
        let start = GlickoRating.start()
        #expect(start.rating == 1000)
        #expect(start.deviation == 350)

        let solved = glicko.update(start, with: PuzzleResult(puzzleRating: 1000, solved: true))
        #expect(abs(solved.rating - 1174.9977413264664) < 1e-9)
        #expect(abs(solved.deviation - 248.1152781753439) < 1e-9)

        let failed = glicko.update(start, with: PuzzleResult(puzzleRating: 1000, solved: false))
        #expect(abs(failed.rating - 825.0022586735336) < 1e-9)
        // Symmetric around the start for an even-money puzzle.
        #expect(abs((solved.rating + failed.rating) / 2 - 1000) < 1e-9)
        #expect(abs(failed.deviation - solved.deviation) < 1e-12)
    }

    @Test("RD shrinks as evidence accumulates")
    func deviationShrinks() {
        var rating = GlickoRating.start()
        var previous = rating.deviation
        let results = (0..<20).map { PuzzleResult(puzzleRating: 1000, solved: $0 % 2 == 0) }

        for result in results {
            rating = glicko.update(rating, with: result)
            #expect(rating.deviation < previous)
            previous = rating.deviation
        }

        #expect(abs(rating.rating - 998.5950088865666) < 1e-9)
        #expect(abs(rating.deviation - 77.37183136461204) < 1e-9)
    }

    @Test("RD never falls below the floor, however much the user solves")
    func deviationFloor() {
        var rating = GlickoRating.start()
        for _ in 0..<500 {
            rating = glicko.update(rating, with: PuzzleResult(puzzleRating: rating.rating, solved: true))
        }
        // The floor is what keeps the rating responsive to genuine improvement.
        #expect(rating.deviation >= DomainTuning.default.puzzleRating.minimumDeviation)
        #expect(abs(rating.deviation - DomainTuning.default.puzzleRating.minimumDeviation) < 1e-9)
    }

    @Test("RD inflates while idle, up to the idle cap")
    func idleInflation() {
        let settled = GlickoRating(rating: 1200, deviation: 80)

        let afterTenDays = glicko.inflated(settled, idleDays: 10)
        #expect(afterTenDays.deviation == 100)
        // Idleness costs confidence, never rating.
        #expect(afterTenDays.rating == 1200)

        let afterAYear = glicko.inflated(settled, idleDays: 365)
        #expect(afterAYear.deviation == DomainTuning.default.puzzleRating.idleInflationCap)
        #expect(afterAYear.deviation < DomainTuning.default.puzzleRating.maximumDeviation)

        // Zero or negative elapsed time is a no-op.
        #expect(glicko.inflated(settled, idleDays: 0) == settled)
    }

    @Test("Idle inflation never pulls an already-high RD downward")
    func idleDoesNotDeflate() {
        let unsettled = GlickoRating(rating: 1000, deviation: 300)
        #expect(glicko.inflated(unsettled, idleDays: 5).deviation == 300)
    }

    @Test("SRS reviews move the rating half as far as fresh puzzles")
    func halfWeightReviews() {
        let start = GlickoRating.start()
        let fresh = glicko.update(start, with: PuzzleResult(puzzleRating: 1000, score: 1, isSRSReview: false))
        let review = glicko.update(start, with: PuzzleResult(puzzleRating: 1000, score: 1, isSRSReview: true))

        let freshDelta = fresh.rating - start.rating
        let reviewDelta = review.rating - start.rating

        #expect(reviewDelta < freshDelta)
        #expect(abs(reviewDelta - freshDelta * 0.5) < 1e-9)
        #expect(abs(review.rating - 1087.4988706632332) < 1e-9)

        // RD is not discounted: a review is still a genuine observation of the
        // user, even if it is weak evidence about their strength.
        #expect(abs(review.deviation - fresh.deviation) < 1e-12)
    }

    @Test("Grinding a deck of reviews cannot inflate the rating as fast as fresh solving")
    func grindingIsNotProfitable() {
        var ground = GlickoRating.start()
        var fresh = GlickoRating.start()
        for _ in 0..<30 {
            ground = glicko.update(ground, with: PuzzleResult(puzzleRating: 1200, score: 1, isSRSReview: true))
            fresh = glicko.update(fresh, with: PuzzleResult(puzzleRating: 1200, score: 1, isSRSReview: false))
        }
        #expect(ground.rating < fresh.rating)
    }
}

@Suite("Elo playing ladder")
struct EloTests {

    let tolerance = 1e-9

    @Test("Expected score matches the standard Elo curve")
    func expectedScore() {
        #expect(abs(EloLadder.expectedScore(userRating: 1000, opponentRating: 1050) - 0.4285368825916186) < tolerance)
        #expect(abs(EloLadder.expectedScore(userRating: 1000, opponentRating: 1000) - 0.5) < tolerance)
    }

    @Test("The K schedule steps down at 15 and 50 games")
    func kSchedule() {
        let t = DomainTuning.default.ladder

        func k(after games: Int) -> Double {
            EloLadder.kFactor(state: LadderState(rating: 1000, gamesSinceCalibration: games), mode: .sparring, tuning: t)
        }

        #expect(k(after: 0) == 40)
        #expect(k(after: 14) == 40)
        // Game 16 onward — index 15 — is the middle band.
        #expect(k(after: 15) == 24)
        #expect(k(after: 49) == 24)
        #expect(k(after: 50) == 16)
        #expect(k(after: 500) == 16)
    }

    @Test("Guided games use half K at every step of the schedule")
    func guidedHalfK() {
        let t = DomainTuning.default.ladder
        for games in [0, 20, 100] {
            let state = LadderState(rating: 1000, gamesSinceCalibration: games)
            let sparring = EloLadder.kFactor(state: state, mode: .sparring, tuning: t)
            let guided = EloLadder.kFactor(state: state, mode: .guided, tuning: t)
            #expect(guided == sparring / 2)
        }
    }

    @Test("A win moves the rating by K(S − E)")
    func ratingUpdate() {
        let early = EloLadder.update(
            state: LadderState(rating: 1000, gamesSinceCalibration: 0),
            game: LadderGame(opponentRating: 1050, outcome: .win)
        )
        #expect(abs(early.rating - 1022.8585246963353) < 1e-9)
        #expect(early.gamesSinceCalibration == 1)

        let middle = EloLadder.update(
            state: LadderState(rating: 1000, gamesSinceCalibration: 20),
            game: LadderGame(opponentRating: 1050, outcome: .win)
        )
        #expect(abs(middle.rating - 1013.7151148178011) < 1e-9)

        let late = EloLadder.update(
            state: LadderState(rating: 1000, gamesSinceCalibration: 60),
            game: LadderGame(opponentRating: 1050, outcome: .win)
        )
        #expect(abs(late.rating - 1009.1434098785342) < 1e-9)

        let guided = EloLadder.update(
            state: LadderState(rating: 1000, gamesSinceCalibration: 0),
            game: LadderGame(opponentRating: 1050, outcome: .win, mode: .guided)
        )
        #expect(abs(guided.rating - 1011.4292623481676) < 1e-9)
    }

    @Test("A game containing a level-2 assisted retry is completely unrated")
    func assistedGameIsUnrated() {
        let before = LadderState(rating: 1000, gamesSinceCalibration: 3, driftBoostGamesRemaining: 2)
        let after = EloLadder.update(
            state: before,
            game: LadderGame(opponentRating: 1400, outcome: .win, containedLevel2AssistedRetry: true)
        )
        // Not just the rating: the game counter and the drift boost must not
        // advance either, or the high-K window silently shortens.
        #expect(after == before)
    }

    @Test("Drift guard fires after two consecutive checks and restores after five games")
    func driftGuardFiresAndRestores() {
        var state = LadderState(rating: 1000, gamesSinceCalibration: 60)
        #expect(EloLadder.kFactor(state: state, mode: .sparring) == 16)

        // One drifting check is not enough — a single hot streak is noise.
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1200)
        #expect(state.consecutiveHighDriftChecks == 1)
        #expect(state.driftBoostGamesRemaining == 0)
        #expect(EloLadder.kFactor(state: state, mode: .sparring) == 16)

        // Two in a row arms it.
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1200)
        #expect(state.driftBoostGamesRemaining == 5)
        #expect(EloLadder.kFactor(state: state, mode: .sparring) == 40)
        // Counters reset so the guard has to re-earn itself.
        #expect(state.consecutiveHighDriftChecks == 0)

        // It lasts exactly five games, then K falls back.
        for game in 1...5 {
            #expect(EloLadder.kFactor(state: state, mode: .sparring) == 40, "game \(game)")
            state = EloLadder.update(state: state, game: LadderGame(opponentRating: 1000, outcome: .draw))
        }
        #expect(state.driftBoostGamesRemaining == 0)
        #expect(EloLadder.kFactor(state: state, mode: .sparring) == 16)
    }

    @Test("Drift guard is symmetric on the downside")
    func driftGuardDownside() {
        var state = LadderState(rating: 1400, gamesSinceCalibration: 60)
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1200)
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1200)
        #expect(state.driftBoostGamesRemaining == 5)
        #expect(EloLadder.kFactor(state: state, mode: .sparring) == 40)
    }

    @Test("A check inside the threshold clears the streak")
    func driftStreakResets() {
        var state = LadderState(rating: 1000, gamesSinceCalibration: 60)
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1200)
        #expect(state.consecutiveHighDriftChecks == 1)

        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1010)
        #expect(state.consecutiveHighDriftChecks == 0)
        #expect(state.driftBoostGamesRemaining == 0)

        // And a drift in the other direction does not accumulate with the first.
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1200)
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 800)
        #expect(state.driftBoostGamesRemaining == 0)
        #expect(state.consecutiveLowDriftChecks == 1)
        #expect(state.consecutiveHighDriftChecks == 0)
    }

    @Test("Exactly at the drift threshold does not count as drift")
    func driftThresholdIsStrict() {
        var state = LadderState(rating: 1000, gamesSinceCalibration: 60)
        state = EloLadder.recordDriftCheck(state: state, performanceRatingLast10: 1150)
        #expect(state.consecutiveHighDriftChecks == 0)
    }

    @Test("Performance rating is mean opponent plus 400(W−L)/N")
    func performanceRating() {
        let games = [
            LadderGame(opponentRating: 1000, outcome: .win),
            LadderGame(opponentRating: 1100, outcome: .win),
            LadderGame(opponentRating: 1200, outcome: .loss),
            LadderGame(opponentRating: 1300, outcome: .draw)
        ]
        // mean 1150, (2-1)/4 => +100
        #expect(EloLadder.performanceRating(games: games) == 1250)
        #expect(EloLadder.performanceRating(games: []) == nil)
    }

    @Test("Opponent ladder cycles its offsets and rounds to 25")
    func opponentLadderCycle() {
        #expect(EloLadder.opponentRating(userRating: 1000, gameIndex: 0) == 1050)
        #expect(EloLadder.opponentRating(userRating: 1000, gameIndex: 1) == 1050)
        #expect(EloLadder.opponentRating(userRating: 1000, gameIndex: 2) == 1150)
        #expect(EloLadder.opponentRating(userRating: 1000, gameIndex: 3) == 1000)
        // ...and repeats.
        #expect(EloLadder.opponentRating(userRating: 1000, gameIndex: 4) == 1050)

        // Rounding: 1013 + 50 = 1063 -> nearest 25 is 1075.
        #expect(EloLadder.opponentRating(userRating: 1013, gameIndex: 0) == 1075)
        #expect(EloLadder.opponentRating(userRating: 1013, gameIndex: 3) % 25 == 0)
    }

    @Test("Opponent ratings clamp to the available engine range")
    func opponentLadderClamps() {
        #expect(EloLadder.opponentRating(userRating: 2200, gameIndex: 2) == 2200)
        #expect(EloLadder.opponentRating(userRating: 400, gameIndex: 3) == 800)
    }
}
