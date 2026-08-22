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

    /// The Glicko deviation behind ``puzzleEstimate``, on the **puzzle** scale.
    ///
    /// This is what the Glicko update produced and what gets stored as the
    /// user's puzzle RD, so it must stay unshifted and uninflated. It is
    /// deliberately *not* the uncertainty the fusion was given: converting a
    /// puzzle rating into a playing rating is itself uncertain, and
    /// ``CalibrationCombiner/playingScaleSigma(puzzleSigma:conversionSigma:)``
    /// is where that gets added. So ``sigma`` can legitimately come out wider
    /// than this number.
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
///
/// "Related-not-identical" is the part that is easy to lose in the algebra. The
/// puzzle side only becomes evidence about *playing* strength after a conversion
/// that has never been measured, so it enters the fusion carrying that
/// conversion's error as well as its own — see ``puzzleConversionSigma``.
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
            // Not `puzzleSigma`: the fusion is a statement about *playing*
            // strength, and the puzzle side only becomes one after a conversion
            // that carries its own error.
            puzzleSigma: playingScaleSigma(puzzleSigma: puzzleSigma),
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

    // MARK: - Crossing between the two scales

    /// How wrong ``DomainTuning/Calibration/puzzleRatingOffset`` could be.
    ///
    /// That offset is a single number — puzzles run about a hundred points hot —
    /// standing in for a conversion nobody has measured. The calibration
    /// document (`Docs/humanizer-calibration.md`) is explicit that the app's
    /// scale has never been anchored against an external rating at all, so the
    /// honest statement is "about a hundred, and it would not be surprising if
    /// it turned out to be nothing or two hundred". A standard error of a
    /// hundred points says exactly that.
    ///
    /// It lives here rather than in `DomainTuning` because it is not a dial
    /// anyone should turn without new measurements behind it: it is a claim
    /// about what has been measured, and the day the anchoring in that document
    /// is done is the day this number is replaced rather than tuned.
    public static let puzzleConversionSigma: Double = 100

    /// The puzzle side's uncertainty restated as a claim about *playing*
    /// strength.
    ///
    /// The bug: the fusion was handed the raw Glicko deviation and treated it as
    /// the uncertainty of the user's playing strength, which is only true if the
    /// −100 conversion is exact. Twenty puzzles give a deviation near 100, so the
    /// puzzle side arrived looking nearly twice as precise as five real games,
    /// dominated the weighting, and produced a combined ±89 — a tighter error bar
    /// than either measurement can support, on the one screen where the user
    /// decides how much to believe the number. Independent errors add in
    /// quadrature, so the conversion's own uncertainty belongs inside the square
    /// root alongside the deviation.
    ///
    /// The knock-on is intended too: ``startingRung(rating:sigma:tuning:)`` bands
    /// `r − 0.5σ`, so an honest σ also makes the placement as conservative as
    /// that subtraction was written to be.
    static func playingScaleSigma(
        puzzleSigma: Double,
        conversionSigma: Double = puzzleConversionSigma
    ) -> Double {
        (puzzleSigma * puzzleSigma + conversionSigma * conversionSigma).squareRoot()
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
