//
//  AutoGrader.swift
//  TrainingCore
//

import Foundation

/// Turns what the user *did* into an FSRS grade.
///
/// There are no rating buttons in this app. Two reasons:
///
/// 1. Self-grading is the single largest source of noise in consumer SRS. The
///    user is asked to introspect on a memory they just used, which they are
///    demonstrably bad at, and every mis-grade compounds through the scheduler.
/// 2. For chess specifically the user cannot tell the difference that matters.
///    "I saw the fork instantly" and "I found the fork after twenty seconds of
///    calculation" feel like the same success and are completely different
///    memories — but the clock can tell them apart, and does.
///
/// So the grade is derived from correctness, hint use, retries, and latency
/// measured against the median for puzzles of that rating band.
public enum AutoGrader {

    /// Grades one attempt.
    ///
    /// - Parameters:
    ///   - correct: The user played the complete solution line. A partially
    ///     correct line is not correct.
    ///   - usedHint: Any hint was revealed. Treated as a failure regardless of
    ///     what happened afterwards — see below.
    ///   - retried: The user took more than one attempt at some move in the
    ///     line.
    ///   - latencyMs: Wall-clock time from position shown to line completed.
    ///   - bandMedianLatencyMs: Median latency for solvers on puzzles in this
    ///     rating band. Normalising against the band is what makes latency
    ///     meaningful: eight seconds is fast for a 1600 puzzle and slow for a
    ///     900 one.
    ///
    /// Precedence is `again` → `hard` → `easy` → `good`. The one non-obvious
    /// tie-break: a *fast in absolute terms* answer that is nevertheless slow
    /// relative to its band grades `.hard`, not `.easy`. The band-relative
    /// signal wins because it is adjusted for how hard the material is, and
    /// the 10-second rule is not.
    public static func grade(
        correct: Bool,
        usedHint: Bool,
        retried: Bool,
        latencyMs: Double,
        bandMedianLatencyMs: Double,
        tuning: DomainTuning.Grading = DomainTuning.default.grading
    ) -> ReviewRating {
        // A hint is a failure even when the user then plays the line perfectly.
        // The card is testing recall of the pattern; once the answer has been
        // shown, nothing after that point is evidence about recall. Grading a
        // hinted success as anything but `.again` is how SRS decks silently
        // fill with cards the user has never actually retrieved.
        guard correct, !usedHint else { return .again }

        // Guard against a zero or missing band median (a brand-new rating band
        // with no solve data): fall back to the absolute rule only.
        let slowForBand = bandMedianLatencyMs > 0
            && latencyMs > tuning.hardLatencyMultiple * bandMedianLatencyMs

        if slowForBand || retried { return .hard }
        if latencyMs < tuning.easyLatencyMs { return .easy }
        return .good
    }
}
