import Foundation
import Testing

@testable import TrainingCore

@Suite("Auto-grading")
struct AutoGraderTests {

    /// Band median of 5s throughout, so the "slow for band" threshold sits at
    /// 10s — the same place as the absolute easy threshold, which makes the
    /// interaction between the two rules visible.
    let median: Double = 5_000

    @Test("Wrong answers grade `.again` regardless of anything else")
    func wrongIsAlwaysAgain() {
        for usedHint in [false, true] {
            for retried in [false, true] {
                for latency in [500.0, 30_000.0] {
                    let graded = AutoGrader.grade(
                        correct: false, usedHint: usedHint, retried: retried,
                        latencyMs: latency, bandMedianLatencyMs: median
                    )
                    #expect(graded == .again, "hint=\(usedHint) retried=\(retried) latency=\(latency)")
                }
            }
        }
    }

    @Test("A hint makes it `.again` even when the line is then played perfectly")
    func hintIsAlwaysAgain() {
        // Once the answer has been shown, nothing after that point is evidence
        // about recall.
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: true, retried: false,
                latencyMs: 100, bandMedianLatencyMs: median
            ) == .again
        )
    }

    @Test("Correct, first try, under 10s grades `.easy`")
    func fastCleanIsEasy() {
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 4_000, bandMedianLatencyMs: median
            ) == .easy
        )
    }

    @Test("Correct but retried grades `.hard`, however fast")
    func retriedIsHard() {
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: true,
                latencyMs: 1_000, bandMedianLatencyMs: median
            ) == .hard
        )
    }

    @Test("Correct but slower than 2x the band median grades `.hard`")
    func slowForBandIsHard() {
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 10_001, bandMedianLatencyMs: median
            ) == .hard
        )
    }

    @Test("Band-relative slowness beats the absolute 10-second easy rule")
    func bandRelativeWinsOverAbsolute() {
        // 9s is under the absolute easy threshold but is 4.5x the median for a
        // very easy band. The band signal is adjusted for how hard the material
        // is, so it wins.
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 9_000, bandMedianLatencyMs: 2_000
            ) == .hard
        )
    }

    @Test("Correct, first try, slower than 10s but not slow for the band grades `.good`")
    func slowButNormalIsGood() {
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 20_000, bandMedianLatencyMs: 30_000
            ) == .good
        )
    }

    @Test("Exactly 2x the band median is not yet slow")
    func thresholdIsStrict() {
        // Boundary check: the rule is `>`, not `>=`.
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 10_000, bandMedianLatencyMs: median
            ) == .good
        )
        // And exactly 10s is not yet `.easy`, for the same reason.
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 10_000, bandMedianLatencyMs: 60_000
            ) == .good
        )
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 9_999, bandMedianLatencyMs: 60_000
            ) == .easy
        )
    }

    @Test("A missing band median falls back to the absolute rule only")
    func missingBandMedian() {
        // A brand-new rating band has no solve data yet; grading everything
        // `.hard` because `latency > 0` would be wrong.
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 3_000, bandMedianLatencyMs: 0
            ) == .easy
        )
        #expect(
            AutoGrader.grade(
                correct: true, usedHint: false, retried: false,
                latencyMs: 30_000, bandMedianLatencyMs: 0
            ) == .good
        )
    }

    @Test("Every branch of the truth table is reachable and distinct")
    func fullTruthTable() {
        struct Row {
            let correct: Bool, hint: Bool, retried: Bool, latency: Double, median: Double
            let expected: ReviewRating
        }
        let rows: [Row] = [
            .init(correct: false, hint: false, retried: false, latency: 1_000, median: 5_000, expected: .again),
            .init(correct: true, hint: true, retried: false, latency: 1_000, median: 5_000, expected: .again),
            .init(correct: true, hint: false, retried: true, latency: 1_000, median: 5_000, expected: .hard),
            .init(correct: true, hint: false, retried: false, latency: 12_000, median: 5_000, expected: .hard),
            .init(correct: true, hint: false, retried: false, latency: 12_000, median: 20_000, expected: .good),
            .init(correct: true, hint: false, retried: false, latency: 2_000, median: 5_000, expected: .easy)
        ]
        for row in rows {
            let graded = AutoGrader.grade(
                correct: row.correct, usedHint: row.hint, retried: row.retried,
                latencyMs: row.latency, bandMedianLatencyMs: row.median
            )
            #expect(graded == row.expected, "row \(row) graded \(graded)")
        }
        #expect(Set(rows.map(\.expected)) == Set(ReviewRating.allCases))
    }

    @Test("PuzzleAttempt routes through the same rules")
    func attemptConvenience() {
        let attempt = PuzzleAttempt(correct: true, latencyMs: 2_000, bandMedianLatencyMs: 5_000)
        #expect(attempt.rating() == .easy)
    }
}
