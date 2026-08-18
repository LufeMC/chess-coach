//
//  CalibrationCombiner.swift
//  TrainingCore
//

import Foundation

/// One calibration game.
public struct CalibrationGame: Sendable, Hashable {
    public var opponentRating: Double
    public var outcome: GameOutcome

    public init(opponentRating: Double, outcome: GameOutcome) {
        self.opponentRating = opponentRating
        self.outcome = outcome
    }
}

/// The output of calibration: a rating, an honest error bar, and where to start.
public struct CalibrationEstimate: Sendable, Hashable {

    /// The precision-weighted combined estimate.
    public var rating: Double
    /// Its standard error.
    public var sigma: Double

    /// The playing-side estimate and its sigma, kept for the UI and for
    /// debugging a surprising placement.
    public var gameEstimate: Double
    public var gameSigma: Double

    /// The puzzle-side estimate, already converted to the playing scale.
    public var puzzleEstimate: Double
    public var puzzleSigma: Double

    /// The user won every calibration game. Their true strength is somewhere
    /// *above* the strongest opponent we showed them and we do not know how far
    /// — the app should offer a stronger re-test rather than trust this number.
    public var ceilingNotFound: Bool

    /// The user lost every calibration game; the mirror case.
    public var floorNotFound: Bool

    /// Curriculum rung to start on, 1...4.
    public var startingRung: Int

    public init(
        rating: Double,
        sigma: Double,
        gameEstimate: Double,
        gameSigma: Double,
        puzzleEstimate: Double,
        puzzleSigma: Double,
        ceilingNotFound: Bool,
        floorNotFound: Bool,
        startingRung: Int
    ) {
        self.rating = rating
        self.sigma = sigma
        self.gameEstimate = gameEstimate
        self.gameSigma = gameSigma
        self.puzzleEstimate = puzzleEstimate
        self.puzzleSigma = puzzleSigma
        self.ceilingNotFound = ceilingNotFound
        self.floorNotFound = floorNotFound
        self.startingRung = startingRung
    }
}

/// Turns a short calibration session into a starting rating and a starting rung.
///
/// Two independent, differently-biased measurements are taken and then fused:
/// five real games (high variance, directly on the scale we care about) and
/// twenty puzzles (low variance, but measuring a related-not-identical skill).
/// Neither alone is good enough — five games has a standard error near 200
/// points, and puzzle rating systematically overstates playing strength.
public enum CalibrationCombiner {

    /// Runs the combiner.
    ///
    /// - Parameters:
    ///   - games: The calibration games, in the order played. The last one
    ///     matters on a clean sweep.
    ///   - puzzles: The calibration puzzles, in the order attempted.
    public static func estimate(
        games: [CalibrationGame],
        puzzles: [PuzzleResult],
        tuning: DomainTuning = .default
    ) -> CalibrationEstimate {
        let (gameRating, gameSigma, ceiling, floor) = gameSideEstimate(games: games, tuning: tuning)
        let (puzzleRating, puzzleSigma) = puzzleSideEstimate(puzzles: puzzles, tuning: tuning)

        let (combined, sigma) = combine(
            gameRating: gameRating,
            gameSigma: gameSigma,
            hasGames: !games.isEmpty,
            puzzleRating: puzzleRating,
            puzzleSigma: puzzleSigma,
            hasPuzzles: !puzzles.isEmpty
        )

        return CalibrationEstimate(
            rating: combined,
            sigma: sigma,
            gameEstimate: gameRating,
            gameSigma: gameSigma,
            puzzleEstimate: puzzleRating,
            puzzleSigma: puzzleSigma,
            ceilingNotFound: ceiling,
            floorNotFound: floor,
            startingRung: startingRung(rating: combined, sigma: sigma, tuning: tuning.calibration)
        )
    }

    // MARK: - Playing side

    /// `r_g = mean(opponentRatings) + 400 · (W − L) / N`, clamped.
    ///
    /// The clamp is not cosmetic. Five games against opponents around 1200
    /// simply cannot demonstrate 2100 strength — the ladder never showed the
    /// user anything hard enough — so an unclamped estimate would be an
    /// artefact of the formula rather than a measurement.
    ///
    /// A clean sweep is the exception and gets its own branch: there the score
    /// term saturates (`400 · 5/5`) and stops carrying information, so the
    /// estimate is anchored to the strongest opponent actually beaten plus a
    /// flat bonus, with a wider sigma and a flag. The flag is the honest part:
    /// the app should say "we could not find your ceiling" and offer a harder
    /// re-test rather than pretending to a number.
    static func gameSideEstimate(
        games: [CalibrationGame],
        tuning: DomainTuning
    ) -> (rating: Double, sigma: Double, ceilingNotFound: Bool, floorNotFound: Bool) {
        let cal = tuning.calibration
        guard !games.isEmpty else {
            // No games: report the midpoint at maximum uncertainty. The combiner
            // weights by 1/sigma², so this contributes essentially nothing.
            let midpoint = (cal.gameRatingRange.lowerBound + cal.gameRatingRange.upperBound) / 2
            return (midpoint, cal.gameSigma, false, false)
        }

        let wins = games.filter { $0.outcome == .win }.count
        let losses = games.filter { $0.outcome == .loss }.count
        let n = Double(games.count)
        let lastOpponent = games[games.count - 1].opponentRating

        if wins == games.count {
            return (lastOpponent + cal.sweepBonus, cal.sweepSigma, true, false)
        }
        if losses == games.count {
            return (lastOpponent - cal.sweepBonus, cal.sweepSigma, false, true)
        }

        let meanOpponent = games.reduce(0.0) { $0 + $1.opponentRating } / n
        let raw = meanOpponent + 400 * Double(wins - losses) / n
        let clamped = min(max(raw, cal.gameRatingRange.lowerBound), cal.gameRatingRange.upperBound)
        return (clamped, cal.gameSigma, false, false)
    }

    // MARK: - Puzzle side

    /// Runs the Glicko updates over the calibration puzzles, then shifts the
    /// result onto the playing scale.
    ///
    /// The offset is the interesting part. Puzzle ratings run hot relative to
    /// over-the-board strength, and not by accident: a puzzle tells you a
    /// tactic exists and that it is your move. Finding a fork when someone has
    /// announced there is a fork is a materially easier task than noticing that
    /// this quiet-looking middlegame position contains one. The offset converts
    /// between the two scales so the combiner is not averaging apples with
    /// oranges.
    static func puzzleSideEstimate(
        puzzles: [PuzzleResult],
        tuning: DomainTuning
    ) -> (rating: Double, sigma: Double) {
        let glicko = Glicko1(tuning: tuning.puzzleRating)
        guard !puzzles.isEmpty else {
            return (
                tuning.puzzleRating.startingRating + tuning.calibration.puzzleRatingOffset,
                tuning.puzzleRating.startingDeviation
            )
        }
        let final = glicko.update(GlickoRating.start(tuning: tuning.puzzleRating), with: puzzles)
        return (final.rating + tuning.calibration.puzzleRatingOffset, final.deviation)
    }

    // MARK: - Fusion

    /// Inverse-variance (precision) weighting.
    ///
    /// ```
    /// r = (r_g/σ_g² + r_p/σ_p²) / (1/σ_g² + 1/σ_p²)
    /// σ = sqrt(1 / (1/σ_g² + 1/σ_p²))
    /// ```
    ///
    /// This is the maximum-likelihood fusion of two independent normal
    /// estimates: whichever measurement is more certain pulls harder, and the
    /// combined estimate is *strictly more certain than either* — which is the
    /// entire reason for running two different tests instead of one longer one.
    static func combine(
        gameRating: Double,
        gameSigma: Double,
        hasGames: Bool,
        puzzleRating: Double,
        puzzleSigma: Double,
        hasPuzzles: Bool
    ) -> (rating: Double, sigma: Double) {
        let gamePrecision = hasGames && gameSigma > 0 ? 1 / (gameSigma * gameSigma) : 0
        let puzzlePrecision = hasPuzzles && puzzleSigma > 0 ? 1 / (puzzleSigma * puzzleSigma) : 0
        let total = gamePrecision + puzzlePrecision

        guard total > 0 else { return (gameRating, gameSigma) }
        let rating = (gameRating * gamePrecision + puzzleRating * puzzlePrecision) / total
        return (rating, (1 / total).squareRoot())
    }

    // MARK: - Rung banding

    /// Bands `r − conservatism·σ` into a starting rung.
    ///
    /// The subtraction is deliberate pessimism. The two errors are not
    /// symmetric: starting a user one rung too low costs them a couple of easy
    /// weeks and a mild "this is beneath me" feeling, while starting them one
    /// rung too high means every skill gate fails, the curriculum never
    /// advances, and the app's core promise stops being believable. Half a
    /// sigma is enough to shade the close calls downward without dropping a
    /// confidently-measured user a full rung.
    public static func startingRung(
        rating: Double,
        sigma: Double,
        tuning: DomainTuning.Calibration = DomainTuning.default.calibration
    ) -> Int {
        let conservative = rating - tuning.conservatism * sigma
        var rung = 1
        for boundary in tuning.rungBoundaries where conservative >= boundary {
            rung += 1
        }
        return rung
    }
}
