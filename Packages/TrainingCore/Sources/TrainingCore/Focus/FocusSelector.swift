//
//  FocusSelector.swift
//  TrainingCore
//

import Foundation

/// Why the focus is what it is. Surfaced to the user, because a focus that
/// changes for no visible reason reads as the app being arbitrary.
public enum FocusChangeReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// No previous focus.
    case initialSelection
    /// Kept — it is not a rotation point.
    case unchanged
    /// The regular Monday rotation.
    case scheduledRotation
    /// The micro-goal cleared for enough consecutive games to rotate early.
    case earlyRotationGoalCleared
    /// The habit hit the consecutive-week cap.
    case maximumWeeksReached
    /// Three weeks with no movement; switched and drill quota doubled.
    case forcedSwitchNoImprovement
}

/// The week's focus.
public struct WeeklyFocus: Sendable, Hashable, Codable {

    public var habit: Habit

    /// The largest cause tag feeding this habit, for the "because you keep..."
    /// line in the UI.
    public var primaryCauseTag: CauseTag?

    /// Expected-points-per-game the habit is currently costing.
    public var epLostPerGame: Double

    /// Multiplier on this habit's puzzle drill quota. 1 normally, doubled by a
    /// forced switch.
    public var drillQuotaMultiplier: Double

    public var reason: FocusChangeReason

    public init(
        habit: Habit,
        primaryCauseTag: CauseTag? = nil,
        epLostPerGame: Double = 0,
        drillQuotaMultiplier: Double = 1,
        reason: FocusChangeReason = .initialSelection
    ) {
        self.habit = habit
        self.primaryCauseTag = primaryCauseTag
        self.epLostPerGame = epLostPerGame
        self.drillQuotaMultiplier = drillQuotaMultiplier
        self.reason = reason
    }

    public var microGoalTitle: String { habit.microGoalTitle }
}

/// How the current focus's micro-goal metric is moving.
///
/// The caller owns this state because it spans weeks and this package holds
/// none. The intended update loop, once a week:
///
/// ```swift
/// var trend = stored
/// trend.currentValue = latestMetric
/// trend.weeksWithoutImprovement = trend.isFlat(tolerance: tuning.improvementTolerance)
///     ? trend.weeksWithoutImprovement + 1
///     : 0
/// ```
public struct FocusMetricTrend: Sendable, Hashable, Codable {

    /// Consecutive weeks the metric stayed within
    /// ``DomainTuning/Focus/improvementTolerance`` of where it started.
    public var weeksWithoutImprovement: Int

    /// Consecutive recent games meeting the micro-goal.
    public var consecutiveGamesMeetingMicroGoal: Int

    /// The metric when this focus began.
    public var startValue: Double

    /// The metric now.
    public var currentValue: Double

    public init(
        weeksWithoutImprovement: Int = 0,
        consecutiveGamesMeetingMicroGoal: Int = 0,
        startValue: Double = 0,
        currentValue: Double = 0
    ) {
        self.weeksWithoutImprovement = weeksWithoutImprovement
        self.consecutiveGamesMeetingMicroGoal = consecutiveGamesMeetingMicroGoal
        self.startValue = startValue
        self.currentValue = currentValue
    }

    /// Whether the metric has failed to move meaningfully.
    ///
    /// Relative rather than absolute, so the same rule works for a rate of 4.0
    /// mistakes per 100 moves and a hit rate of 0.55. A start value of zero is
    /// treated as flat only if the current value is also zero — there is no
    /// percentage of nothing.
    public func isFlat(tolerance: Double) -> Bool {
        guard startValue != 0 else { return currentValue == 0 }
        return abs(currentValue - startValue) <= tolerance * abs(startValue)
    }
}

/// The 60/40 split of a session's puzzles.
public struct DrillMix: Sendable, Hashable {
    /// Puzzles drawn from the focus habit's themes.
    public var focusThemed: Int
    /// Due SRS cards and general puzzles.
    public var dueOrGeneral: Int

    public init(focusThemed: Int, dueOrGeneral: Int) {
        self.focusThemed = focusThemed
        self.dueOrGeneral = dueOrGeneral
    }

    public var total: Int { focusThemed + dueOrGeneral }
}

/// Picks the week's habit.
public enum FocusSelector {

    /// A habit and the leak weight behind it.
    struct Candidate {
        var habit: Habit
        var weight: Double
        var primaryCauseTag: CauseTag?
        var epLostPerGame: Double
        var drillability: Double
    }

    /// Selects the focus for the coming period.
    ///
    /// - Parameters:
    ///   - leaks: The leak table from ``LeakAnalyzer``, sorted descending.
    ///   - rung: The user's curriculum rung. Candidates are restricted to
    ///     habits the rung actually measures — coaching a habit the ladder is
    ///     not tracking means the user works for a week and sees no progress
    ///     anywhere in the app.
    ///   - currentFocus: The focus in force, or `nil` on first run.
    ///   - weeksOnFocus: Consecutive weeks ``currentFocus`` has been held.
    ///   - metricTrend: How the current focus's metric is moving.
    ///   - now: Used only to detect the rotation weekday.
    ///
    /// ## Selection
    ///
    /// Leaks are grouped by the habit that fixes them and the group weights are
    /// **summed**, then the heaviest group wins. Summing rather than taking the
    /// single largest leak because the habit is the unit of action: a user
    /// leaking a little to each of three causes that all resolve to
    /// "blunder-check every move" has a blunder-check problem, and telling them
    /// otherwise because no individual tag topped the chart would be wrong.
    /// Ties break on drillability — a habit we cannot practise deliberately
    /// makes a poor week's work no matter what it is costing.
    ///
    /// ## Rotation and anti-thrash
    ///
    /// Rotation is Monday-shaped so the user has a whole week's rhythm, with
    /// three overrides, checked in this order:
    ///
    /// 1. **Three non-improving weeks → forced switch, doubled drill quota.**
    ///    Three weeks of a habit that has not moved is three weeks the user
    ///    spent on advice that is not working for them. Switching to the #2
    ///    leak with double the drills is the recovery.
    /// 2. **Three consecutive weeks on one habit → switch.** The cap exists
    ///    because the largest leak is usually also the most stubborn, and
    ///    without a ceiling it would hold the slot indefinitely while the user
    ///    watched the same chip for a month.
    /// 3. **Micro-goal clear for 5 consecutive games → rotate early.** Sitting
    ///    on a solved habit is wasted weeks.
    ///
    /// Between rotation points the focus is left alone. That is the actual
    /// anti-thrash mechanism: without it, one bad game would reshuffle the leak
    /// chart and hand the user a different homework assignment on Wednesday,
    /// and a habit that changes twice a week is not a habit.
    public static func selectFocus(
        leaks: [Leak],
        rung: Int,
        currentFocus: WeeklyFocus?,
        weeksOnFocus: Int,
        metricTrend: FocusMetricTrend,
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        ladder: [Rung] = Curriculum.default,
        tuning: DomainTuning.Focus = DomainTuning.default.focus
    ) -> WeeklyFocus {

        let candidates = rankedCandidates(leaks: leaks, rung: rung, ladder: ladder, tuning: tuning)

        guard let best = candidates.first else {
            // Nothing to coach: no leaks, or none that map anywhere. Keep what
            // we have rather than inventing a focus out of nothing.
            return currentFocus ?? WeeklyFocus(habit: .blunderCheck, reason: .initialSelection)
        }

        guard let current = currentFocus else {
            return focus(from: best, reason: .initialSelection, multiplier: 1)
        }

        func alternative() -> Candidate {
            candidates.first { $0.habit != current.habit } ?? best
        }

        if metricTrend.weeksWithoutImprovement >= tuning.nonImprovingWeeksBeforeSwitch {
            return focus(
                from: alternative(),
                reason: .forcedSwitchNoImprovement,
                multiplier: tuning.forcedSwitchDrillMultiplier
            )
        }

        if weeksOnFocus >= tuning.maximumConsecutiveWeeks {
            return focus(from: alternative(), reason: .maximumWeeksReached, multiplier: 1)
        }

        if metricTrend.consecutiveGamesMeetingMicroGoal >= tuning.earlyRotationConsecutiveGames {
            return focus(from: alternative(), reason: .earlyRotationGoalCleared, multiplier: 1)
        }

        if calendar.component(.weekday, from: now) == tuning.rotationWeekday {
            return focus(
                from: best,
                reason: best.habit == current.habit ? .unchanged : .scheduledRotation,
                multiplier: 1
            )
        }

        var unchanged = current
        unchanged.reason = .unchanged
        return unchanged
    }

    /// Groups leaks by habit and ranks them.
    static func rankedCandidates(
        leaks: [Leak],
        rung: Int,
        ladder: [Rung],
        tuning: DomainTuning.Focus
    ) -> [Candidate] {
        let rungHabits = ladder.first { $0.id == rung }?.habits ?? []

        func group(restrictToRung: Bool) -> [Candidate] {
            var byHabit: [Habit: Candidate] = [:]
            for leak in leaks {
                guard let habit = leak.habit ?? leak.causeTag.habit(rung: rung) else { continue }
                if restrictToRung && !rungHabits.contains(habit) { continue }

                if var existing = byHabit[habit] {
                    existing.weight += leak.weightedEPLost
                    existing.epLostPerGame += leak.epLostPerGame
                    // The primary tag is the largest contributor. `leaks` is
                    // already sorted, so the first one seen wins.
                    byHabit[habit] = existing
                } else {
                    byHabit[habit] = Candidate(
                        habit: habit,
                        weight: leak.weightedEPLost,
                        primaryCauseTag: leak.causeTag,
                        epLostPerGame: leak.epLostPerGame,
                        drillability: tuning.habitDrillability[habit] ?? 0.5
                    )
                }
            }
            return byHabit.values.sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                if lhs.drillability != rhs.drillability { return lhs.drillability > rhs.drillability }
                return lhs.habit.rawValue < rhs.habit.rawValue
            }
        }

        let onRung = group(restrictToRung: true)
        // Fall back to unrestricted ranking rather than returning nothing: a
        // user whose leaks all sit outside their rung's skills still deserves a
        // focus, and "no focus" is a worse answer than "a focus the ladder does
        // not happen to measure".
        let ranked = onRung.isEmpty ? group(restrictToRung: false) : onRung
        return ranked + unaskedRungHabits(rung: rung, ranked: ranked, ladder: ladder, tuning: tuning)
    }

    /// The rung's own habits that no leak can ever nominate, ranked last.
    ///
    /// `CauseTag.habit(rung:)` maps the detectors' sixteen tags onto six habits.
    /// Three habits have no tag at all — `convertCleanly`, `clockDiscipline` and
    /// `kingSafety` — because no detector emits a "you failed to convert" or a
    /// "you used your clock badly" cause. Every candidate here is built *from a
    /// leak*, so those three could never appear, and a rung whose required skill
    /// names one of them had no way to make it the week's focus. `r4.conversion`
    /// is exactly that: required, `habit: .convertCleanly`, and unreachable.
    ///
    /// The honest fix upstream is cause tags the detectors can emit, which is
    /// detector work and a change to what gets persisted. This is the cheap half
    /// that removes the dead end today: seed the missing habits at zero weight
    /// so they sit *below* every measured leak and are chosen only when nothing
    /// real outranks them — which is precisely the situation the dead end
    /// described, a user with no leaks pointing at a skill the ladder demands.
    private static func unaskedRungHabits(
        rung: Int,
        ranked: [Candidate],
        ladder: [Rung],
        tuning: DomainTuning.Focus
    ) -> [Candidate] {
        let rungHabits = ladder.first { $0.id == rung }?.habits ?? []
        let already = Set(ranked.map(\.habit))
        return rungHabits
            .filter { !already.contains($0) && !Habit.hasCauseTag($0) }
            .map {
                Candidate(
                    habit: $0,
                    weight: 0,
                    primaryCauseTag: nil,
                    epLostPerGame: 0,
                    drillability: tuning.habitDrillability[$0] ?? 0.5
                )
            }
            .sorted { $0.drillability > $1.drillability }
    }

    private static func focus(
        from candidate: Candidate,
        reason: FocusChangeReason,
        multiplier: Double
    ) -> WeeklyFocus {
        WeeklyFocus(
            habit: candidate.habit,
            primaryCauseTag: candidate.primaryCauseTag,
            epLostPerGame: candidate.epLostPerGame,
            drillQuotaMultiplier: multiplier,
            reason: reason
        )
    }

    /// Splits a session's puzzle budget between focus themes and everything
    /// else.
    ///
    /// 60/40. Enough repetition on one habit's themes for a week of work to
    /// actually move it, and enough left over that the SRS deck keeps draining
    /// and the user does not spend seven days looking at back-rank mates. A
    /// forced switch raises the focus share but never past
    /// ``DomainTuning/Focus/maximumFocusShare`` for the same reason.
    public static func drillMix(
        totalPuzzles: Int,
        focus: WeeklyFocus?,
        tuning: DomainTuning.Focus = DomainTuning.default.focus
    ) -> DrillMix {
        guard totalPuzzles > 0 else { return DrillMix(focusThemed: 0, dueOrGeneral: 0) }
        guard let focus else { return DrillMix(focusThemed: 0, dueOrGeneral: totalPuzzles) }

        let share = min(tuning.focusThemeShare * focus.drillQuotaMultiplier, tuning.maximumFocusShare)
        let themed = min(totalPuzzles, max(0, Int((Double(totalPuzzles) * share).rounded())))
        return DrillMix(focusThemed: themed, dueOrGeneral: totalPuzzles - themed)
    }
}
