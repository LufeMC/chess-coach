//
//  MetricsService.swift
//  ChessCoach
//

import Database
import Foundation
import Observation
import TrainingCore

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
    }

    // MARK: Dependencies

    private nonisolated let games: any GameStore
    private nonisolated let moments: any MomentStore
    private nonisolated let metrics: any MetricStore
    private nonisolated let settings: any AppSettingsStore
    private nonisolated let guided: any GuidedPromptLog
    private nonisolated let tuning: DomainTuning
    private nonisolated let ladder: [Rung]
    private nonisolated let calendar: Calendar
    private nonisolated let clock: @Sendable () -> Date

    init(
        games: any GameStore,
        moments: any MomentStore,
        metrics: any MetricStore,
        settings: any AppSettingsStore,
        guided: any GuidedPromptLog = EmptyGuidedPromptLog(),
        tuning: DomainTuning = .default,
        ladder: [Rung] = Curriculum.default,
        calendar: Calendar = Calendar(identifier: .gregorian),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.games = games
        self.moments = moments
        self.metrics = metrics
        self.settings = settings
        self.guided = guided
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
    /// accepted.
    func setFocus(habit: Habit) async {
        let now = clock()
        _ = try? settings.update { $0.weeklyFocusHabit = habit.rawValue }
        try? metrics.set(Keys.focusWeeksOnHabit, value: 1, sampleCount: 1, at: now)
        try? metrics.set(Keys.focusWeekStartedAt, value: now.timeIntervalSince1970, sampleCount: 1, at: now)
        await refresh()
    }
}

// MARK: - Computation

extension MetricsService {

    private nonisolated static func recompute(
        games: any GameStore,
        moments: any MomentStore,
        metrics: any MetricStore,
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
        let horizon = maximumWindowGames(in: ladder)
        let recent = try games.recent(limit: horizon)

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
            consecutiveGamesMeetingMicroGoal: Int(metrics.value(Keys.focusConsecutiveGamesMeetingGoal)),
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
