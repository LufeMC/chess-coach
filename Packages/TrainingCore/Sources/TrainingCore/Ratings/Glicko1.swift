//
//  Glicko1.swift
//  TrainingCore
//

import Foundation

/// A rating together with how much we trust it.
public struct GlickoRating: Sendable, Hashable, Codable {

    public var rating: Double

    /// Rating deviation: the standard error of ``rating``. Large means "we are
    /// guessing"; small means "we have watched this player a lot, recently".
    public var deviation: Double

    public init(rating: Double, deviation: Double) {
        self.rating = rating
        self.deviation = deviation
    }

    /// A user who has never solved a puzzle.
    public static func start(
        tuning: DomainTuning.PuzzleRating = DomainTuning.default.puzzleRating
    ) -> GlickoRating {
        GlickoRating(rating: tuning.startingRating, deviation: tuning.startingDeviation)
    }

    /// The conventional 95% interval. Used by the UI to decide whether to show
    /// a rating at all — a rating with RD 300 is not worth displaying.
    public var confidenceInterval: ClosedRange<Double> {
        (rating - 1.96 * deviation)...(rating + 1.96 * deviation)
    }
}

/// One puzzle result.
public struct PuzzleResult: Sendable, Hashable {

    public var puzzleRating: Double

    /// 1 for solved, 0 for failed. Puzzles have no draws, but the type is a
    /// `Double` because the Glicko equations are defined on `0...1` and a
    /// future partial-credit scheme would slot straight in.
    public var score: Double

    /// Whether this was a spaced-repetition review of a card the user has
    /// already seen, as opposed to a fresh puzzle.
    public var isSRSReview: Bool

    public init(puzzleRating: Double, score: Double, isSRSReview: Bool = false) {
        self.puzzleRating = puzzleRating
        self.score = score
        self.isSRSReview = isSRSReview
    }

    public init(puzzleRating: Double, solved: Bool, isSRSReview: Bool = false) {
        self.init(puzzleRating: puzzleRating, score: solved ? 1 : 0, isSRSReview: isSRSReview)
    }
}

/// Glicko-1, used for the puzzle rating.
///
/// Plain Elo was rejected because it has no concept of uncertainty, and this
/// app's central problem *is* uncertainty: a new user has done nothing, and a
/// returning user's six-month-old rating is a guess. Glicko's rating deviation
/// makes both cases explicit — a new user's rating moves hundreds of points on
/// the first few puzzles and then settles, without any hand-rolled provisional
/// -rating hack, and the UI can refuse to show a number it does not believe.
///
/// Glicko-1 rather than Glicko-2 because Glicko-2's extra parameter (volatility)
/// is fitted from long rating histories that this app will not have for months,
/// and its rating periods assume batches of games against rated opponents —
/// neither of which describes solving puzzles one at a time.
public struct Glicko1: Sendable {

    public let tuning: DomainTuning.PuzzleRating

    public init(tuning: DomainTuning.PuzzleRating = DomainTuning.default.puzzleRating) {
        self.tuning = tuning
    }

    /// `q = ln(10) / 400`. Converts the base-10, 400-point Elo scale into the
    /// natural-log scale the variance algebra works in.
    public static let q = log(10.0) / 400.0

    /// `g(RD) = 1 / sqrt(1 + 3q²RD² / π²)`
    ///
    /// The attenuation factor. A result against an opponent whose own rating is
    /// uncertain says less about you, and `g` is how much less. Here the
    /// "opponent" is a puzzle, whose rating comes from a large solve population,
    /// so ``DomainTuning/PuzzleRating/puzzleDeviation`` is small and fixed and
    /// `g` is close to 1.
    public static func g(_ deviation: Double) -> Double {
        1 / (1 + 3 * q * q * deviation * deviation / (Double.pi * Double.pi)).squareRoot()
    }

    /// `E = 1 / (1 + 10^(−g(RD_j)(r − r_j) / 400))`
    ///
    /// Expected score against a puzzle of the given rating.
    public func expectedScore(
        rating: Double,
        puzzleRating: Double,
        puzzleDeviation: Double? = nil
    ) -> Double {
        let rd = puzzleDeviation ?? tuning.puzzleDeviation
        return 1 / (1 + pow(10, -Glicko1.g(rd) * (rating - puzzleRating) / 400))
    }

    /// Applies one puzzle result.
    ///
    /// ```
    /// d² = 1 / (q² g(RD_j)² E (1 − E))
    /// r' = r + q / (1/RD² + 1/d²) · g(RD_j) · (s − E)
    /// RD' = sqrt(1 / (1/RD² + 1/d²))
    /// ```
    ///
    /// The `(s − E)` term is scaled by
    /// ``DomainTuning/PuzzleRating/srsReviewWeight`` when the result came from
    /// an SRS review. This is load-bearing: a review is a repeat of a puzzle
    /// the user has already been shown the answer to, so it is *not*
    /// independent evidence of playing strength. At full weight a user could
    /// inflate their rating simply by grinding their own deck — and worse, the
    /// inflated rating would feed straight into fresh-puzzle selection and the
    /// curriculum's rating gates, so the app would start serving them puzzles
    /// they cannot do and then blame them for failing.
    ///
    /// Note the RD update is *not* half-weighted. RD measures how recently we
    /// observed the user at all, and a review is a genuine observation; only
    /// the strength inference it supports is discounted.
    public func update(_ current: GlickoRating, with result: PuzzleResult) -> GlickoRating {
        let rd = min(max(current.deviation, tuning.minimumDeviation), tuning.maximumDeviation)
        let gj = Glicko1.g(tuning.puzzleDeviation)
        let e = expectedScore(rating: current.rating, puzzleRating: result.puzzleRating)

        let variance = e * (1 - e)
        // A near-certain result carries no information and would divide by zero
        // on the way to `d²`. Treat `1/d²` as zero: the rating and RD stand.
        guard variance > 1e-12 else { return GlickoRating(rating: current.rating, deviation: rd) }

        let q = Glicko1.q
        let dSquaredInverse = q * q * gj * gj * variance
        let denominator = 1 / (rd * rd) + dSquaredInverse

        let weight = result.isSRSReview ? tuning.srsReviewWeight : 1.0
        let newRating = current.rating + (q / denominator) * gj * (result.score - e) * weight
        let newDeviation = (1 / denominator).squareRoot()

        return GlickoRating(
            rating: newRating,
            deviation: min(max(newDeviation, tuning.minimumDeviation), tuning.maximumDeviation)
        )
    }

    /// Applies a sequence of results in order.
    public func update(_ current: GlickoRating, with results: [PuzzleResult]) -> GlickoRating {
        results.reduce(current) { update($0, with: $1) }
    }

    /// Re-inflates RD after a period of not solving anything.
    ///
    /// A rating decays in *confidence*, not in value: the user did not get
    /// worse while they were away, we simply know less about them. Inflation
    /// stops at ``DomainTuning/PuzzleRating/idleInflationCap`` rather than the
    /// full 350 — someone returning after a year is rusty, not unrated, and
    /// throwing away their whole history would make them re-grind twenty
    /// puzzles to get back to a number we already had good reason to believe.
    public func inflated(_ current: GlickoRating, idleDays: Double) -> GlickoRating {
        guard idleDays > 0 else { return current }
        let target = min(current.deviation + tuning.idleInflationPerDay * idleDays, tuning.idleInflationCap)
        // `max` so that a deviation already above the cap is left alone rather
        // than being pulled *down* by an idle period.
        let inflated = max(current.deviation, target)
        return GlickoRating(
            rating: current.rating,
            deviation: min(max(inflated, tuning.minimumDeviation), tuning.maximumDeviation)
        )
    }
}
