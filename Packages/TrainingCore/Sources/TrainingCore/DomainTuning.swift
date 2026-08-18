//
//  DomainTuning.swift
//  TrainingCore
//

import Foundation

/// Every tunable constant in the coaching model, in one place.
///
/// The rule this type enforces: **no magic number appears inside a decision
/// function.** Tuning a coaching model is an empirical exercise — thresholds
/// move as real user data arrives — and if the numbers are scattered through
/// the logic, every tuning pass becomes an archaeology expedition and a source
/// of merge conflicts. Everything that a future calibration pass might want to
/// move lives here, documented with the reasoning behind its default.
///
/// It is a plain `Sendable` value type: pass a modified copy into any function
/// to run a what-if, and `.default` is what ships.
public struct DomainTuning: Sendable, Hashable {

    public var srs: SRS
    public var grading: Grading
    public var cards: Cards
    public var puzzleRating: PuzzleRating
    public var ladder: Ladder
    public var calibration: Calibration
    public var curriculum: Curriculum
    public var focus: Focus

    public init(
        srs: SRS = SRS(),
        grading: Grading = Grading(),
        cards: Cards = Cards(),
        puzzleRating: PuzzleRating = PuzzleRating(),
        ladder: Ladder = Ladder(),
        calibration: Calibration = Calibration(),
        curriculum: Curriculum = Curriculum(),
        focus: Focus = Focus()
    ) {
        self.srs = srs
        self.grading = grading
        self.cards = cards
        self.puzzleRating = puzzleRating
        self.ladder = ladder
        self.calibration = calibration
        self.curriculum = curriculum
        self.focus = focus
    }

    /// The shipping configuration.
    public static let `default` = DomainTuning()

    // MARK: - Spaced repetition

    public struct SRS: Sendable, Hashable {

        /// The 21 FSRS-6 weights.
        ///
        /// These are the published defaults from the reference implementation,
        /// fitted over the Anki review corpus. They are the *prior* for a user
        /// with no review history; a future build can re-fit them per user and
        /// write the result back here.
        ///
        /// Index guide (used by ``FSRS6``):
        /// - `0...3` initial stability for again/hard/good/easy
        /// - `4, 5`  initial difficulty
        /// - `6, 7`  difficulty update: rating slope, mean-reversion strength
        /// - `8...10` stability growth on a successful recall
        /// - `11...14` post-lapse stability
        /// - `15, 16` hard penalty / easy bonus
        /// - `17...19` same-day (short-term) stability
        /// - `20` forgetting-curve decay magnitude (valid range 0.1...0.8)
        ///
        /// Note this is the *current* FSRS-6 default set, not the one shipped
        /// when FSRS-6 first landed — the defaults were re-fitted in mid-2025
        /// and the decay parameter moved from 0.2 to 0.1542. The two vectors
        /// are easy to confuse because both have 21 entries.
        public var weights: [Double] = [
            0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
            1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
            1.8729, 0.5425, 0.0912, 0.0658, 0.1542
        ]

        /// Probability of recall we aim for at the moment a card comes due.
        ///
        /// 0.85 is load-bearing: it is the FSRS default and the point where
        /// review cost per retained item is near its minimum. Raising it makes
        /// sessions longer for the same knowledge; lowering it makes cards feel
        /// unfamiliar, which for chess patterns reads as "I never learned this".
        public var desiredRetention: Double = 0.85

        /// Stability can never reach zero — the forgetting curve divides by it.
        public var minimumStability: Double = 0.001

        /// 100 years. Beyond this the card is effectively retired anyway.
        public var maximumStability: Double = 36_500

        /// FSRS difficulty is defined on a 1...10 scale.
        public var minimumDifficulty: Double = 1
        public var maximumDifficulty: Double = 10

        /// Review-state intervals are whole days, never shorter than this.
        public var minimumIntervalDays: Double = 1
        public var maximumIntervalDays: Double = 36_500

        /// Below this elapsed time a review counts as a *same-day* repeat and
        /// takes the short-term stability path instead of the long-term one.
        ///
        /// Same-day repeats are not independent evidence of retention — the
        /// answer is still in working memory — so they must not be allowed to
        /// inflate stability the way a genuine spaced recall does.
        public var sameDayThresholdDays: Double = 1.0

        /// How soon a card in `.learning` or `.relearning` comes back.
        ///
        /// Short by design: the point of a relearn step is to close the loop
        /// inside the same session, which is also what
        /// ``SessionBuilder`` relies on when it appends failed cards to the end
        /// of the queue.
        public var learningStepMinutes: Double = 10
        public var relearningStepMinutes: Double = 10

        public init() {}
    }

    // MARK: - Auto-grading

    public struct Grading: Sendable, Hashable {

        /// A correct answer this many times slower than the band median is
        /// graded `.hard` rather than `.good`.
        ///
        /// 2x is deliberately generous. Latency on a phone is noisy (the user
        /// gets interrupted, the screen locks), and a false `.hard` costs less
        /// than a false `.good`: it only means seeing the card sooner.
        public var hardLatencyMultiple: Double = 2.0

        /// A correct, first-try, full-line answer inside this many milliseconds
        /// is graded `.easy`.
        ///
        /// 10s is roughly the ceiling for pattern *recognition* as opposed to
        /// calculation. Above it the user worked the answer out, which is a
        /// different (and less durable) memory.
        public var easyLatencyMs: Double = 10_000

        public init() {}
    }

    // MARK: - Card policy

    public struct Cards: Sendable, Hashable {

        /// Fresh puzzles are served within this many rating points of the user.
        public var freshServingBand: Int = 150

        /// Hard cap on new cards admitted per day.
        ///
        /// 3 is the whole anti-burnout mechanism. A puzzle app that turns every
        /// miss into a card produces a review debt that grows faster than the
        /// user can service it, and the user quits. Three per day is roughly
        /// 90/month, which at FSRS intervals settles into a sustainable steady
        /// state of well under ten reviews a day.
        public var newCardsPerDay: Int = 3

        /// Most due cards a single session will serve.
        public var maxReviewsPerSession: Int = 7

        /// Total items in a daily session, review cards plus fresh puzzles.
        public var sessionTargetSize: Int = 10

        /// An interval at or above this counts as "long" for the
        /// anti-memorization ladder.
        ///
        /// 21 days is the point where reciting a remembered move sequence stops
        /// being plausible for most users — below it, a pass is ambiguous
        /// evidence between "knows the pattern" and "remembers the answer".
        public var longIntervalDays: Double = 21

        /// Consecutive good/easy passes at a long interval before the card's
        /// position is swapped for a theme sibling.
        public var longIntervalPassesBeforeSibling: Int = 2

        /// Theme siblings are drawn from this rating radius around the original.
        public var siblingRatingRadius: Int = 100

        /// Reviews completed before the card starts being transformed.
        ///
        /// 1 means: shown as-is the first time, transformed from the second
        /// review onward. See ``CardPolicy/presentation(for:tuning:)`` for why.
        public var reviewsBeforeTransform: Int = 1

        public init() {}
    }

    // MARK: - Puzzle rating (Glicko-1)

    public struct PuzzleRating: Sendable, Hashable {

        public var startingRating: Double = 1000

        /// A brand-new player's rating is worth almost nothing, and RD 350 says
        /// so: the first few results move the rating a long way.
        public var startingDeviation: Double = 350

        /// Puzzles have a large, stable population behind their rating, so we
        /// treat their uncertainty as fixed and small.
        public var puzzleDeviation: Double = 50

        /// RD never drops below this. A floor keeps the rating responsive to
        /// genuine improvement; without it a heavy user's rating freezes.
        public var minimumDeviation: Double = 60

        public var maximumDeviation: Double = 350

        /// Uncertainty regained per idle day.
        public var idleInflationPerDay: Double = 2

        /// Idle inflation stops here rather than at ``maximumDeviation``: a
        /// returning user is rusty, not unrated, and their history still counts.
        public var idleInflationCap: Double = 200

        /// Weight applied to the `(score - expected)` term for an SRS review.
        ///
        /// Load-bearing. A review is a *repeat* of a puzzle the user has already
        /// seen, so it is not independent evidence of strength — full-weight
        /// updates would let a user farm rating by grinding their own deck.
        public var srsReviewWeight: Double = 0.5

        public init() {}
    }

    // MARK: - Playing ladder (Elo)

    public struct Ladder: Sendable, Hashable {

        /// K-factor while the rating is still settling after calibration.
        public var earlyK: Double = 40
        /// Number of post-calibration games the early K applies to.
        public var earlyGames: Int = 15

        public var middleK: Double = 24
        /// The middle K applies through this game number (inclusive).
        public var middleThroughGame: Int = 50

        public var lateK: Double = 16

        /// Guided games are played with coaching prompts, so the result is
        /// partly the coach's. Half credit.
        public var guidedKMultiplier: Double = 0.5

        /// Performance-rating gap that counts as drift.
        public var driftThreshold: Double = 150

        /// Consecutive drifting checks before the guard fires. Two, because a
        /// single hot streak is noise at these sample sizes.
        public var driftConsecutiveChecks: Int = 2

        /// K used while the drift guard is active.
        public var driftK: Double = 40

        /// Games the boosted K lasts for.
        public var driftBoostGames: Int = 5

        /// Rating offsets applied to successive ladder opponents.
        ///
        /// Two slightly-above games, one stretch game, one level game. The
        /// mix targets roughly a 45% score: enough losing to learn from, enough
        /// winning to come back tomorrow.
        public var opponentOffsetCycle: [Int] = [50, 50, 150, 0]

        /// Opponent ratings are rounded to this step so the ladder reads as a
        /// tidy series of rungs rather than arbitrary numbers.
        public var opponentRoundingStep: Int = 25

        /// The engine personalities available at either end of the ladder.
        public var opponentRatingRange: ClosedRange<Int> = 800...2200

        public init() {}
    }

    // MARK: - Calibration

    public struct Calibration: Sendable, Hashable {

        public var gameCount: Int = 5
        public var puzzleCount: Int = 20

        /// Standard error of a 5-game estimate. Five games is a tiny sample;
        /// 180 points is honest about that.
        public var gameSigma: Double = 180

        /// A 5-game estimate outside this range is not credible — the ladder
        /// simply has not shown the user anything that far from the middle.
        public var gameRatingRange: ClosedRange<Double> = 700...1900

        /// Applied to the last opponent's rating on a clean sweep.
        public var sweepBonus: Double = 200

        /// Uncertainty after a sweep. Larger than ``gameSigma`` because the
        /// true strength is somewhere *above* the ceiling we probed, and we do
        /// not know how far above.
        public var sweepSigma: Double = 250

        /// Puzzle ratings run hot relative to over-the-board strength: a puzzle
        /// announces that a tactic exists, which is the hard half of finding
        /// one. This offset converts the puzzle scale to the playing scale.
        public var puzzleRatingOffset: Double = -100

        /// Starting rung uses `r - conservatism * sigma` rather than `r`.
        ///
        /// Deliberately pessimistic: starting a user one rung too low costs a
        /// couple of easy weeks, starting them one rung too high costs the
        /// whole curriculum's credibility.
        public var conservatism: Double = 0.5

        /// Lower bounds of rungs 2, 3, 4 on the combined estimate.
        public var rungBoundaries: [Double] = [1000, 1400, 1800]

        public init() {}
    }

    // MARK: - Curriculum

    public struct Curriculum: Sendable, Hashable {

        /// Games that must be played at a rung before advancement is possible.
        ///
        /// The metric gates alone are gameable on a small sample; this is the
        /// "you actually lived at this rung" requirement.
        public var minimumGamesAtRung: Int = 10

        /// Days that must pass at a rung. Prevents a heavy weekend from
        /// vaulting a user through the whole ladder — skill consolidation is
        /// wall-clock bound, not session bound.
        public var minimumDaysAtRung: Int = 14

        /// Move budgets for the basic-mate drills.
        public var kqkMaxMoves: Int = 15
        public var krkMaxMoves: Int = 25

        /// A KPK drill set is this many positions; a clean set is all of them.
        public var kpkSetSize: Int = 6

        /// Consecutive clean runs a drill needs.
        public var drillCleanStreakRequired: Int = 2

        /// Opening composite sub-conditions.
        public var openingCastledByMove: Int = 12
        public var openingMinorsDevelopedByMove: Int = 10
        public var openingMinorsRequired: Int = 3
        /// The composite passes with this many of its three sub-conditions.
        /// Two of three, because the third is often legitimately unavailable
        /// (an early queen trade, a forced line).
        public var openingCompositeSubConditionsRequired: Int = 2

        /// Centipawn loss that makes a hanging piece count for rung 1.
        public var hangingPieceThresholdCentipawns: Int = 300

        /// Rung 2's per-theme gate only counts puzzles at or above this rating.
        ///
        /// Without a floor the gate is trivially passed on 800-rated forks,
        /// which prove nothing about a user on their way to 1400.
        public var themeRatingFloor: Int = 1200

        /// Attempts needed per theme before the success rate is trusted.
        public var themeMinimumAttempts: Int = 15

        /// Critical moments needed before the hit rate is trusted.
        public var criticalMomentMinimumSamples: Int = 25

        /// Themes rung 2 gates on.
        public var rung2Themes: [ThemeTag] = [
            .fork, .pin, .skewer, .discoveredAttack, .backRankMate
        ]

        public init() {}
    }

    // MARK: - Weekly focus and leaks

    public struct Focus: Sendable, Hashable {

        /// Nominal leak window.
        public var leakWindowDays: Int = 21

        /// ...extended further back if the window holds fewer games than this.
        /// Below eight games the per-cause numbers are noise.
        public var leakMinimumGames: Int = 8

        /// A mistake this many games ago counts half as much as one today.
        ///
        /// Ten games is roughly a fortnight of normal play, which matches how
        /// long a habit takes to actually change. A shorter half-life makes the
        /// focus chase yesterday's game; a longer one keeps recommending work
        /// on something the user already fixed.
        public var leakHalfLifeGames: Double = 10

        /// Length of the week-over-week comparison buckets, in days.
        public var comparisonWindowDays: Int = 7

        /// A habit may hold the focus slot for at most this many consecutive
        /// weeks. Anti-thrash in the other direction: without a cap, the
        /// largest leak (which is usually also the hardest to shift) would
        /// monopolise the slot forever.
        public var maximumConsecutiveWeeks: Int = 3

        /// Non-improving weeks before the focus is force-switched.
        public var nonImprovingWeeksBeforeSwitch: Int = 3

        /// A metric still within this fraction of where it started counts as
        /// "not improving".
        public var improvementTolerance: Double = 0.10

        /// Consecutive games clearing the micro-goal that trigger an early
        /// rotation, without waiting for Monday.
        public var earlyRotationConsecutiveGames: Int = 5

        /// Drill quota multiplier applied to a habit picked by a forced switch.
        /// Double, because a forced switch means three weeks were wasted and
        /// the replacement needs to land quickly.
        public var forcedSwitchDrillMultiplier: Double = 2.0

        /// Share of a session's puzzles drawn from the focus habit's themes.
        ///
        /// 60/40 is the compromise: enough repetition to move one habit,
        /// enough breadth that the SRS deck does not starve and the user does
        /// not spend a week on a single tactic shape.
        public var focusThemeShare: Double = 0.60

        /// Ceiling on the focus share once the forced-switch multiplier is
        /// applied. Without it, `0.60 × 2.0` would claim the entire session and
        /// the SRS deck would get nothing — which is the exact starvation the
        /// 60/40 split exists to prevent.
        public var maximumFocusShare: Double = 0.80

        /// Weekday the focus rotates on, in `Calendar`'s numbering
        /// (1 = Sunday). 2 = Monday.
        public var rotationWeekday: Int = 2

        /// Tie-break when two habits own leaks of the same size: how well the
        /// habit can actually be drilled with the content we have. A habit we
        /// cannot practise deliberately is a poor weekly focus no matter how
        /// much rating it is costing.
        public var habitDrillability: [Habit: Double] = [
            .blunderCheck: 1.00,
            .scanThreats: 0.95,
            .calcToQuiet: 0.90,
            .endgameTechnique: 0.85,
            .candidatesFirst: 0.80,
            .convertCleanly: 0.75,
            .whatChanged: 0.70,
            .kingSafety: 0.60,
            .clockDiscipline: 0.40
        ]

        public init() {}
    }
}
