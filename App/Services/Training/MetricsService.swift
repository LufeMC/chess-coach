//
//  MetricsService.swift
//  ChessCoach
//

import Database
import Foundation
import Observation
import TrainingCore

/// Read and write access to the metric history the Profile chart is drawn from.
///
/// Separate from `MetricStore` because it describes a different table with the
/// opposite lifecycle — see `Database.MetricSample` — and because exactly two
/// places in the app touch it: this service writes samples, `ProfileDataLoader`
/// reads them. It lives here, beside its writer, rather than with the other
/// store protocols in `TrainingStores.swift`.
protocol MetricHistoryStore: Sendable {
    func recordSample(
        key: String,
        window: String,
        value: Double,
        measuredAt: Date,
        now: Date,
        calendar: Calendar
    ) throws
    func samples(key: String, window: String, limit: Int) throws -> [MetricSample]
}

extension MetricsRepository: MetricHistoryStore {}

/// The user's micro-goal for the week: one metric, one number to beat.
///
/// Derived from the curriculum rather than invented. The weekly focus names a
/// habit; the rung names a skill trained by that habit; that skill's first
/// criterion is already "this metric, this threshold, this direction". Making
/// the micro-goal anything else would mean the user could clear their weekly
/// goal and see no movement on the ladder, which is the fastest way to make a
/// curriculum feel fake.
struct MicroGoalState: Sendable, Hashable {
    var metricKey: MetricKey
    var window: MetricWindow
    var target: Double
    var comparison: MetricComparison
    var current: Double?

    var isMet: Bool {
        guard let current else { return false }
        return comparison.evaluate(current, threshold: target)
    }
}

/// Everything the curriculum UI needs, computed together so it is internally
/// consistent.
struct CurriculumState: Sendable {
    var rung: Int
    var snapshot: MetricSnapshot
    var decision: AdvancementDecision
    var leaks: [Leak]
    var focus: WeeklyFocus?
    var microGoal: MicroGoalState?
    var gamesAtRung: Int
    var daysAtRung: Int

    init(
        rung: Int,
        snapshot: MetricSnapshot,
        decision: AdvancementDecision,
        leaks: [Leak] = [],
        focus: WeeklyFocus? = nil,
        microGoal: MicroGoalState? = nil,
        gamesAtRung: Int = 0,
        daysAtRung: Int = 0
    ) {
        self.rung = rung
        self.snapshot = snapshot
        self.decision = decision
        self.leaks = leaks
        self.focus = focus
        self.microGoal = microGoal
        self.gamesAtRung = gamesAtRung
        self.daysAtRung = daysAtRung
    }
}

/// Computes the curriculum's measurable skills from stored data, writes them
/// back, and decides rung progression and the weekly focus.
///
/// `@MainActor @Observable` for the same reason as ``TrainingService``: the
/// results are bound directly by the progress UI, and every expensive step runs
/// in a `nonisolated static` that genuinely leaves the main actor.
@MainActor
@Observable
final class MetricsService {

    // MARK: Stored keys
    //
    // State the selectors need that has nowhere else to live. All of it is a
    // single number keyed by `(key, window)`, so it goes in `skillMetrics`
    // rather than earning a table.

    enum Keys {
        static let rungEnteredAt = "curriculum.rungEnteredAt"
        static let focusWeeksOnHabit = "focus.weeksOnHabit"
        static let focusWeekStartedAt = "focus.weekStartedAt"
        static let focusWeeksWithoutImprovement = "focus.weeksWithoutImprovement"
        static let focusMicroGoalStartValue = "focus.microGoalStartValue"
        static let focusConsecutiveGamesMeetingGoal = "focus.consecutiveGamesMeetingGoal"
        /// Start date of the newest analysed game already counted toward
        /// ``focusConsecutiveGamesMeetingGoal``. See ``advanceMicroGoalStreak``.
        static let focusMicroGoalGameMark = "focus.microGoalGameMark"
        /// The drill multiplier of the focus in force, so a session built
        /// without a recompute still gets the mix the selector intended.
        static let focusDrillQuotaMultiplier = "focus.drillQuotaMultiplier"
    }

    /// The metrics whose history is kept.
    ///
    /// Deliberately three. Every key here costs a row for each day its value
    /// stands still, forever, on a table that synchronises — so it holds
    /// precisely what the Profile chart plots and nothing else. Per-game
    /// accuracy is absent because `games.userAccuracy` is already a time series
    /// and a second copy could only disagree with it, and the curriculum gates
    /// are absent because a gate never asks what a metric *was*.
    nonisolated static let historyKeys: [MetricKey] = [
        .ladderRating,
        .puzzleRating,
        .puzzleRatingDeviation,
    ]

    // MARK: Dependencies

    private nonisolated let games: any GameStore
    private nonisolated let moments: any MomentStore
    private nonisolated let metrics: any MetricStore
    /// `nil` when the metric store keeps no history, which is the honest answer
    /// for the in-memory store used by previews and tests.
    private nonisolated let history: (any MetricHistoryStore)?
    private nonisolated let settings: any AppSettingsStore
    private nonisolated let guided: any GuidedPromptLog
    private nonisolated let tuning: DomainTuning
    private nonisolated let ladder: [Rung]
    private nonisolated let calendar: Calendar
    private nonisolated let clock: @Sendable () -> Date

    /// - Parameter guided: Source of guided-mode prompt outcomes. Defaults to
    ///   ``GameMovePromptLog`` over `games` rather than to
    ///   ``EmptyGuidedPromptLog``, and the difference is a whole rung: the
    ///   empty log leaves `guided.scanThreats.hitRate` permanently unmeasured,
    ///   `Skill.evaluate(in:)` counts unmeasured as unmet, and `r2.threatAwareness`
    ///   is required — so with the empty default the ladder had a hard ceiling
    ///   at rung 2 no matter how well the user played. A `nil` default rather
    ///   than a literal because the replacement is built from another
    ///   parameter, which a default expression cannot see.
    init(
        games: any GameStore,
        moments: any MomentStore,
        metrics: any MetricStore,
        settings: any AppSettingsStore,
        guided: (any GuidedPromptLog)? = nil,
        tuning: DomainTuning = .default,
        ladder: [Rung] = Curriculum.default,
        calendar: Calendar = Calendar(identifier: .gregorian),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.games = games
        self.moments = moments
        self.metrics = metrics
        // Taken from `metrics` rather than as a second parameter on purpose:
        // the history and the metric rows are the same store, and two
        // parameters would let a caller wire a chart to one database and the
        // numbers behind it to another.
        self.history = metrics as? any MetricHistoryStore
        self.settings = settings
        self.guided = guided ?? GameMovePromptLog(games: games)
        self.tuning = tuning
        self.ladder = ladder
        self.calendar = calendar
        self.clock = clock
    }

    // MARK: Observable state

    private(set) var state: CurriculumState?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    /// Recomputes every metric the ladder names, persists them, and re-runs
    /// advancement and focus selection.
    ///
    /// Called after a game is analysed and on app foreground. Cheap enough to
    /// run eagerly: the expensive part is the board replay, bounded by the
    /// largest window the ladder asks for (20 games).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            state = try await Self.recompute(
                games: games,
                moments: moments,
                metrics: metrics,
                history: history,
                settings: settings,
                guided: guided,
                tuning: tuning,
                ladder: ladder,
                calendar: calendar,
                now: clock()
            )
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Applies an advancement decision, moving the user up a rung.
    ///
    /// Separate from ``refresh()`` because promotion is a *moment* in the app —
    /// it deserves a screen and an acknowledgement — not a side effect of a
    /// background recompute.
    @discardableResult
    func advanceRung() async -> Int? {
        guard let state, state.decision.canAdvance, let next = state.decision.nextRung else { return nil }
        let now = clock()
        do {
            try settings.update { $0.currentRung = next }
            try metrics.set(Keys.rungEnteredAt, value: now.timeIntervalSince1970, sampleCount: 1, at: now)
            await refresh()
            return next
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    /// Overrides the selected focus — used when the coach's suggestion is
    /// accepted, or when the user picks a different habit for the week.
    ///
    /// Refreshes **first** and applies the override afterwards, rather than
    /// writing the habit and then recomputing. Selection is what chose the
    /// habit being overridden, so re-running it hands the slot straight back —
    /// on a rotation weekday it would return the leak table's own answer, and a
    /// control that silently undoes itself is worse than no control. The
    /// override is written to exactly the storage a rotation writes, so the
    /// next recompute reads it as the focus in force and leaves it alone until
    /// the next rotation point.
    func setFocus(habit: Habit) async {
        await refresh()

        let now = clock()
        _ = try? settings.update { $0.weeklyFocusHabit = habit.rawValue }

        // Everything a rotation resets, because this is one: the streak, the
        // improvement clock and the baseline the trend is measured against all
        // describe the habit being replaced. Leaving them would let a stale
        // "three weeks without improvement" force-switch the user off the habit
        // they just chose, on the very next recompute.
        try? metrics.set(Keys.focusWeeksOnHabit, value: 1, sampleCount: 1, at: now)
        try? metrics.set(Keys.focusWeekStartedAt, value: now.timeIntervalSince1970, sampleCount: 1, at: now)
        try? metrics.set(Keys.focusWeeksWithoutImprovement, value: 0, sampleCount: 1, at: now)
        try? metrics.set(Keys.focusConsecutiveGamesMeetingGoal, value: 0, sampleCount: 1, at: now)
        try? metrics.set(Keys.focusDrillQuotaMultiplier, value: 1, sampleCount: 1, at: now)

        guard var updated = state else { return }
        let goal = Self.microGoal(for: habit, rung: updated.rung, ladder: ladder, snapshot: updated.snapshot)
        try? metrics.set(Keys.focusMicroGoalStartValue, value: goal?.current ?? 0, sampleCount: 1, at: now)

        updated.focus = WeeklyFocus(
            habit: habit,
            epLostPerGame: updated.leaks.first { $0.habit == habit }?.epLostPerGame ?? 0,
            reason: .initialSelection
        )
        updated.microGoal = goal
        state = updated
    }

    /// The focus a training session should be assembled against.
    ///
    /// Prefers the recomputed focus and falls back to the stored one, because
    /// the session cannot wait: a user who opens Train and taps Start before
    /// the recompute lands must still get their week's 60/40 mix, and the
    /// selector's last answer is already on disk.
    var sessionFocus: WeeklyFocus? {
        state?.focus ?? Self.storedFocus(metrics: metrics, settings: settings)
    }

    /// The focus in force, read back from storage rather than reselected.
    ///
    /// Selecting a focus replays up to twenty games; nothing that merely needs
    /// to *know* the week's habit should pay that. Selection writes its answer
    /// down — the habit onto `AppSettings`, the drill multiplier alongside the
    /// rest of the focus counters — so reading it back is two indexed lookups.
    ///
    /// `epLostPerGame` and `primaryCauseTag` are deliberately not restored:
    /// they are copy for the leak chart, and nothing in session assembly reads
    /// either.
    nonisolated static func storedFocus(
        metrics: any MetricStore,
        settings: any AppSettingsStore
    ) -> WeeklyFocus? {
        guard
            let stored = try? settings.current(),
            let habit = stored.weeklyFocusHabit.flatMap(Habit.init(rawValue:))
        else { return nil }

        return WeeklyFocus(
            habit: habit,
            drillQuotaMultiplier: metrics.value(Keys.focusDrillQuotaMultiplier, default: 1),
            reason: .unchanged
        )
    }
}

// MARK: - Computation

extension MetricsService {

    private nonisolated static func recompute(
        games: any GameStore,
        moments: any MomentStore,
        metrics: any MetricStore,
        history: (any MetricHistoryStore)?,
        settings: any AppSettingsStore,
        guided: any GuidedPromptLog,
        tuning: DomainTuning,
        ladder: [Rung],
        calendar: Calendar,
        now: Date
    ) async throws -> CurriculumState {

        let stored = try settings.current()
        let rung = max(1, stored.currentRung)

        // Load exactly as far back as the widest window the ladder names — no
        // further. A user with three hundred games does not want three hundred
        // board replays to see their progress ring.
        //
        // Only games the analysis pass finished. Every rate on Today and Profile
        // is `causes / userMoves`, and the two halves come from different
        // places: `userMoves` is counted off the move list, which exists from
        // the moment the game is saved, while the causes come from moments,
        // which only exist after analysis. A pending, failed or half-finished
        // game therefore contributes a full denominator and no numerator, and
        // every leak rate is pulled toward zero by exactly the games nobody has
        // looked at yet — so a backlog reads as improvement, and the curriculum
        // promotes on it.
        //
        // Dropping them costs nothing real: an unanalysed game has no moments
        // and no evals, so it was never contributing evidence, only dilution.
        // The window is taken *after* filtering so "last 20 games" means twenty
        // games that were actually measured.
        let horizon = maximumWindowGames(in: ladder)
        let recent = Array(
            try games
                .recent(limit: horizon * Self.unanalysedGameAllowance)
                .filter { $0.analysis == .complete }
                .prefix(horizon)
        )

        var analysed: [AnalysedGame] = []
        analysed.reserveCapacity(recent.count)
        let prompts = try guided.prompts(forGames: recent.map(\.id))
        let promptsByGame = Dictionary(grouping: prompts, by: \.gameID)

        for game in recent {
            analysed.append(
                AnalysedGame(
                    game: game,
                    moves: (try? games.moves(forGame: game.id)) ?? [],
                    moments: (try? moments.moments(forGame: game.id)) ?? [],
                    evals: (try? games.evals(forGame: game.id)) ?? [],
                    guidedPrompts: promptsByGame[game.id] ?? []
                )
            )
        }

        let counters = loadCounters(metrics: metrics, settings: stored, tuning: tuning)
        let computed = MetricComputer.compute(
            games: analysed,
            counters: counters,
            ladder: ladder,
            tuning: tuning
        )

        // Read the tracked rows *before* the persist loop below overwrites
        // them, and keep the whole row rather than only its timestamp. A stored
        // row that already carries the value about to be recorded was written
        // by whoever moved the number — `LadderRatingWriter`, at the end of the
        // game that moved it — so its `updatedAt` is the instant the user
        // earned it, and that is where the point belongs on the chart. A row
        // still carrying the *previous* value is stale evidence about a change
        // this recompute is the first to see, and the honest stamp for that
        // is `now`.
        let previouslyStored: [MetricKey: SkillMetric] =
            history == nil
            ? [:]
            : Dictionary(
                uniqueKeysWithValues: historyKeys.compactMap { key -> (MetricKey, SkillMetric)? in
                    guard
                        let row = try? metrics.metric(
                            key: key.rawValue,
                            window: MetricWindow.allTime.key
                        )
                    else { return nil }
                    return (key, row)
                }
            )

        // Persist, then read back into a snapshot from the same values so the
        // UI and the database never disagree.
        var snapshot = MetricSnapshot()
        for (address, value) in computed {
            try? metrics.upsert(
                key: address.key.rawValue,
                window: address.window.key,
                value: value.value,
                sampleCount: value.sampleCount,
                updatedAt: now
            )
            snapshot[address.key, address.window] = value
        }

        // The chart's history. Nothing is backfilled behind the first sample:
        // the rating's past was never stored — every recompute overwrote the
        // one `skillMetrics` row and its timestamp with it — so a curve drawn
        // behind today would be invented, and a flat line from the calibration
        // date to now would assert a rating that held still through games that
        // certainly moved it. History therefore begins at the first refresh,
        // with one true point; per-game accuracy, which *was* always stored,
        // plots its whole past immediately.
        if let history {
            for key in historyKeys {
                guard let value = computed[MetricAddress(key: key, window: .allTime)] else {
                    continue
                }
                let measuredAt =
                    previouslyStored[key]
                    .flatMap { $0.value == value.value ? $0.updatedAt : nil } ?? now
                try? history.recordSample(
                    key: key.rawValue,
                    window: MetricWindow.allTime.key,
                    value: value.value,
                    measuredAt: measuredAt,
                    now: now,
                    calendar: calendar
                )
            }
        }

        // Time and volume at the current rung.
        let rungEnteredAt = rungEntryDate(metrics: metrics, games: recent, now: now)
        let gamesAtRung = recent.filter { $0.startedAt >= rungEnteredAt }.count
        let daysAtRung = max(0, calendar.dateComponents([.day], from: rungEnteredAt, to: now).day ?? 0)

        let decision = advancement(
            state: AdvancementState(
                currentRung: rung,
                metrics: snapshot,
                gamesAtRung: gamesAtRung,
                daysAtRung: daysAtRung
            ),
            ladder: ladder,
            tuning: tuning.curriculum
        )

        // Rating-leak chart.
        let leaks = LeakAnalyzer.leaks(
            from: analysed.flatMap { analysedGame in
                analysedGame.moments.map { moment in
                    MistakeRecord(
                        gameID: analysedGame.game.id.uuidString,
                        causeTag: TrainingVocabulary.trainingCause(rawValue: moment.causeTag),
                        deltaEP: moment.deltaEP
                    )
                }
            },
            games: recent.map { GameRecord(id: $0.id.uuidString, playedAt: $0.startedAt) },
            rung: rung,
            now: now,
            tuning: tuning.focus
        )

        // Weekly focus.
        let currentHabit = stored.weeklyFocusHabit.flatMap(Habit.init(rawValue:))
        let currentFocus = currentHabit.map { habit in
            WeeklyFocus(
                habit: habit,
                epLostPerGame: leaks.first { $0.habit == habit }?.epLostPerGame ?? 0,
                reason: .unchanged
            )
        }

        var weeksOnFocus = Int(metrics.value(Keys.focusWeeksOnHabit))
        let weekStartedAt = Date(timeIntervalSince1970: metrics.value(Keys.focusWeekStartedAt, default: now.timeIntervalSince1970))
        if now.timeIntervalSince(weekStartedAt) >= Double(tuning.focus.comparisonWindowDays) * 86_400 {
            weeksOnFocus += 1
        }

        let currentGoal = currentHabit.flatMap { microGoal(for: $0, rung: rung, ladder: ladder, snapshot: snapshot) }
        let trend = FocusMetricTrend(
            weeksWithoutImprovement: Int(metrics.value(Keys.focusWeeksWithoutImprovement)),
            consecutiveGamesMeetingMicroGoal: advanceMicroGoalStreak(
                goal: currentGoal,
                games: recent,
                metrics: metrics,
                now: now
            ),
            startValue: metrics.value(Keys.focusMicroGoalStartValue, default: currentGoal?.current ?? 0),
            currentValue: currentGoal?.current ?? 0
        )

        let focus = FocusSelector.selectFocus(
            leaks: leaks,
            rung: rung,
            currentFocus: currentFocus,
            weeksOnFocus: weeksOnFocus,
            metricTrend: trend,
            now: now,
            calendar: calendar,
            ladder: ladder,
            tuning: tuning.focus
        )

        try? persistFocus(
            focus,
            previousHabit: currentHabit,
            weeksOnFocus: weeksOnFocus,
            trend: trend,
            goal: microGoal(for: focus.habit, rung: rung, ladder: ladder, snapshot: snapshot),
            metrics: metrics,
            settings: settings,
            tuning: tuning.focus,
            now: now
        )

        return CurriculumState(
            rung: rung,
            snapshot: snapshot,
            decision: decision,
            leaks: leaks,
            focus: focus,
            microGoal: microGoal(for: focus.habit, rung: rung, ladder: ladder, snapshot: snapshot),
            gamesAtRung: gamesAtRung,
            daysAtRung: daysAtRung
        )
    }

    /// How much deeper than the window to read, so the window can still be
    /// filled once unanalysed games are dropped.
    ///
    /// A bound rather than an unlimited scan: the analysis queue drains in the
    /// background, so a handful of recent games being unanalysed is normal and a
    /// long backlog is not. Reading three windows' worth covers the normal case
    /// and refuses to replay a user's whole history for the pathological one —
    /// where the honest answer is a smaller sample, which the sample-size
    /// disclosures on Profile already say out loud.
    nonisolated static let unanalysedGameAllowance = 3

    /// The widest `lastGames` window the ladder asks for.
    nonisolated static func maximumWindowGames(in ladder: [Rung]) -> Int {
        let counts = MetricComputer.windows(in: ladder).compactMap { window -> Int? in
            if case let .lastGames(count) = window { return count }
            return nil
        }
        return counts.max() ?? 20
    }

    /// The micro-goal for a habit at a rung.
    nonisolated static func microGoal(
        for habit: Habit,
        rung: Int,
        ladder: [Rung],
        snapshot: MetricSnapshot
    ) -> MicroGoalState? {
        guard
            let rungDefinition = ladder.first(where: { $0.id == rung }),
            let skill = rungDefinition.skills.first(where: { $0.habit == habit }),
            let criterion = skill.criteria.first
        else { return nil }

        return MicroGoalState(
            metricKey: criterion.metricKey,
            window: criterion.window,
            target: criterion.threshold,
            comparison: criterion.comparison,
            current: snapshot[criterion.metricKey, criterion.window]?.value
        )
    }

    /// Moves the consecutive-games-clearing-the-micro-goal streak on, at most
    /// once per analysed game.
    ///
    /// `FocusSelector`'s early-rotation rule reads this counter and
    /// ``persistFocus(_:previousHabit:weeksOnFocus:trend:goal:metrics:settings:tuning:now:)``
    /// resets it, but nothing ever raised it — so the rule could not fire, and
    /// a habit the user had already fixed held the focus slot until the weekly
    /// cap ran out.
    ///
    /// The advance is gated on a *watermark* rather than happening on every
    /// call, because ``refresh()`` also runs on app foreground and on every
    /// Profile load: without it, opening the app five times on a good afternoon
    /// would rotate the week's focus. The watermark is the start date of the
    /// newest **analysed** game already counted, because only an analysed game
    /// can have moved the metric the goal is measured on — counting a game the
    /// moment it is saved would score the user on the numbers from the game
    /// before it.
    private nonisolated static func advanceMicroGoalStreak(
        goal: MicroGoalState?,
        games: [Database.Game],
        metrics: any MetricStore,
        now: Date
    ) -> Int {
        let stored = Int(metrics.value(Keys.focusConsecutiveGamesMeetingGoal))
        guard let goal else { return stored }

        guard
            let newest = games
                .filter({ $0.analysisState == AnalysisState.complete.rawValue })
                .map(\.startedAt)
                .max(),
            newest.timeIntervalSince1970 > metrics.value(Keys.focusMicroGoalGameMark)
        else { return stored }

        let advanced = goal.isMet ? stored + 1 : 0
        try? metrics.set(Keys.focusConsecutiveGamesMeetingGoal, value: Double(advanced), sampleCount: 1, at: now)
        try? metrics.set(
            Keys.focusMicroGoalGameMark,
            value: newest.timeIntervalSince1970,
            sampleCount: 1,
            at: now
        )
        return advanced
    }

    private nonisolated static func loadCounters(
        metrics: any MetricStore,
        settings stored: AppSettings,
        tuning: DomainTuning
    ) -> MetricCounters {
        var counters = MetricCounters()
        counters.puzzleRating = stored.puzzleRating
        counters.puzzleDeviation = stored.puzzleRD
        counters.ladderRating = stored.userRating

        for kind in EndgameDrillKind.allCases {
            guard let row = metrics.counter(kind.streakMetricKey.rawValue) else { continue }
            counters.drillStreaks[kind] = MetricValue(value: row.value, sampleCount: row.sampleCount)
        }

        let floor = tuning.curriculum.themeRatingFloor
        for theme in tuning.curriculum.rung2Themes {
            counters.themeAttempts[theme] = metrics.value(TrainingMetricKeys.themeAttempts(theme, ratingFloor: floor))
            counters.themeSolves[theme] = metrics.value(TrainingMetricKeys.themeSolves(theme, ratingFloor: floor))
        }

        counters.cleanRetryAttempts = metrics.value(TrainingMetricKeys.cleanRetryAttempts)
        counters.cleanRetrySuccesses = metrics.value(TrainingMetricKeys.cleanRetrySuccesses)
        return counters
    }

    /// When the user arrived at their current rung.
    ///
    /// Seeded on first read from the oldest game we can see rather than from
    /// "now": a user who has been playing for a month should not have their
    /// fourteen-day clock restarted by an app update.
    private nonisolated static func rungEntryDate(
        metrics: any MetricStore,
        games: [Database.Game],
        now: Date
    ) -> Date {
        if let stored = metrics.counter(Keys.rungEnteredAt) {
            return Date(timeIntervalSince1970: stored.value)
        }
        let seed = games.map(\.startedAt).min() ?? now
        try? metrics.set(Keys.rungEnteredAt, value: seed.timeIntervalSince1970, sampleCount: 1, at: now)
        return seed
    }

    private nonisolated static func persistFocus(
        _ focus: WeeklyFocus,
        previousHabit: Habit?,
        weeksOnFocus: Int,
        trend: FocusMetricTrend,
        goal: MicroGoalState?,
        metrics: any MetricStore,
        settings: any AppSettingsStore,
        tuning: DomainTuning.Focus,
        now: Date
    ) throws {
        try settings.update { $0.weeklyFocusHabit = focus.habit.rawValue }

        // The multiplier is part of the focus in force, not a display value: a
        // forced switch doubles the session's focus share, and a session that
        // reads the focus back from storage has to get the same mix the
        // selector intended rather than a quietly halved one.
        try metrics.set(
            Keys.focusDrillQuotaMultiplier,
            value: focus.drillQuotaMultiplier,
            sampleCount: 1,
            at: now
        )

        if focus.habit != previousHabit {
            // A new habit restarts every counter: the streak, the improvement
            // clock, and the baseline the trend is measured against.
            try metrics.set(Keys.focusWeeksOnHabit, value: 1, sampleCount: 1, at: now)
            try metrics.set(Keys.focusWeekStartedAt, value: now.timeIntervalSince1970, sampleCount: 1, at: now)
            try metrics.set(Keys.focusWeeksWithoutImprovement, value: 0, sampleCount: 1, at: now)
            try metrics.set(Keys.focusConsecutiveGamesMeetingGoal, value: 0, sampleCount: 1, at: now)
            try metrics.set(Keys.focusMicroGoalStartValue, value: goal?.current ?? 0, sampleCount: 1, at: now)
            return
        }

        let weekStartedAt = Date(timeIntervalSince1970: metrics.value(Keys.focusWeekStartedAt, default: now.timeIntervalSince1970))
        guard now.timeIntervalSince(weekStartedAt) >= Double(tuning.comparisonWindowDays) * 86_400 else { return }

        // A week has turned on the same habit: roll the counters once.
        var updatedTrend = trend
        updatedTrend.currentValue = goal?.current ?? trend.currentValue
        let flat = updatedTrend.isFlat(tolerance: tuning.improvementTolerance)

        try metrics.set(Keys.focusWeeksOnHabit, value: Double(weeksOnFocus), sampleCount: 1, at: now)
        try metrics.set(Keys.focusWeekStartedAt, value: now.timeIntervalSince1970, sampleCount: 1, at: now)
        try metrics.set(
            Keys.focusWeeksWithoutImprovement,
            value: flat ? Double(trend.weeksWithoutImprovement + 1) : 0,
            sampleCount: 1,
            at: now
        )
    }
}
