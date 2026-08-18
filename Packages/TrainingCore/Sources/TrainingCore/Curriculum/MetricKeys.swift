//
//  MetricKeys.swift
//  TrainingCore
//

import Foundation

/// The metric vocabulary the curriculum gates on.
///
/// Namespaced with dots so a metric's producer is readable from its key alone:
/// `mistake.*` comes from the post-game analysis detectors, `drill.*` from the
/// endgame drills, `puzzle.*`/`ladder.*` from the rating systems, and so on.
/// The app layer is responsible for computing these; this package only names
/// them and compares them to thresholds.
extension MetricKey {

    // MARK: - Mistake rates (per 100 moves unless stated)

    /// Pieces hung for at least
    /// ``DomainTuning/Curriculum/hangingPieceThresholdCentipawns``.
    public static let hangingPiecePer100: MetricKey = "mistake.hangingPiece.per100"
    public static let blundersPer100: MetricKey = "mistake.blunder.per100"
    public static let missedTacticPer100: MetricKey = "mistake.missedTactic.per100"
    public static let ignoredThreatPer100: MetricKey = "mistake.ignoredThreat.per100"
    public static let allowedDeepTacticPer100: MetricKey = "mistake.allowedTactic.deep.per100"
    public static let missedQuietMovePer100: MetricKey = "mistake.missedQuietMove.per100"

    // MARK: - Retry and guidance

    /// Fraction of failed positions the user then re-played cleanly.
    public static let cleanRetryRate: MetricKey = "retry.cleanRate"
    /// Hit rate on the guided-mode "what is your opponent threatening?" prompt.
    public static let guidedScanThreatsHitRate: MetricKey = "guided.scanThreats.hitRate"

    // MARK: - Drills

    public static let kqkDrillCleanStreak: MetricKey = "drill.kqk.cleanStreak"
    public static let krkDrillCleanStreak: MetricKey = "drill.krk.cleanStreak"
    /// Consecutive *complete sets* of KPK positions solved without error.
    public static let kpkDrillCleanSetStreak: MetricKey = "drill.kpk.cleanSetStreak"
    public static let lucenaDrillCleanStreak: MetricKey = "drill.lucena.cleanStreak"
    public static let philidorDrillCleanStreak: MetricKey = "drill.philidor.cleanStreak"
    /// Rook endings whose result class flipped, normalised per 8 endings.
    public static let rookEndingResultFlipsPer8: MetricKey = "rookEnding.resultFlipsPer8"

    // MARK: - Opening

    /// Fraction of games passing the three-part opening composite.
    public static let openingCompositeRate: MetricKey = "opening.compositeRate"
    public static let openingAccuracy: MetricKey = "opening.accuracy"
    public static let openingMistakesPerGame: MetricKey = "opening.mistakesPerGame"

    // MARK: - Middlegame quality

    public static let middlegameNonCriticalAccuracy: MetricKey = "accuracy.middlegameNonCritical"
    /// Fraction of critical moments where the user found a good move.
    public static let criticalMomentHitRate: MetricKey = "criticalMoment.hitRate"
    /// Fraction of available prophylactic moves the user found.
    public static let prophylacticFindRate: MetricKey = "prophylactic.findRate"

    // MARK: - Conversion

    /// Win rate in games that reached an expected-points advantage of 0.85.
    public static let winRateFromWinningPosition: MetricKey = "conversion.winRateFromWinningEP"
    /// Advantage-losing slips per game that was winning.
    public static let advantageSlipsPerWinningGame: MetricKey = "conversion.advantageSlipsPerWinningGame"

    // MARK: - Clock

    /// Fraction of games that ended in clock pressure.
    public static let clockPressureGameRate: MetricKey = "timeError.clockPressure.gameRate"
    /// Count of instant moves played at critical moments.
    public static let impulseAtCriticalCount: MetricKey = "timeError.impulseAtCritical.count"
    /// Mean think time at critical moments divided by mean elsewhere.
    public static let criticalToNormalThinkTimeRatio: MetricKey = "thinkTime.criticalToNormalRatio"

    // MARK: - Ratings

    public static let puzzleRating: MetricKey = "puzzle.rating"
    public static let puzzleRatingDeviation: MetricKey = "puzzle.ratingDeviation"
    public static let ladderRating: MetricKey = "ladder.rating"
    /// Performance rating over the metric's window.
    public static let ladderPerformance: MetricKey = "ladder.performance"

    // MARK: - Composed keys

    /// Success rate on puzzles of a given theme at or above a rating floor.
    ///
    /// The floor is part of the key rather than a separate criterion because
    /// the *metric itself* is scoped — "70% on forks" and "70% on forks rated
    /// 1200+" are different measurements, not the same measurement with an
    /// extra condition.
    public static func puzzleThemeSuccess(_ theme: ThemeTag, ratingFloor: Int) -> MetricKey {
        MetricKey("puzzle.themeSuccess.\(theme.rawValue)@\(ratingFloor)")
    }
}
