//
//  TodayState.swift
//  ChessCoach
//

import Database
import Foundation

// MARK: - Progress

/// One day's progress through the loop, free of the database row.
///
/// A value type rather than a view of `DailyLoop` so the whole screen's logic
/// can be tested without a database, and so the targets live in exactly one
/// place instead of being re-typed as literals at every comparison.
struct DailyProgress: Equatable, Sendable {

    var gamePlayed: Bool
    var momentsReviewed: Int
    var puzzlesDone: Int

    static let momentsTarget = 3
    static let puzzlesTarget = 10

    static let zero = DailyProgress(gamePlayed: false, momentsReviewed: 0, puzzlesDone: 0)

    init(gamePlayed: Bool = false, momentsReviewed: Int = 0, puzzlesDone: Int = 0) {
        self.gamePlayed = gamePlayed
        self.momentsReviewed = momentsReviewed
        self.puzzlesDone = puzzlesDone
    }

    init(_ loop: DailyLoop) {
        self.init(
            gamePlayed: loop.gamePlayed,
            momentsReviewed: loop.momentsReviewed,
            puzzlesDone: loop.puzzlesDone
        )
    }

    /// Nothing has happened today.
    ///
    /// Note this is *not* the same as "no row": `DailyLoopRepository.loop(for:)`
    /// creates a row on read, so merely opening the app writes an all-zero day.
    /// Any predicate keyed on row existence would report a streak for a user who
    /// only ever launched the app.
    var isUntouched: Bool {
        !gamePlayed && momentsReviewed == 0 && puzzlesDone == 0
    }

    func isDone(_ step: TodayStep) -> Bool {
        switch step {
        case .game: gamePlayed
        case .moments: momentsReviewed >= Self.momentsTarget
        case .puzzles: puzzlesDone >= Self.puzzlesTarget
        }
    }

    func completed(_ step: TodayStep) -> Int {
        switch step {
        case .game: gamePlayed ? 1 : 0
        case .moments: min(momentsReviewed, Self.momentsTarget)
        case .puzzles: min(puzzlesDone, Self.puzzlesTarget)
        }
    }

    func remaining(_ step: TodayStep) -> Int {
        max(step.target - completed(step), 0)
    }

    var completedStepCount: Int {
        TodayStep.allCases.filter { isDone($0) }.count
    }

    var isComplete: Bool { completedStepCount == TodayStep.allCases.count }
}

// MARK: - Steps

/// The three steps of the daily loop, in the order they are meant to happen.
enum TodayStep: Int, CaseIterable, Identifiable, Sendable {
    case game = 1
    case moments
    case puzzles

    var id: Int { rawValue }

    var target: Int {
        switch self {
        case .game: 1
        case .moments: DailyProgress.momentsTarget
        case .puzzles: DailyProgress.puzzlesTarget
        }
    }

    /// The row label. Deliberately a noun phrase, not an imperative — the rows
    /// are status, and only the CTA gives an order.
    var title: String {
        switch self {
        case .game: "1 game"
        case .moments: "3 moments"
        case .puzzles: "10 puzzles"
        }
    }

    /// Whole-step cost in minutes, used to state the price on the CTA.
    ///
    /// These are the numbers the app is promising, so they are conservative:
    /// a step that reliably overruns its estimate is worse than one that never
    /// gave an estimate at all.
    var estimatedMinutes: Int {
        switch self {
        case .game: 10
        case .moments: 5
        case .puzzles: 4
        }
    }

    /// The step this one cannot start without.
    ///
    /// Only `moments` has a real dependency: three moments are pulled from a
    /// game's analysis, so with no game there is nothing to review. Puzzles are
    /// genuinely independent — pretending otherwise to make a tidier ladder
    /// would be a lie the user can catch in one tap.
    var requires: TodayStep? {
        switch self {
        case .game: nil
        case .moments: .game
        case .puzzles: nil
        }
    }

    /// Shown on a locked row instead of a tally. Names the blocker, so the row
    /// explains itself rather than just looking broken.
    var lockedReason: String? {
        switch self {
        case .moments: "after your game"
        default: nil
        }
    }

    var destination: TodayDestination {
        switch self {
        case .game: .play
        case .moments: .reviewLatestGame
        case .puzzles: .train
        }
    }
}

/// Where the Today screen can send you. Resolved to an `AppModel.Route` by the
/// view, which is the only layer that knows which game is the latest one.
enum TodayDestination: Equatable, Sendable {
    case play
    case reviewLatestGame
    case train
    case weekSummary
}

/// How a step row presents.
enum StepStatus: Equatable, Sendable {
    /// Finished today.
    case done
    /// The step the CTA points at.
    case current
    /// Startable right now, but not what the CTA names.
    case available
    /// Blocked by a dependency. Dimmed, with the reason.
    case locked

    var isDimmed: Bool { self == .locked }
}

struct StepRowState: Equatable, Identifiable, Sendable {
    let step: TodayStep
    let status: StepStatus
    /// `2` `of 3`. Nil on a locked row, which shows its reason instead — a
    /// `0/3` on a step you cannot start is a score you were never able to move.
    let tally: Denominator?
    let lockedReason: String?

    var id: Int { step.rawValue }
}

// MARK: - Streak strip

/// One slot in the seven-day strip.
///
/// `missed` is drawn as a plain grey circle. There is no `failed` case and
/// there will not be one: a red X on a missed day is a punishment for a person
/// who has just returned, which is the exact moment the app can least afford it.
enum DayMarker: Equatable, Sendable {
    /// Loop completed.
    case done
    /// A day that passed without the loop being completed. Plain grey.
    case missed
    /// Today, still open.
    case today
    /// Tomorrow — a **dashed** outline. "Not yet" must be visually distinct
    /// from "missed", or the strip reads as a row of failures every Monday.
    case tomorrow
    /// Later this week, or — before the user has any history — every slot,
    /// because you cannot miss a day you had no chance to play.
    case upcoming
}

struct DaySlot: Equatable, Identifiable, Sendable {
    let dayKey: String
    let initial: String
    let marker: DayMarker

    var id: String { dayKey }
}

// MARK: - CTA

/// How loudly an action is presented.
enum ActionEmphasis: Equatable, Sendable {
    /// The one filled accent button. At most one per screen.
    case primary
    /// Bordered. Optional work.
    case secondary
    /// Plain text. "Or do this instead."
    case tertiary
}

struct TodayAction: Equatable, Sendable {
    /// Names the step **and its cost**. Never `Continue` — a generic verb makes
    /// the user tap to find out what they agreed to.
    let title: String
    /// An optional second line, e.g. flagging a shorter alternative.
    let subtitle: String?
    let destination: TodayDestination
    let emphasis: ActionEmphasis
    /// The step this action advances, if any. Nil for "see your week".
    let step: TodayStep?

    init(
        title: String,
        subtitle: String? = nil,
        destination: TodayDestination,
        emphasis: ActionEmphasis,
        step: TodayStep? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
        self.emphasis = emphasis
        self.step = step
    }
}

// MARK: - Phase

/// Which of the four honest states the screen is in.
enum TodayPhase: Equatable, Sendable {
    /// No history at all. The real screen, zeroed — not a marketing pitch.
    case firstRun
    /// Some steps done, some not.
    case inProgress
    /// All three done today.
    case complete
    /// A gap in the record, and today not yet started.
    case streakRestarted
}

// MARK: - Rung

/// The rung card's content. `progress` is optional on purpose.
struct RungPresentation: Equatable, Sendable {
    let rung: Int
    let title: String
    /// Required-skill progress, 0...1. **Nil means not yet measured**, and the
    /// card says so rather than drawing an empty bar. A 0% bar is a claim that
    /// the user has made no progress; "unmeasured" is the truth.
    let progress: Double?
    let focusHabit: String?
    /// Shown in place of the bar when `progress` is nil.
    let unmeasuredNote: String

    static let firstRunNote = "We'll set your rung after your first game"
    static let measuringNote = "Measuring — a few more games"
}

// MARK: - The plan

/// Everything the Today screen renders, computed from data and nothing else.
struct TodayPlan: Equatable, Sendable {

    let phase: TodayPhase
    let steps: [StepRowState]
    /// `TODAY` / `1 OF 3`. The tally lives on the section header, never inside
    /// the button: a button that carries a count is promising a count, and it
    /// can only deliver one step.
    let headerQualifier: Denominator
    let primary: TodayAction
    /// A shorter, independent step offered alongside the primary — the "when
    /// steps are independent, pick the shortest and say so" case.
    let alternative: TodayAction?
    /// Present-tense greeting, shown before anything about the streak.
    let greeting: String?
    /// One sentence about the streak, without a number.
    let streakNote: String?
    /// Identity framing on the completed state. Not praise: praise expires, and
    /// heat metaphors escalate with nowhere to go on day 40.
    let completionNote: String?

    var currentStep: TodayStep? {
        steps.first { $0.status == .current }?.step
    }
}

// MARK: - Composition

/// The pure logic behind the Today screen.
///
/// Everything here is a static function over values, so all four states — plus
/// every dependency and marker rule — are testable without a database, a
/// simulator, or a rendered view.
enum TodayPlanner {

    // MARK: Phase selection

    static func phase(
        today: DailyProgress,
        hasHistory: Bool,
        streakBroken: Bool
    ) -> TodayPhase {
        // Completion wins outright: a user who finished on their very first day
        // should see the finished screen, not an onboarding one.
        if today.isComplete { return .complete }
        if !hasHistory { return .firstRun }
        // The restart message is for someone who has just come back. Once
        // they have done anything today, it has served its purpose and the
        // screen returns to normal — repeating it all day would be nagging.
        if streakBroken && today.isUntouched { return .streakRestarted }
        return .inProgress
    }

    // MARK: Steps

    static func steps(for progress: DailyProgress, phase: TodayPhase) -> [StepRowState] {
        let currentStep = nextStep(for: progress, phase: phase)

        return TodayStep.allCases.map { step in
            let status: StepStatus
            if progress.isDone(step) {
                status = .done
            } else if let required = step.requires, !progress.isDone(required) {
                status = .locked
            } else if step == currentStep {
                status = .current
            } else {
                status = .available
            }

            return StepRowState(
                step: step,
                status: status,
                tally: status == .locked
                    ? nil
                    : .of(progress.completed(step), step.target),
                lockedReason: status == .locked ? step.lockedReason : nil
            )
        }
    }

    /// The step the CTA points at: the first incomplete step, in loop order,
    /// whose dependency is satisfied.
    ///
    /// Loop order beats "shortest first" here, and deliberately. Puzzles are
    /// cheaper than a game, so a pure cost sort would open every single day
    /// with "10 puzzles" and the user would never play — the game is what
    /// produces the moments, the analysis, and the rung measurement. The
    /// shortest option is surfaced instead as ``TodayPlan/alternative``, which
    /// offers it without hijacking the loop.
    static func nextStep(for progress: DailyProgress, phase: TodayPhase) -> TodayStep? {
        guard phase != .complete else { return nil }
        return TodayStep.allCases.first { step in
            guard !progress.isDone(step) else { return false }
            guard let required = step.requires else { return true }
            return progress.isDone(required)
        }
    }

    /// Incomplete steps that could be started right now.
    static func unblockedSteps(for progress: DailyProgress) -> [TodayStep] {
        TodayStep.allCases.filter { step in
            guard !progress.isDone(step) else { return false }
            guard let required = step.requires else { return true }
            return progress.isDone(required)
        }
    }

    // MARK: Copy

    /// `Play 1 game · ~10 min`.
    ///
    /// Both halves are load-bearing. The verb and object say what happens; the
    /// duration is the price. A `Continue` gives neither, so the user has to
    /// spend the tap to find out — and after they have been surprised once,
    /// they stop tapping it when they are short on time.
    static func actionTitle(for step: TodayStep, progress: DailyProgress, firstRun: Bool) -> String {
        let remaining = progress.remaining(step)
        let minutes = estimatedMinutes(for: step, remaining: remaining)

        let phrase: String
        switch step {
        case .game:
            phrase = firstRun ? "Play your first game" : "Play 1 game"
        case .moments:
            phrase = "Review \(remaining) moment\(remaining == 1 ? "" : "s")"
        case .puzzles:
            phrase = "\(remaining) puzzle\(remaining == 1 ? "" : "s")"
        }
        return "\(phrase) · ~\(minutes) min"
    }

    /// Cost scaled to what is actually left, never to the whole step.
    ///
    /// Telling someone with 8 of 10 puzzles done that it will take 4 minutes is
    /// a small lie, and small lies about time are how a daily habit loses trust.
    static func estimatedMinutes(for step: TodayStep, remaining: Int) -> Int {
        guard step.target > 0, remaining > 0 else { return step.estimatedMinutes }
        let fraction = Double(remaining) / Double(step.target)
        return max(1, Int((Double(step.estimatedMinutes) * fraction).rounded(.up)))
    }

    // MARK: Actions

    static func actions(
        phase: TodayPhase,
        progress: DailyProgress
    ) -> (primary: TodayAction, alternative: TodayAction?) {

        if phase == .complete {
            // The CTA stops being filled. A filled accent button pointing at
            // optional extra work teaches the user that "the big button" does
            // not mean "the thing you came for", and once that is learned it is
            // learned everywhere in the app.
            return (
                TodayAction(
                    title: "Play a free game",
                    subtitle: nil,
                    destination: .play,
                    emphasis: .secondary,
                    step: nil
                ),
                TodayAction(
                    title: "See your week",
                    destination: .weekSummary,
                    emphasis: .tertiary
                )
            )
        }

        guard let next = nextStep(for: progress, phase: phase) else {
            return (
                TodayAction(title: "Play a free game", destination: .play, emphasis: .secondary),
                nil
            )
        }

        let primary = TodayAction(
            title: actionTitle(for: next, progress: progress, firstRun: phase == .firstRun),
            subtitle: nil,
            destination: next.destination,
            emphasis: .primary,
            step: next
        )

        // The shortest *other* unblocked step, offered plainly. This is the
        // honest version of "pick the shortest": it is stated as an option
        // rather than substituted for the loop.
        let shortest = unblockedSteps(for: progress)
            .filter { $0 != next }
            .min { lhs, rhs in
                estimatedMinutes(for: lhs, remaining: progress.remaining(lhs))
                    < estimatedMinutes(for: rhs, remaining: progress.remaining(rhs))
            }

        let alternative = shortest.map { step in
            TodayAction(
                title: "Short on time? " + actionTitle(for: step, progress: progress, firstRun: false),
                destination: step.destination,
                emphasis: .tertiary,
                step: step
            )
        }

        return (primary, alternative)
    }

    // MARK: Plan

    static func plan(
        progress: DailyProgress,
        hasHistory: Bool,
        streakBroken: Bool
    ) -> TodayPlan {
        let phase = phase(today: progress, hasHistory: hasHistory, streakBroken: streakBroken)
        let actions = actions(phase: phase, progress: progress)

        return TodayPlan(
            phase: phase,
            steps: steps(for: progress, phase: phase),
            headerQualifier: .of(progress.completedStepCount, TodayStep.allCases.count),
            primary: actions.primary,
            alternative: actions.alternative,
            greeting: greeting(for: phase),
            streakNote: streakNote(for: phase),
            completionNote: phase == .complete ? completionNote : nil
        )
    }

    /// Lead with the present, always — and especially on a return.
    ///
    /// "Good to see you." arrives before any mention of the streak, because the
    /// first thing a returning user should read is that they are welcome, not
    /// an accounting of their absence.
    static func greeting(for phase: TodayPhase) -> String? {
        phase == .streakRestarted ? "Good to see you." : nil
    }

    /// Said once, plainly, without a number.
    ///
    /// "Your streak restarted." states a fact about the present. "You lost your
    /// 12-day streak" states a quantity of loss, and the number's only function
    /// is to make it hurt more — which does not bring anybody back tomorrow.
    static func streakNote(for phase: TodayPhase) -> String? {
        phase == .streakRestarted ? "Your streak restarted." : nil
    }

    /// Identity, not praise.
    ///
    /// "You're on fire!" is a claim about a mood that expires by morning, and
    /// heat metaphors escalate — there is nowhere to go on day 40 that is not
    /// either louder or a let-down. A vote toward the player you are becoming
    /// stays exactly as true on day 400 as on day 4.
    static let completionNote = "One more vote toward the player you're becoming."

    static let completionHeadline = "Done for today."
}

// MARK: - Streak arithmetic

/// Streak and week-strip computation over `DailyLoop` rows.
///
/// Kept apart from ``TodayPlanner`` because it is date arithmetic, which wants
/// an injected calendar and an injected "today" in every single test.
enum StreakCalculator {

    /// A day counts only when the whole loop was completed.
    ///
    /// `completedAt` is never written by any code path today, so keying off it
    /// would report a permanent zero streak. The derived predicate is the
    /// truthful one; `completedAt` is still honoured if a future writer sets it.
    static func isComplete(_ loop: DailyLoop) -> Bool {
        loop.completedAt != nil || DailyProgress(loop).isComplete
    }

    /// The set of day keys whose loop was completed.
    static func completedDays(_ loops: [DailyLoop]) -> Set<String> {
        Set(loops.filter(isComplete).map(\.day))
    }

    /// Consecutive completed days ending today or yesterday.
    ///
    /// Today not being finished *yet* does not break a streak — it is still
    /// today. Counting from yesterday in that case is what stops the number
    /// flickering to zero every midnight.
    static func currentStreak(
        completedDays: Set<String>,
        today: Date,
        calendar: Calendar = .current
    ) -> Int {
        var cursor = today
        // If today is not done, the streak is measured to yesterday instead.
        if !completedDays.contains(DailyLoop.dayKey(for: today, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return 0
            }
            cursor = yesterday
        }

        var count = 0
        while completedDays.contains(DailyLoop.dayKey(for: cursor, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// True when the user has completed days in the past, but the run ended
    /// before yesterday.
    ///
    /// Yesterday is the boundary rather than today because a streak is not
    /// broken by a day that has not finished happening.
    static func isStreakBroken(
        completedDays: Set<String>,
        today: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard !completedDays.isEmpty else { return false }
        let todayKey = DailyLoop.dayKey(for: today, calendar: calendar)
        guard !completedDays.contains(todayKey) else { return false }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
        return !completedDays.contains(DailyLoop.dayKey(for: yesterday, calendar: calendar))
    }

    /// Whether the user has ever done anything.
    ///
    /// Any progress on any day counts, not just completed loops — someone who
    /// played a game yesterday and stopped is not a first-run user, and showing
    /// them "We'll set your rung after your first game" would be wrong.
    static func hasHistory(_ loops: [DailyLoop], todayKey: String) -> Bool {
        loops.contains { loop in
            loop.day != todayKey && !DailyProgress(loop).isUntouched
        }
    }

    /// The seven slots of the current week.
    ///
    /// - Parameter hasHistory: when false, past days come back as `.upcoming`
    ///   rather than `.missed`. You cannot miss a day you had no chance to play,
    ///   and opening a brand-new app to a row of misses is a strange first
    ///   impression to engineer on purpose.
    static func weekSlots(
        completedDays: Set<String>,
        today: Date,
        calendar: Calendar = .current,
        hasHistory: Bool
    ) -> [DaySlot] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { return [] }
        let todayKey = DailyLoop.dayKey(for: today, calendar: calendar)
        let symbols = weekdayInitials(calendar: calendar)

        return (0..<7).compactMap { offset -> DaySlot? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start) else {
                return nil
            }
            let key = DailyLoop.dayKey(for: date, calendar: calendar)
            let dayDelta = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: today),
                to: calendar.startOfDay(for: date)
            ).day ?? 0

            let marker: DayMarker
            if completedDays.contains(key) {
                marker = .done
            } else if key == todayKey {
                marker = .today
            } else if dayDelta == 1 {
                marker = .tomorrow
            } else if dayDelta > 1 {
                marker = .upcoming
            } else {
                marker = hasHistory ? .missed : .upcoming
            }

            return DaySlot(dayKey: key, initial: symbols[offset], marker: marker)
        }
    }

    /// Single-letter weekday labels, rotated to the calendar's first weekday so
    /// the strip matches the user's own week rather than a hardcoded Sunday.
    static func weekdayInitials(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7] }
    }
}
