//
//  FSRS6.swift
//  TrainingCore
//

import Foundation

/// FSRS-6 (Free Spaced Repetition Scheduler, 21-parameter revision).
///
/// ## Why implemented here rather than taken as a dependency
///
/// Both candidate Swift packages were evaluated and rejected:
///
/// - **`open-spaced-repetition/swift-fsrs`** is correct and Swift 6 clean, but
///   its FSRS-6 support exists only on unreleased `main`. The newest tag is
///   FSRS-5 and *defaults* to the 19-parameter vector. Pinning a shipping
///   app's scheduler to an untagged revision of a third-party repository trades
///   ninety lines of arithmetic for a reproducibility problem.
/// - **`bootuz/SwiftFSRS`** is FSRS-6 and tagged, but carries a leftover FSRS-4
///   divisor in its forgetting curve that breaks the defining invariant
///   `R(S, S) = 0.9` (it returns ≈0.984), omits the post-lapse stability clamp,
///   and is not built under Swift 6 strict concurrency — its parameter and
///   algorithm types are not `Sendable`.
///
/// FSRS-6 specifically, rather than 5, because of the short-term stability
/// path: FSRS-6 adds an `S^(−w[19])` term that stops repeated same-session
/// retries from inflating stability. Same-session retries are *exactly* what
/// this app does — every failed card comes back at the end of the same
/// session — so under FSRS-5 the relearn loop would quietly over-schedule
/// every card the user struggles with most.
///
/// ## The model
///
/// Every card carries two numbers:
/// - **stability** `S` — days until recall probability decays to 90%
/// - **difficulty** `D` — 1...10, how grudgingly this card's stability grows
///
/// A review reads the current recall probability `R`, updates `D` from the
/// grade, then updates `S` along one of three paths (successful recall, lapse,
/// or same-day repeat), and finally schedules the card for the moment `R` will
/// have decayed to ``DomainTuning/SRS/desiredRetention``.
public struct FSRS6: SchedulerProtocol {

    /// The scheduler's tuning. Held by value: two schedulers with different
    /// weights can coexist, which is how a re-fit is A/B'd.
    public let tuning: DomainTuning.SRS

    /// Resolved weights. Falls back to the published defaults if a caller hands
    /// over a vector of the wrong length — a mis-sized weight array is a
    /// configuration bug, and crashing a review session over it would be worse
    /// than scheduling with the shipping prior.
    private let w: [Double]

    /// `w[20]` is the (positive) magnitude; the curve's exponent is its
    /// negative. Cached because it appears in every retrievability call.
    private let decay: Double

    /// Chosen so that `R(S, S) = 0.9` exactly, whatever the decay is:
    /// solving `(1 + factor)^decay = 0.9` gives `factor = 0.9^(1/decay) − 1`.
    /// This is what keeps "stability" meaning "days to 90% recall" across
    /// re-fits of `w[20]`.
    private let factor: Double

    public init(tuning: DomainTuning.SRS = DomainTuning.default.srs) {
        self.tuning = tuning
        let resolved = tuning.weights.count == FSRS6.parameterCount
            ? tuning.weights
            : DomainTuning.SRS().weights
        self.w = resolved
        let decay = -resolved[20]
        self.decay = decay
        self.factor = pow(0.9, 1 / decay) - 1
    }

    /// FSRS-6 has 21 fitted parameters. FSRS-5 had 19, FSRS-4.5 had 17 — the
    /// count is the quickest way to tell which revision a weight vector is for.
    public static let parameterCount = 21

    // MARK: - SchedulerProtocol

    /// Recall probability under the power-law forgetting curve.
    ///
    /// ```
    /// R(t, S) = (1 + factor · t / S) ^ decay
    /// ```
    ///
    /// Power law rather than the exponential `e^(−t/S)` that older SRS
    /// algorithms used: real forgetting has a long tail — the probability of
    /// still knowing something a year later is far higher than an exponential
    /// predicts — and modelling that tail is most of FSRS's accuracy advantage.
    public func retrievability(card: CardState, now: Date) -> Double {
        // A card with no memory yet has no recall probability. Reporting 0
        // rather than 1 also makes new cards sort first in a queue ordered by
        // "closest to being forgotten", which is the behaviour we want.
        guard card.stability > 0, card.lastReview != nil else { return 0 }
        return retrievability(elapsedDays: card.elapsedDays(at: now), stability: card.stability)
    }

    public func nextReview(card: CardState, rating: ReviewRating, now: Date) -> CardState {
        var next = card
        next.reps += 1
        next.lastReview = now

        if card.state == .new {
            // First ever exposure: the grade alone seeds both parameters.
            next.stability = clampStability(initialStability(rating))
            next.difficulty = clampDifficulty(initialDifficulty(rating))
        } else {
            let elapsed = card.elapsedDays(at: now)
            let recall = retrievability(card: card, now: now)

            // Ordering is load-bearing and matches the reference trainer: the
            // stability update reads the difficulty the card had *going into*
            // this review, and difficulty is advanced afterwards. Using the new
            // difficulty here would double-count the grade.
            if elapsed < tuning.sameDayThresholdDays {
                next.stability = clampStability(
                    shortTermStability(stability: card.stability, rating: rating)
                )
            } else if rating == .again {
                next.stability = clampStability(
                    postLapseStability(
                        stability: card.stability,
                        difficulty: card.difficulty,
                        recall: recall
                    )
                )
            } else {
                next.stability = clampStability(
                    recallStability(
                        stability: card.stability,
                        difficulty: card.difficulty,
                        recall: recall,
                        rating: rating
                    )
                )
            }

            next.difficulty = clampDifficulty(
                nextDifficulty(current: card.difficulty, rating: rating)
            )
        }

        next.state = nextState(from: card.state, rating: rating)

        // A graduated card that was just failed is the definition of a lapse.
        // Failures inside the learning/relearning loop are not counted again —
        // one bad card would otherwise register five lapses in one session and
        // poison both the post-lapse path and the "keeps catching you" UI.
        if card.state == .review, rating == .again {
            next.lapses += 1
        }

        next.due = dueDate(for: next, now: now)
        return next
    }

    // MARK: - Forgetting curve

    /// `R(t, S) = (1 + factor · t / S) ^ decay`
    func retrievability(elapsedDays: Double, stability: Double) -> Double {
        let s = max(stability, tuning.minimumStability)
        let t = max(elapsedDays, 0)
        return pow(1 + factor * t / s, decay)
    }

    /// Inverts the forgetting curve: the number of days until recall
    /// probability falls to `retention`.
    ///
    /// ```
    /// I(r, S) = (S / factor) · (r ^ (1 / decay) − 1)
    /// ```
    ///
    /// This is where ``DomainTuning/SRS/desiredRetention`` turns into a
    /// calendar date, and therefore where the whole review-load/retention
    /// trade-off is made.
    public func interval(stability: Double, retention: Double? = nil) -> Double {
        let r = min(max(retention ?? tuning.desiredRetention, 0.0001), 0.9999)
        let raw = (stability / factor) * (pow(r, 1 / decay) - 1)
        return min(max(raw, tuning.minimumIntervalDays), tuning.maximumIntervalDays)
    }

    // MARK: - Initial values

    /// `S₀(G) = w[G − 1]`
    ///
    /// The four initial-stability weights are literally "how many days does a
    /// first review at this grade buy you", fitted directly.
    func initialStability(_ rating: ReviewRating) -> Double {
        w[rating.rawValue - 1]
    }

    /// `D₀(G) = w[4] − e^(w[5] · (G − 1)) + 1`
    ///
    /// Exponential in the grade, so the gap between "good" and "easy" is much
    /// larger than between "again" and "hard": an easy first answer is strong
    /// evidence the pattern is already known, a hard one barely distinguishes
    /// itself from a failure.
    func initialDifficulty(_ rating: ReviewRating) -> Double {
        w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1
    }

    // MARK: - Difficulty update

    /// Difficulty after a review, with linear damping and mean reversion.
    ///
    /// ```
    /// ΔD  = −w[6] · (G − 3)
    /// D'  = D + ΔD · (10 − D) / 9        // linear damping
    /// D'' = w[7] · D₀(easy) + (1 − w[7]) · D'   // mean reversion
    /// ```
    ///
    /// The damping term shrinks the change as `D` approaches 10, so a card
    /// cannot be driven to maximum difficulty by a run of bad luck and then be
    /// stuck there. Mean reversion pulls every card slowly back toward the
    /// difficulty of an easy first answer, which is what stops long-lived cards
    /// from ratcheting monotonically harder over years of reviews.
    ///
    /// `D₀(easy)` here is deliberately the **unclamped** value. With the
    /// shipping weights it is about −4.77, well outside the 1...10 scale, and
    /// clamping it to 1 — the obvious-looking "fix" — moves the reversion
    /// target and measurably changes long-run scheduling. The reference
    /// implementations use the raw value, and clamping it is a known porting
    /// bug in a third-party Swift FSRS package. The clamp belongs on the
    /// *stored* difficulty only, which is where ``nextReview(card:rating:now:)``
    /// applies it.
    func nextDifficulty(current: Double, rating: ReviewRating) -> Double {
        let delta = -w[6] * Double(rating.rawValue - 3)
        let damped = current + delta * (10 - current) / 9
        return w[7] * initialDifficulty(.easy) + (1 - w[7]) * damped
    }

    // MARK: - Stability updates

    /// Stability after a successful recall (hard, good or easy).
    ///
    /// ```
    /// S' = S · (1 + e^w[8] · (11 − D) · S^(−w[9]) · (e^(w[10]·(1−R)) − 1) · h · e)
    /// ```
    ///
    /// Three ideas are stacked here:
    /// - `(11 − D)`: easy cards gain more from a review than hard ones.
    /// - `S^(−w[9])`: diminishing returns — a card already stable for a year
    ///   gains proportionally less than one stable for a week.
    /// - `(e^(w[10]·(1−R)) − 1)`: the *spacing effect*. The lower `R` was when
    ///   the card was answered — the closer to forgotten — the more the
    ///   successful recall is worth. Reviewing something you already know cold
    ///   (`R ≈ 1`) buys almost nothing, and this term is what encodes that.
    ///
    /// `h` is ``DomainTuning/SRS/weights```[15]` on a hard answer and `e` is
    /// `[16]` on an easy one; both are 1 for `.good`.
    func recallStability(
        stability: Double,
        difficulty: Double,
        recall: Double,
        rating: ReviewRating
    ) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        let growth = exp(w[8])
            * (11 - difficulty)
            * pow(stability, -w[9])
            * (exp(w[10] * (1 - recall)) - 1)
            * hardPenalty
            * easyBonus
        return stability * (1 + growth)
    }

    /// Stability after a lapse.
    ///
    /// ```
    /// S_f = w[11] · D^(−w[12]) · ((S + 1)^w[13] − 1) · e^(w[14]·(1−R))
    /// S'  = min(S_f, S / e^(w[17]·w[18]))
    /// ```
    ///
    /// The forgotten card keeps *some* of its stability — relearning is faster
    /// than learning, and `(S+1)^w[13]` carries that memory forward. The `min`
    /// clamp is the important half: without it the post-lapse formula can
    /// return a value *above* the card's pre-lapse stability for very unstable
    /// cards, which would reward failing.
    func postLapseStability(stability: Double, difficulty: Double, recall: Double) -> Double {
        let raw = w[11]
            * pow(difficulty, -w[12])
            * (pow(stability + 1, w[13]) - 1)
            * exp(w[14] * (1 - recall))
        let ceiling = stability / exp(w[17] * w[18])
        return min(raw, ceiling)
    }

    /// Stability for a repeat inside the same day.
    ///
    /// ```
    /// inc = e^(w[17] · (G − 3 + w[18])) · S^(−w[19])
    /// S'  = S · (G ≥ good ? max(inc, 1) : inc)
    /// ```
    ///
    /// This is FSRS-6's headline change and the reason this app needs FSRS-6
    /// specifically. The `S^(−w[19])` term makes the same-day gain shrink as
    /// stability grows, so hammering a card five times in one session does not
    /// compound into a multi-month interval. Answering something correctly
    /// ninety seconds after seeing the answer is working memory, not learning.
    ///
    /// The `max(inc, 1)` guard stops a same-day answer the user *got right*
    /// from ever reducing stability, which the raw formula can do once `S` is
    /// large. The guard applies from `.hard` upward, not from `.good`: a hard
    /// same-day success is still a success, and the reference implementation
    /// was corrected in this direction.
    func shortTermStability(stability: Double, rating: ReviewRating) -> Double {
        let increment = exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
            * pow(stability, -w[19])
        let guarded = rating.rawValue >= ReviewRating.hard.rawValue
            ? max(increment, 1)
            : increment
        return stability * guarded
    }

    // MARK: - Lifecycle

    /// The state machine.
    ///
    /// Learning steps are deliberately minimal — one step — because this app
    /// closes the loop differently: a failed card is re-queued at the end of
    /// the same session by ``SessionBuilder``, not held in a multi-step ladder.
    func nextState(from state: SRSState, rating: ReviewRating) -> SRSState {
        switch state {
        case .new:
            return rating == .again ? .learning : .review
        case .learning:
            return rating == .again ? .learning : .review
        case .review:
            return rating == .again ? .relearning : .review
        case .relearning:
            return rating == .again ? .relearning : .review
        }
    }

    /// When the card comes back.
    ///
    /// Learning and relearning cards get a short fixed step so they land inside
    /// the current session; graduated cards get the forgetting-curve interval,
    /// rounded to whole days because a review scheduled for "3.7 days" has no
    /// meaning to a user who studies once a day.
    func dueDate(for card: CardState, now: Date) -> Date {
        switch card.state {
        case .learning:
            return now.addingTimeInterval(tuning.learningStepMinutes * 60)
        case .relearning:
            return now.addingTimeInterval(tuning.relearningStepMinutes * 60)
        case .review:
            let days = (interval(stability: card.stability)).rounded()
            let clamped = min(max(days, tuning.minimumIntervalDays), tuning.maximumIntervalDays)
            return now.addingTimeInterval(clamped * 86_400)
        case .new:
            // Unreachable: `nextState` never returns `.new`. Scheduling for now
            // is the harmless answer if that ever changes.
            return now
        }
    }

    // MARK: - Clamping

    private func clampStability(_ value: Double) -> Double {
        guard value.isFinite else { return tuning.minimumStability }
        return min(max(value, tuning.minimumStability), tuning.maximumStability)
    }

    private func clampDifficulty(_ value: Double) -> Double {
        guard value.isFinite else { return tuning.minimumDifficulty }
        return min(max(value, tuning.minimumDifficulty), tuning.maximumDifficulty)
    }
}
