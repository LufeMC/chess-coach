//
//  EloLadder.swift
//  TrainingCore
//

import Foundation

/// The result of a game, from the user's point of view.
public enum GameOutcome: Double, Sendable, Hashable, Codable, CaseIterable {
    case loss = 0
    case draw = 0.5
    case win = 1

    public var score: Double { rawValue }
}

/// How the game was played. Affects the K-factor, not the expected score.
public enum LadderGameMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Free play against a tuned engine personality.
    case sparring
    /// Play with coaching prompts and hints available.
    case guided
}

/// One ladder game.
public struct LadderGame: Sendable, Hashable {

    public var opponentRating: Double
    public var outcome: GameOutcome
    public var mode: LadderGameMode

    /// The game contained a level-2 assisted retry — the coach did not just
    /// nudge, it showed the move and let the user take it back.
    ///
    /// Such a game is **unrated**. The result is partly the engine's, and a
    /// rating that counts them measures the coach, not the user.
    public var containedLevel2AssistedRetry: Bool

    /// How many moves the user took back during the game, at any hint level.
    ///
    /// ``containedLevel2AssistedRetry`` is the loud case — the coach drew the
    /// refutation — and it is also the rarest. The quiet ones matter more:
    /// every blunder over the threshold is offered back for free, so a win
    /// after two retracted blunders moved the rating exactly as far as a clean
    /// win did. The number then climbed faster than the player, and the ladder
    /// served opponents they could not beat unaided.
    ///
    /// Discounted rather than refused. The game was still played — refusing it
    /// would freeze the rating of anyone who leans on the take-back, which is
    /// the player who most needs the number to be right.
    public var retractionCount: Int

    public init(
        opponentRating: Double,
        outcome: GameOutcome,
        mode: LadderGameMode = .sparring,
        containedLevel2AssistedRetry: Bool = false,
        retractionCount: Int = 0
    ) {
        self.opponentRating = opponentRating
        self.outcome = outcome
        self.mode = mode
        self.containedLevel2AssistedRetry = containedLevel2AssistedRetry
        self.retractionCount = retractionCount
    }
}

/// The user's standing on the playing ladder.
public struct LadderState: Sendable, Hashable, Codable {

    public var rating: Double

    /// Rated games completed since calibration. Drives the K schedule.
    public var gamesSinceCalibration: Int

    /// Consecutive drift checks where the last-10 performance rating came in
    /// more than the threshold *above* the current rating.
    public var consecutiveHighDriftChecks: Int

    /// ...and below.
    public var consecutiveLowDriftChecks: Int

    /// Games remaining under the drift guard's boosted K.
    public var driftBoostGamesRemaining: Int

    public init(
        rating: Double,
        gamesSinceCalibration: Int = 0,
        consecutiveHighDriftChecks: Int = 0,
        consecutiveLowDriftChecks: Int = 0,
        driftBoostGamesRemaining: Int = 0
    ) {
        self.rating = rating
        self.gamesSinceCalibration = gamesSinceCalibration
        self.consecutiveHighDriftChecks = consecutiveHighDriftChecks
        self.consecutiveLowDriftChecks = consecutiveLowDriftChecks
        self.driftBoostGamesRemaining = driftBoostGamesRemaining
    }
}

/// Elo for the playing ladder.
///
/// Elo rather than Glicko here — unlike puzzles, ladder games are played
/// against opponents *we* chose, at ratings we set, in an unbroken stream. The
/// uncertainty Glicko exists to model is already controlled, and Elo's single
/// K-factor gives a much more legible answer to "why did my rating move".
public enum EloLadder {

    /// `E = 1 / (1 + 10^((R_opponent − R_user) / 400))`
    public static func expectedScore(userRating: Double, opponentRating: Double) -> Double {
        1 / (1 + pow(10, (opponentRating - userRating) / 400))
    }

    /// The K-factor for the next game.
    ///
    /// The schedule trades responsiveness for stability as evidence accumulates:
    /// - **40** for the first 15 games after calibration. The calibration
    ///   estimate is built on 5 games and 20 puzzles; it is a starting guess and
    ///   needs to be able to move 200 points in a fortnight if it was wrong.
    /// - **24** through game 50.
    /// - **16** thereafter, which is roughly the FIDE standard and keeps a
    ///   settled rating from lurching on one bad night.
    ///
    /// Guided games are halved: the user had coaching prompts, so the result is
    /// partly the coach's. Halving rather than zeroing keeps guided play worth
    /// doing — a mode that cannot move your rating gets skipped.
    ///
    /// The drift guard overrides the schedule entirely while it is active.
    public static func kFactor(
        state: LadderState,
        mode: LadderGameMode,
        tuning: DomainTuning.Ladder = DomainTuning.default.ladder
    ) -> Double {
        let base: Double
        if state.driftBoostGamesRemaining > 0 {
            base = tuning.driftK
        } else if state.gamesSinceCalibration < tuning.earlyGames {
            base = tuning.earlyK
        } else if state.gamesSinceCalibration < tuning.middleThroughGame {
            base = tuning.middleK
        } else {
            base = tuning.lateK
        }
        return mode == .guided ? base * tuning.guidedKMultiplier : base
    }

    /// How far a K-factor is cut by the take-backs a game contained.
    ///
    /// Halved per retraction, to a floor of a quarter. One take-back is a slip
    /// or a single caught blunder and the game is still mostly the player's;
    /// past two the result says more about how many attempts they had than
    /// about how they play, and cutting further would only be noise on a number
    /// that has already stopped meaning much.
    ///
    /// The constant lives here rather than in `DomainTuning` because it is not
    /// a dial: it is the arithmetic of the discount itself, and there is no
    /// value of it a caller should be choosing.
    public static func retractionMultiplier(retractionCount: Int) -> Double {
        pow(0.5, Double(min(max(retractionCount, 0), 2)))
    }

    /// Applies one game.
    ///
    /// `R += K(S − E)`.
    ///
    /// A game with take-backs in it counts for less — see
    /// ``retractionMultiplier(retractionCount:)``.
    ///
    /// An unrated game returns the state completely untouched — including the
    /// game counter and the drift boost. Advancing the K schedule on a game
    /// that did not move the rating would silently shorten the high-K window
    /// the new user actually needs.
    public static func update(
        state: LadderState,
        game: LadderGame,
        tuning: DomainTuning.Ladder = DomainTuning.default.ladder
    ) -> LadderState {
        guard !game.containedLevel2AssistedRetry else { return state }

        let k = kFactor(state: state, mode: game.mode, tuning: tuning)
            * retractionMultiplier(retractionCount: game.retractionCount)
        let expected = expectedScore(userRating: state.rating, opponentRating: game.opponentRating)

        var next = state
        next.rating += k * (game.outcome.score - expected)
        next.gamesSinceCalibration += 1
        if next.driftBoostGamesRemaining > 0 {
            next.driftBoostGamesRemaining -= 1
        }
        return next
    }

    /// Records one drift check and arms the guard if it has now fired twice.
    ///
    /// The guard exists because a fixed K schedule is only correct when the
    /// rating is roughly right. If the user has genuinely improved, every game
    /// is an underdog win at K=16 and the rating crawls up 4 points at a time
    /// while they are handed opponents they beat easily — which is both boring
    /// and, because the curriculum gates on rating, actively blocking. Two
    /// consecutive checks rather than one, because a single hot streak over ten
    /// games is well within noise.
    ///
    /// Symmetric on the downside: a user who has gone backwards (illness, a
    /// long break, a new time control) needs to fall to their real level fast,
    /// or every game is a loss and they quit.
    ///
    /// Callers run this once per game, once ten games exist to average over.
    public static func recordDriftCheck(
        state: LadderState,
        performanceRatingLast10: Double,
        tuning: DomainTuning.Ladder = DomainTuning.default.ladder
    ) -> LadderState {
        var next = state
        let gap = performanceRatingLast10 - state.rating

        if gap > tuning.driftThreshold {
            next.consecutiveHighDriftChecks += 1
            next.consecutiveLowDriftChecks = 0
        } else if gap < -tuning.driftThreshold {
            next.consecutiveLowDriftChecks += 1
            next.consecutiveHighDriftChecks = 0
        } else {
            next.consecutiveHighDriftChecks = 0
            next.consecutiveLowDriftChecks = 0
        }

        if next.consecutiveHighDriftChecks >= tuning.driftConsecutiveChecks
            || next.consecutiveLowDriftChecks >= tuning.driftConsecutiveChecks {
            next.driftBoostGamesRemaining = tuning.driftBoostGames
            // Both counters reset so the guard fires once and then has to
            // re-earn itself, rather than re-arming on every subsequent check
            // and never letting K fall back.
            next.consecutiveHighDriftChecks = 0
            next.consecutiveLowDriftChecks = 0
        }

        return next
    }

    /// `mean(opponentRatings) + 400 · (W − L) / N`
    ///
    /// The standard small-sample performance rating. Undefined for an empty
    /// set, which returns `nil` rather than a fabricated number.
    public static func performanceRating(games: [LadderGame]) -> Double? {
        guard !games.isEmpty else { return nil }
        let wins = games.filter { $0.outcome == .win }.count
        let losses = games.filter { $0.outcome == .loss }.count
        let meanOpponent = games.reduce(0.0) { $0 + $1.opponentRating } / Double(games.count)
        return meanOpponent + 400 * Double(wins - losses) / Double(games.count)
    }

    /// The rating of the opponent for a given game on the ladder.
    ///
    /// `round25(userRating + offset)` where the offset cycles through
    /// ``DomainTuning/Ladder/opponentOffsetCycle``.
    ///
    /// The cycle — two games slightly above, one clear stretch, one level —
    /// targets roughly a 45% score. That is deliberately below even: a ladder
    /// the user wins is not teaching them anything, and one they always lose is
    /// abandoned by week two. The level game every fourth outing is the
    /// confidence reset.
    ///
    /// Rounding to 25 makes the ladder read as a series of tidy rungs rather
    /// than "1163 vs 1187", which users correctly find meaningless.
    public static func opponentRating(
        userRating: Double,
        gameIndex: Int,
        tuning: DomainTuning.Ladder = DomainTuning.default.ladder
    ) -> Int {
        let cycle = tuning.opponentOffsetCycle
        guard !cycle.isEmpty else {
            return min(max(Int(userRating.rounded()), tuning.opponentRatingRange.lowerBound), tuning.opponentRatingRange.upperBound)
        }
        // Modulo that behaves for negative indices too.
        let position = ((gameIndex % cycle.count) + cycle.count) % cycle.count
        let raw = userRating + Double(cycle[position])
        let step = Double(tuning.opponentRoundingStep)
        let rounded = Int(((raw / step).rounded() * step).rounded())
        return min(max(rounded, tuning.opponentRatingRange.lowerBound), tuning.opponentRatingRange.upperBound)
    }
}
