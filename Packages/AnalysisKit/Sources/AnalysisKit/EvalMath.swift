//
//  EvalMath.swift
//  AnalysisKit
//

import EngineKit
import Foundation

// MARK: - Judgment

/// How bad a move was, in Lichess's four-way classification.
///
/// `Comparable` so call sites can say `judgment >= .inaccuracy`, which is the
/// gate almost every detector uses.
public enum Judgment: Int, Sendable, Codable, CaseIterable, Comparable {
    case ok = 0
    case inaccuracy = 1
    case mistake = 2
    case blunder = 3

    public static func < (lhs: Judgment, rhs: Judgment) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The inclusive lower bound of expected-points loss for this judgment.
    public var threshold: Double {
        switch self {
        case .ok: 0
        case .inaccuracy: EvalMath.inaccuracyThreshold
        case .mistake: EvalMath.mistakeThreshold
        case .blunder: EvalMath.blunderThreshold
        }
    }
}

// MARK: - EvalMath

/// Conversions between engine scores, win percentages, expected points, and
/// accuracy — the published Lichess formulas, reproduced exactly.
///
/// Every constant here is load-bearing: they were fitted by Lichess against
/// millions of games, and changing one silently re-tunes every threshold in the
/// app (judgments, criticality, moment severity). Do not "clean them up".
public enum EvalMath {

    // MARK: Constants

    /// Sigmoid steepness for the centipawn → win% curve (Lichess, 2023 fit).
    public static let winPercentK = 0.003_682_08
    /// Centipawn magnitude beyond which the curve is flat enough that Lichess
    /// clamps rather than extrapolating.
    public static let centipawnClamp = 1000

    /// Accuracy curve coefficients (Lichess): `A * exp(-B * winPercentLoss) + C`.
    public static let accuracyA = 103.166_8
    public static let accuracyB = 0.043_54
    public static let accuracyC = -3.166_9

    /// Expected-points-loss thresholds for the judgment classes.
    public static let inaccuracyThreshold = 0.10
    public static let mistakeThreshold = 0.20
    public static let blunderThreshold = 0.30

    // MARK: Win percent

    /// Win percentage (0...100) for a centipawn score, from the perspective of
    /// whoever the score belongs to.
    ///
    /// - note: The curve is symmetric: `winPercent(cp) + winPercent(-cp) == 100`
    ///   for every input. Downstream code relies on that identity to flip
    ///   perspective without re-running the engine.
    public static func winPercent(cp: Int) -> Double {
        let clamped = Double(min(max(cp, -centipawnClamp), centipawnClamp))
        return 50 + 50 * (2 / (1 + exp(-winPercentK * clamped)) - 1)
    }

    /// Win percentage (0...100) for an engine score.
    ///
    /// Mate scores saturate: a forced mate is a 100% (or 0%) result, not a very
    /// large centipawn count, because feeding `mateEquivalent` through the
    /// sigmoid would only reach ~97% and would make "mate in 1" look like a
    /// merely large advantage.
    ///
    /// `.mate(0)` is what an engine reports for a position that is *already*
    /// checkmate with the scored side to move, so it counts as 0%.
    public static func winPercent(score: UCIScore) -> Double {
        switch score {
        case .centipawns(let cp): winPercent(cp: cp)
        case .mate(let n): n > 0 ? 100 : 0
        }
    }

    /// Expected points (0...1) — win% expressed as a share of a full point.
    ///
    /// This is the unit every threshold in the app is expressed in ("EP").
    public static func expectedPoints(_ winPct: Double) -> Double {
        winPct / 100
    }

    /// Expected points for a score, from that score's own perspective.
    public static func expectedPoints(score: UCIScore) -> Double {
        expectedPoints(winPercent(score: score))
    }

    /// The same position's expected points seen from the other side.
    ///
    /// Valid because the win% curve is symmetric about 50 (see `winPercent`).
    public static func complement(ep: Double) -> Double {
        1 - ep
    }

    /// Lichess's "winning chances" scale, -1 (lost) ... +1 (won).
    ///
    /// The puzzle miner's thresholds are published on this scale, so it gets a
    /// first-class conversion rather than being open-coded at the call site.
    public static func winChance(score: UCIScore) -> Double {
        2 * expectedPoints(score: score) - 1
    }

    // MARK: Accuracy

    /// Move accuracy (0...100) from the win percentages before and after a move.
    ///
    /// - important: Both inputs must be from the **mover's** perspective. Engine
    ///   scores are side-to-move relative, so the score of the position *after*
    ///   the move belongs to the opponent and must be negated first — see
    ///   ``Perspective``. Getting this backwards produces plausible-looking
    ///   garbage, which is why the conversion lives in its own tested type.
    public static func accuracy(winPctBefore: Double, winPctAfter: Double) -> Double {
        let loss = winPctBefore - winPctAfter
        let raw = accuracyA * exp(-accuracyB * loss) + accuracyC
        return min(max(raw, 0), 100)
    }

    /// Whole-game accuracy: the mean of a volatility-weighted mean and a
    /// harmonic mean of the per-move accuracies.
    ///
    /// This reproduces Lichess's `AccuracyPercent.fromWinPercents` with two
    /// documented approximations:
    ///
    /// 1. **Windows.** Lichess builds `windowSize` copies of the first window and
    ///    then appends every sliding window, so accuracy *i* is weighted by the
    ///    window starting at `max(0, i - windowSize)`. That indexing is
    ///    reproduced here, but Lichess computes the windows over *both* colors'
    ///    win percentages while weighting one color's accuracies. Callers here
    ///    pass whichever pair of arrays they mean; per-colour behaviour is the
    ///    caller's choice.
    /// 2. **Standard deviation clamp.** A dead-quiet stretch has a standard
    ///    deviation of 0, which would zero every weight and make the weighted
    ///    mean undefined, so weights are clamped to 0.5...12 exactly as Lichess
    ///    does. Likewise the harmonic mean floors each accuracy at 1 so a single
    ///    0-accuracy move cannot drive the whole game to 0.
    ///
    /// - parameter moveAccuracies: Per-move accuracy values (0...100).
    /// - parameter winPercents: Win percentages used to measure volatility. Must
    ///   line up with `moveAccuracies`; the shorter of the two is used.
    /// - returns: Game accuracy 0...100, or `nil` when there are no moves.
    public static func gameAccuracy(moveAccuracies: [Double], winPercents: [Double]) -> Double? {
        let count = min(moveAccuracies.count, winPercents.count)
        guard count > 0 else { return nil }

        let accuracies = Array(moveAccuracies.prefix(count))
        let percents = Array(winPercents.prefix(count))

        let windowSize = min(max(count / 10, 2), 8)

        var weightedSum = 0.0
        var weightTotal = 0.0
        for index in accuracies.indices {
            let start = max(0, index - windowSize)
            let end = min(percents.count, start + windowSize)
            let window = Array(percents[start..<end])
            let weight = min(max(standardDeviation(window) ?? 0.5, 0.5), 12)
            weightedSum += accuracies[index] * weight
            weightTotal += weight
        }

        let weightedMean = weightTotal > 0 ? weightedSum / weightTotal : mean(accuracies)
        let harmonic = harmonicMean(accuracies.map { max($0, 1) })

        return (weightedMean + harmonic) / 2
    }

    // MARK: Judgment

    /// Classifies an expected-points loss.
    ///
    /// - parameter deltaEP: `EP(before) - EP(after played move)`, always from the
    ///   mover's perspective, so a positive number means the mover lost ground.
    public static func judgment(deltaEP: Double) -> Judgment {
        if deltaEP >= blunderThreshold { return .blunder }
        if deltaEP >= mistakeThreshold { return .mistake }
        if deltaEP >= inaccuracyThreshold { return .inaccuracy }
        return .ok
    }

    /// Expected-points loss for a move, given mover-relative scores.
    ///
    /// - parameter before: Eval of the position before the move, mover-relative.
    /// - parameter after: Eval of the position after the move, **already
    ///   converted** to the mover's perspective (see ``Perspective``).
    public static func deltaEP(before: UCIScore, after: UCIScore) -> Double {
        expectedPoints(score: before) - expectedPoints(score: after)
    }

    // MARK: Statistics helpers

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Population standard deviation, `nil` for fewer than two samples.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
        return variance.squareRoot()
    }

    static func harmonicMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let denominator = values.reduce(0) { $0 + 1 / $1 }
        guard denominator > 0 else { return 0 }
        return Double(values.count) / denominator
    }
}
