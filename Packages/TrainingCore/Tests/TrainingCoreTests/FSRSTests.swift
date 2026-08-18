import Foundation
import Testing

@testable import TrainingCore

/// The expected values in this suite were generated from an independent
/// reference implementation written directly from the published FSRS-6
/// equations, so they check the Swift code against something that is not
/// itself. A failure here means either a transcription error or a deliberate
/// algorithm change — in the latter case the reference must be re-run, not the
/// literals nudged.
@Suite("FSRS-6 scheduler")
struct FSRSTests {

    let scheduler = FSRS6()
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let day: TimeInterval = 86_400
    let tolerance = 1e-9

    // MARK: - Constants and invariants

    @Test("Weight vector is the 21-parameter FSRS-6 set, not FSRS-5's 19")
    func weightCount() {
        #expect(DomainTuning.default.srs.weights.count == FSRS6.parameterCount)
        #expect(FSRS6.parameterCount == 21)
    }

    @Test("The curve's defining invariant holds: R(S, S) = 0.9")
    func retrievabilityAtStability() {
        // This is what makes "stability" mean "days until 90% recall". A wrong
        // `factor` still produces a plausible-looking decay curve, and this is
        // the assertion that catches it.
        for stability in [0.5, 1.0, 10.0, 365.0] {
            let r = scheduler.retrievability(elapsedDays: stability, stability: stability)
            #expect(abs(r - 0.9) < 1e-12)
        }
    }

    @Test("Forgetting curve matches the reference at fixed points")
    func forgettingCurveValues() {
        let expected: [(Double, Double)] = [
            (0, 1.0),
            (1, 0.9856824087775146),
            (5, 0.9403442888929227),
            (10, 0.9),
            (30, 0.8093881035731708),
            (100, 0.6928266345726217)
        ]
        for (t, want) in expected {
            #expect(abs(scheduler.retrievability(elapsedDays: t, stability: 10) - want) < tolerance)
        }
    }

    @Test("Retrievability decays strictly monotonically with elapsed time")
    func retrievabilityDecaysMonotonically() {
        var card = CardState.new(due: t0)
        card = scheduler.nextReview(card: card, rating: .good, now: t0)

        var previous = 1.1
        for dayOffset in stride(from: 0.0, through: 400.0, by: 2.0) {
            let r = scheduler.retrievability(card: card, now: t0.addingTimeInterval(dayOffset * day))
            #expect(r < previous, "retrievability rose at day \(dayOffset)")
            #expect(r > 0 && r <= 1)
            previous = r
        }
    }

    @Test("A never-reviewed card reports zero retrievability")
    func newCardRetrievability() {
        // Zero rather than one, so a new card sorts to the front of a queue
        // ordered by "closest to being forgotten".
        #expect(scheduler.retrievability(card: CardState.new(due: t0), now: t0) == 0)
    }

    @Test("Initial difficulty for easy is left unclamped inside mean reversion")
    func meanReversionTargetIsRaw() {
        // Clamping D0(easy) to the 1...10 scale here is a known porting bug; it
        // silently changes every long-run difficulty trajectory.
        #expect(abs(scheduler.initialDifficulty(.easy) - (-4.771630703161737)) < tolerance)
        #expect(abs(scheduler.initialDifficulty(.good) - 2.118103970459015) < tolerance)
    }

    // MARK: - Review progressions

    @Test("A good/good/good sequence produces the reference stability, difficulty and due progression")
    func goodSequenceProgression() {
        var card = CardState.new(due: t0)

        card = scheduler.nextReview(card: card, rating: .good, now: t0)
        #expect(abs(card.stability - 2.3065) < tolerance)
        #expect(abs(card.difficulty - 2.118103970459015) < tolerance)
        #expect(card.state == .review)
        #expect(card.reps == 1)
        #expect(card.lapses == 0)
        #expect(abs(card.due.timeIntervalSince(t0) - 4 * day) < 1)

        let t1 = t0.addingTimeInterval(4 * day)
        card = scheduler.nextReview(card: card, rating: .good, now: t1)
        #expect(abs(card.stability - 16.177263202654682) < tolerance)
        #expect(abs(card.difficulty - 2.1112142357853942) < tolerance)
        #expect(card.reps == 2)
        #expect(abs(card.due.timeIntervalSince(t1) - 31 * day) < 1)

        let t2 = t1.addingTimeInterval(31 * day)
        card = scheduler.nextReview(card: card, rating: .good, now: t2)
        #expect(abs(card.stability - 90.98893922984016) < tolerance)
        #expect(abs(card.difficulty - 2.1043313908464474) < tolerance)
        #expect(card.reps == 3)
        #expect(abs(card.due.timeIntervalSince(t2) - 173 * day) < 1)
    }

    @Test("Intervals grow monotonically across a run of successes")
    func intervalsGrow() {
        var card = CardState.new(due: t0)
        var now = t0
        var previousInterval = 0.0

        for _ in 0..<8 {
            card = scheduler.nextReview(card: card, rating: .good, now: now)
            let interval = card.due.timeIntervalSince(now) / day
            #expect(interval > previousInterval)
            previousInterval = interval
            now = card.due
        }
    }

    @Test("Hard, good and easy order correctly in both stability and difficulty")
    func gradeOrdering() {
        var base = CardState.new(due: t0)
        base = scheduler.nextReview(card: base, rating: .good, now: t0)
        let t1 = t0.addingTimeInterval(4 * day)

        let hard = scheduler.nextReview(card: base, rating: .hard, now: t1)
        let good = scheduler.nextReview(card: base, rating: .good, now: t1)
        let easy = scheduler.nextReview(card: base, rating: .easy, now: t1)

        #expect(abs(hard.stability - 10.648376990076528) < tolerance)
        #expect(abs(good.stability - 16.177263202654682) < tolerance)
        #expect(abs(easy.stability - 28.285052402251956) < tolerance)
        #expect(hard.stability < good.stability)
        #expect(good.stability < easy.stability)

        // A hard answer makes the card harder; an easy one makes it easier.
        #expect(hard.difficulty > base.difficulty)
        #expect(easy.difficulty < base.difficulty)
        #expect(abs(hard.difficulty - 4.752858488532556) < tolerance)
        // Easy drives difficulty below the scale, so the stored value clamps.
        #expect(easy.difficulty == DomainTuning.default.srs.minimumDifficulty)
    }

    // MARK: - Lapses

    @Test("`.again` on a review card sends it to relearning and increments lapses")
    func lapseTransition() {
        var card = CardState.new(due: t0)
        card = scheduler.nextReview(card: card, rating: .good, now: t0)
        #expect(card.state == .review)

        let t1 = t0.addingTimeInterval(4 * day)
        let recallBefore = scheduler.retrievability(card: card, now: t1)
        #expect(abs(recallBefore - 0.8579857892330743) < tolerance)

        let lapsed = scheduler.nextReview(card: card, rating: .again, now: t1)
        #expect(lapsed.state == .relearning)
        #expect(lapsed.lapses == 1)
        #expect(lapsed.reps == 2)
        #expect(abs(lapsed.stability - 0.6614165256503188) < tolerance)
        #expect(abs(lapsed.difficulty - 7.394502741279718) < tolerance)

        // A lapse must never leave the card more stable than before.
        #expect(lapsed.stability < card.stability)

        // And it comes back inside the session, not in days.
        let stepMinutes = DomainTuning.default.srs.relearningStepMinutes
        #expect(abs(lapsed.due.timeIntervalSince(t1) - stepMinutes * 60) < 1)
    }

    @Test("Failing while already relearning does not double-count the lapse")
    func relearningDoesNotDoubleCountLapses() {
        // Otherwise one stubborn card in one session registers five lapses and
        // poisons both the post-lapse path and the coaching UI.
        var card = CardState.new(due: t0)
        card = scheduler.nextReview(card: card, rating: .good, now: t0)
        card = scheduler.nextReview(card: card, rating: .again, now: t0.addingTimeInterval(4 * day))
        #expect(card.lapses == 1)

        card = scheduler.nextReview(card: card, rating: .again, now: t0.addingTimeInterval(4 * day + 600))
        #expect(card.state == .relearning)
        #expect(card.lapses == 1)
    }

    @Test("A new card failed on first sight enters learning without a lapse")
    func newCardFailure() {
        let card = scheduler.nextReview(card: CardState.new(due: t0), rating: .again, now: t0)
        #expect(card.state == .learning)
        #expect(card.lapses == 0)
        #expect(abs(card.stability - DomainTuning.default.srs.weights[0]) < tolerance)
    }

    @Test("Relearning graduates back to review on a pass")
    func relearningGraduates() {
        var card = CardState.new(due: t0)
        card = scheduler.nextReview(card: card, rating: .good, now: t0)
        card = scheduler.nextReview(card: card, rating: .again, now: t0.addingTimeInterval(4 * day))
        card = scheduler.nextReview(card: card, rating: .good, now: t0.addingTimeInterval(4 * day + 600))
        #expect(card.state == .review)
    }

    // MARK: - Same-day handling

    @Test("Same-day repeats take the short-term path and cannot inflate stability")
    func sameDayRepeat() {
        // This is the FSRS-6-specific behaviour the app depends on: the relearn
        // retry at the end of a session must not compound into a long interval.
        var card = CardState.new(due: t0)
        card = scheduler.nextReview(card: card, rating: .good, now: t0)
        let before = card.stability

        let sameDay = t0.addingTimeInterval(600)

        let again = scheduler.nextReview(card: card, rating: .again, now: sameDay)
        #expect(abs(again.stability - 0.7750839828558983) < tolerance)
        #expect(again.stability < before)

        // The `max(increment, 1)` guard: a same-day success never loses ground.
        let hard = scheduler.nextReview(card: card, rating: .hard, now: sameDay)
        #expect(abs(hard.stability - before) < tolerance)

        let good = scheduler.nextReview(card: card, rating: .good, now: sameDay)
        #expect(abs(good.stability - before) < tolerance)

        let easy = scheduler.nextReview(card: card, rating: .easy, now: sameDay)
        #expect(abs(easy.stability - 3.9460540679694778) < tolerance)
    }

    @Test("Five same-day repeats stay far below one genuine spaced review")
    func sameDayGrindingDoesNotPayOff() {
        var ground = CardState.new(due: t0)
        ground = scheduler.nextReview(card: ground, rating: .good, now: t0)
        for i in 1...5 {
            ground = scheduler.nextReview(card: ground, rating: .good, now: t0.addingTimeInterval(Double(i) * 600))
        }

        var spaced = CardState.new(due: t0)
        spaced = scheduler.nextReview(card: spaced, rating: .good, now: t0)
        spaced = scheduler.nextReview(card: spaced, rating: .good, now: t0.addingTimeInterval(4 * day))

        #expect(ground.stability < spaced.stability)
    }

    // MARK: - Intervals

    @Test("Interval inverts the forgetting curve at the desired retention")
    func intervalInvertsCurve() {
        let interval = scheduler.interval(stability: 10)
        #expect(abs(interval - 19.064261330529586) < tolerance)
        // Round-trip: at the computed interval, recall probability is exactly
        // the desired retention.
        let r = scheduler.retrievability(elapsedDays: interval, stability: 10)
        #expect(abs(r - DomainTuning.default.srs.desiredRetention) < 1e-12)
    }

    @Test("A higher desired retention produces shorter intervals")
    func retentionShortensIntervals() {
        #expect(scheduler.interval(stability: 100, retention: 0.95)
            < scheduler.interval(stability: 100, retention: 0.85))
    }

    @Test("A mis-sized weight vector falls back to the shipping defaults")
    func malformedWeightsFallBack() {
        var tuning = DomainTuning.default.srs
        tuning.weights = [1, 2, 3]
        let fallback = FSRS6(tuning: tuning)
        let card = fallback.nextReview(card: CardState.new(due: t0), rating: .good, now: t0)
        #expect(abs(card.stability - 2.3065) < tolerance)
    }
}
