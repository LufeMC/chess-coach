//
//  TodayState.swift
//  ChessCoach
//

import Database
import Foundation
import TrainingCore

// MARK: - Progress

/// What the latest game left behind to review.
///
/// The moments step is the one step whose work the user does not create by
/// showing up: a game is always playable and puzzles always exist, but moments
/// are a *residue* of a game going wrong. A clean game, or a two-move
/// resignation, leaves none; the pass that finds them takes seconds and can
/// fail outright. Each of those is a different sentence on the screen, so each
/// is a case here rather than one number asked to stand for all of them.
enum MomentsQueue: Equatable, Sendable {

    /// Nothing counted, and nothing claimed. The nominal target stands. This is
    /// the state every caller outside Today works in — the game summary prices
    /// the same step from its own count and has no business with the day's.
    case unknown

    /// A game is waiting on its post-game pass. There is no count yet and the
    /// step must not invent one: the review it would open has nothing in it.
    case analysing

    /// The pass could not finish, so there is no queue and no way to make one
    /// without a re-run. Said plainly rather than parking the whole day on work
    /// the app is not able to supply.
    case unavailable

    /// The pass finished: `total` moments worth reviewing, `reviewed` of them
    /// already worked through.
    ///
    /// Both halves come from one read of one game's rows. Sizing the step from
    /// "moments still unread" instead — the number the queue query answers most
    /// cheaply — makes the target shrink as the user works through it, and a
    /// target that shrinks ticks the step done after two of three.
    case counted(total: Int, reviewed: Int)
}

/// One day's progress through the loop, free of the database row.
///
/// A value type rather than a view of `DailyLoop` so the whole screen's logic
/// can be tested without a database, and so the targets live in exactly one
/// place instead of being re-typed as literals at every comparison.
struct DailyProgress: Equatable, Sendable {

    var gamePlayed: Bool

    /// Moments worked through **today**, across every game — the day's own
    /// counter, straight off the loop row.
    ///
    /// Not the same number as ``MomentsQueue/counted``'s `reviewed`, which is
    /// per game. This one resets at midnight, and it is what says whether the
    /// user has touched the review step today at all.
    var momentsReviewed: Int

    var puzzlesDone: Int

    /// The latest game's review queue. See ``MomentsQueue``.
    var moments: MomentsQueue

    /// How many puzzles today's set is.
    ///
    /// Read from the length the user chose on Train rather than fixed at ten,
    /// because two screens negotiating one decision is how "10 puzzles" here
    /// becomes "5 puzzles." on the screen it opens.
    var puzzleTarget: Int

    /// The nominal target — what a normal game is expected to yield, and the
    /// ceiling on a day's review work regardless of how badly a game went.
    static let momentsTarget = 3
    /// The default set length, standing in until the user's own choice is read.
    static let puzzlesTarget = 10

    static let zero = DailyProgress(gamePlayed: false, momentsReviewed: 0, puzzlesDone: 0)

    init(
        gamePlayed: Bool = false,
        momentsReviewed: Int = 0,
        puzzlesDone: Int = 0,
        moments: MomentsQueue = .unknown,
        puzzleTarget: Int = DailyProgress.puzzlesTarget
    ) {
        self.gamePlayed = gamePlayed
        self.momentsReviewed = momentsReviewed
        self.puzzlesDone = puzzlesDone
        self.moments = moments
        self.puzzleTarget = puzzleTarget
    }

    init(
        _ loop: DailyLoop,
        moments: MomentsQueue = .unknown,
        puzzleTarget: Int = DailyProgress.puzzlesTarget
    ) {
        self.init(
            gamePlayed: loop.gamePlayed,
            momentsReviewed: loop.momentsReviewed,
            puzzlesDone: loop.puzzlesDone,
            moments: moments,
            puzzleTarget: puzzleTarget
        )
    }

    /// The moments target this particular day can honour.
    var momentsTarget: Int {
        switch moments {
        case .unknown, .analysing:
            Self.momentsTarget
        case .unavailable:
            0
        case let .counted(total, reviewed):
            // Never below what has already been worked through: a user who
            // emptied a two-moment queue has *finished* the step, and must not
            // be shown a `2 of 0` for it.
            max(reviewed, min(Self.momentsTarget, total))
        }
    }

    /// The target for a step on this day. `game` is the only fixed one.
    func target(_ step: TodayStep) -> Int {
        switch step {
        case .moments: momentsTarget
        case .puzzles: puzzleTarget
        case .game: step.target
        }
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

    /// Blocked by a dependency that today has not satisfied.
    ///
    /// Keyed on the day's own counter, not on the per-game one: a game reviewed
    /// yesterday keeps its `reviewed` count forever, and reading that would
    /// hand every morning a moments step that was already finished before the
    /// user woke up. The second clause keeps the legitimate case working —
    /// moments worked through today from a game played yesterday are progress,
    /// not a locked step.
    func isBlocked(_ step: TodayStep) -> Bool {
        guard let required = step.requires else { return false }
        return !isDone(required) && !hasProgressToday(step)
    }

    /// Whether anything was done toward this step *today*.
    private func hasProgressToday(_ step: TodayStep) -> Bool {
        switch step {
        case .game: gamePlayed
        case .moments: momentsReviewed > 0
        case .puzzles: puzzlesDone > 0
        }
    }

    /// Whether the step can be started right now.
    ///
    /// Separate from "blocked", which is about the loop's order. This is about
    /// the work existing yet: a review opened while the post-game pass is still
    /// running shows an empty screen, and a CTA that leads there has spent the
    /// user's one tap on nothing.
    func isActionable(_ step: TodayStep) -> Bool {
        guard step == .moments else { return true }
        return moments != .analysing
    }

    func isDone(_ step: TodayStep) -> Bool {
        // A step whose dependency today has not met is not done, whatever its
        // target arithmetic says. Without this, a game that produced nothing to
        // review yesterday ticks tomorrow's moments row green — and the header
        // reads `1 of 3` before the user has touched anything.
        guard !isBlocked(step) else { return false }

        switch step {
        case .game: return gamePlayed
        // `>=` and not `==`, so a game that produced nothing to review (target
        // 0) counts as done rather than parking the loop on a step with no work
        // in it.
        case .moments: return completed(.moments) >= momentsTarget
        case .puzzles: return puzzlesDone >= puzzleTarget
        }
    }

    func completed(_ step: TodayStep) -> Int {
        switch step {
        case .game:
            return gamePlayed ? 1 : 0
        case .moments:
            switch moments {
            // The day's counter is the only figure either state has.
            case .unknown: return min(momentsReviewed, momentsTarget)
            // A queue still being built has had nothing worked out of it.
            case .analysing, .unavailable: return 0
            case let .counted(_, reviewed): return min(reviewed, momentsTarget)
            }
        case .puzzles:
            return min(puzzlesDone, puzzleTarget)
        }
    }

    func remaining(_ step: TodayStep) -> Int {
        max(target(step) - completed(step), 0)
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
    var title: String { title(target: target) }

    /// The row label for a target this day can actually honour.
    ///
    /// Takes the number rather than reading a constant, because `moments` is
    /// only worth as much as the game produced and the row must not name a
    /// quantity the review screen cannot show.
    func title(target: Int) -> String {
        switch self {
        case .game: "1 game"
        case .moments: target == 0 ? "No moments to review" : "\(target) moment\(target == 1 ? "" : "s")"
        case .puzzles: "\(target) puzzles"
        }
    }

    /// Whole-step cost in minutes, used to state the price on the CTA.
    ///
    /// These are the numbers the app is promising, so they are conservative:
    /// a step that reliably overruns its estimate is worse than one that never
    /// gave an estimate at all.
    ///
    /// The game is priced at 25 because that is what the game the button starts
    /// actually is. Sparring is a 15+10 rapid game (`GameSession.Configuration
    /// .sparring`), and the Play screen prints "15+10" above the board the
    /// moment the CTA is tapped: two sides using a fifteen-minute clock with a
    /// ten-second increment is twenty to forty minutes, not ten. A user who
    /// budgeted the promised ten resigns mid-game, and the app records that as
    /// a loss.
    var estimatedMinutes: Int {
        switch self {
        case .game: 25
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
    /// A coached game on one habit.
    ///
    /// Its own destination rather than a flag on ``play`` because it is the only
    /// route the app has to the guided metrics, and a required rung-2 skill is
    /// gated on one of them: prompts are logged nowhere else, so a user who
    /// follows the ordinary CTA every day can never clear the rung.
    case playGuided(Habit)
    case reviewLatestGame
    case train
    /// The Profile tab: the rating chart, the ladder and the leak table. Named
    /// for what it opens — the finished screen's one link used to promise a
    /// week summary, and no week view exists anywhere in the app.
    case progress
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
    /// The work is coming but is not ready yet — the post-game pass is still
    /// running. Dimmed, with the reason, and *not* tappable: the screen it
    /// would open is empty.
    case waiting
    /// Settled without anything to do: a clean game leaves no moments, and a
    /// failed pass leaves none either. Drawn apart from ``done`` on purpose —
    /// a gold check identical to the one earned by reviewing three moments
    /// tells the user they did work they never did.
    case empty

    var isDimmed: Bool { self == .locked || self == .waiting || self == .empty }
}

struct StepRowState: Equatable, Identifiable, Sendable {
    let step: TodayStep
    let status: StepStatus
    /// Resolved here rather than read off `step` by the view, because the
    /// moments row's label depends on the day's data.
    let title: String
    /// `2` `of 3`. Nil whenever there is no score the user could move — a
    /// `0/3` on a step you cannot start is a number that only looks like a
    /// failure. Those rows carry a ``note`` instead.
    let tally: Denominator?
    /// The row's one line of explanation when it has no tally: why it is
    /// locked, why it is waiting, or why there is nothing in it.
    let note: String?

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
    /// Names the step, **who it is against**, and **its cost**. Never
    /// `Continue` — a generic verb makes the user tap to find out what they
    /// agreed to, and a bare `Play` hides the half of the decision that is
    /// actually interesting.
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

/// The rung bar's value and the count it is a fraction of.
///
/// ## Why the count travels with the fraction
///
/// The bar can only ever move in whole skills. A rung with three required
/// skills goes 0%, 33%, 67%, 100% and nothing in between, so a card that reads
/// `33%` invites the reader to watch for 34% — which will never arrive, however
/// well they play. `1 of 3 met` is the same fact and it also says what the next
/// step costs, which is the only actionable thing about the number.
///
/// ## Why "not measured yet" is counted separately
///
/// A required skill nothing has measured is not a cleared one, so it stays in
/// the denominator — a bar that skipped it would read as further along than the
/// rung actually is. But it is not a *failure* either, and the rest of the app
/// takes care to keep those apart. The caption carries the distinction so the
/// bar does not have to.
struct RungSkillProgress: Equatable, Sendable {

    /// Required skills measured and met.
    let met: Int

    /// Required skills on the rung, whatever their state.
    let total: Int

    /// How many of `total` have no measurement behind them yet.
    let unmeasured: Int

    /// 0...1 for the bar. A rung with no required skills is already clear.
    var fraction: Double { total > 0 ? Double(met) / Double(total) : 1 }

    /// `1 of 3 met · 2 not measured yet`.
    var caption: String {
        let tally = "\(met) of \(total) met"
        guard unmeasured > 0 else { return tally }
        return "\(tally) · \(unmeasured) not measured yet"
    }
}

/// The rung card's content. `skills` is optional on purpose.
struct RungPresentation: Equatable, Sendable {
    let rung: Int
    /// How many rungs the ladder has, so the card can say `Rung 2 of 4`.
    ///
    /// A bare "Rung 2" is a coordinate with no axis: it does not say how far
    /// the ladder goes, and "rung" is the app's organising noun. The card is
    /// the loudest surface on the home screen and it is where the word has to
    /// become legible, because the only other place that explains it is an
    /// accordion three tabs away.
    let rungCount: Int
    let title: String
    /// Required-skill progress. **Nil means not yet measured**, and the card
    /// says so rather than drawing an empty bar. A 0% bar is a claim that the
    /// user has made no progress; "unmeasured" is the truth.
    let skills: RungSkillProgress?
    let focusHabit: String?
    /// Shown in place of the bar when `skills` is nil.
    let unmeasuredNote: String

    /// What the bar measures, stated next to it.
    ///
    /// Without this the card shows a word, a title and a bar with no unit —
    /// and a user cannot tell whether the bar is rating, accuracy or time
    /// served. Every rung is a checklist of required skills; clearing it is
    /// what moves you up.
    static let progressCaption = "Required skills for this rung"

    /// Calibration has already placed the user by the time Today is first
    /// opened, so the note must not say the rung is still to be set — it is on
    /// the card directly above these words. What is genuinely missing on day
    /// one is the skill measurement, which needs played games.
    static let firstRunNote = "Skill progress starts with your first game"
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
            let target = progress.target(step)
            let status: StepStatus
            // Blocked is tested first: a step the day has not unlocked yet is
            // dimmed whatever its arithmetic says. `DailyProgress.isBlocked`
            // owns that rule so the row, the header tally and the streak all
            // read the same day.
            if progress.isBlocked(step) {
                status = .locked
            } else if progress.isDone(step) {
                // A target of zero is a step that was settled by having no work
                // in it, which is not the same event as finishing three
                // moments and must not wear the same gold check.
                status = target == 0 ? .empty : .done
            } else if !progress.isActionable(step) {
                status = .waiting
            } else if step == currentStep {
                status = .current
            } else {
                status = .available
            }

            let note: String?
            switch status {
            case .locked: note = step.lockedReason
            case .waiting: note = "analysing"
            case .empty: note = emptyNote(for: step, progress: progress)
            case .done, .current, .available: note = nil
            }

            return StepRowState(
                step: step,
                status: status,
                title: step.title(target: target),
                tally: note == nil ? .of(progress.completed(step), target) : nil,
                note: note
            )
        }
    }

    /// Why a step ended the day with nothing in it.
    ///
    /// The two reasons are not interchangeable: "your game was clean" is about
    /// the user's play, "the pass did not finish" is about the app. Collapsing
    /// them would credit the app's own failure to the player.
    static func emptyNote(for step: TodayStep, progress: DailyProgress) -> String? {
        guard step == .moments else { return nil }
        return progress.moments == .unavailable ? "not analysed" : "none today"
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
        return unblockedSteps(for: progress).first
    }

    /// Incomplete steps that could be started right now.
    ///
    /// "Right now" includes the work existing: a moments step whose analysis is
    /// still running is skipped, so the loop moves on to the step that has work
    /// in it instead of pointing the filled button at an empty review.
    static func unblockedSteps(for progress: DailyProgress) -> [TodayStep] {
        TodayStep.allCases.filter { step in
            guard !progress.isDone(step), progress.isActionable(step) else { return false }
            return !progress.isBlocked(step)
        }
    }

    // MARK: Copy

    /// `Play Oscar · ~10 min`.
    ///
    /// Both halves are load-bearing. The verb and object say what happens; the
    /// duration is the price. A `Continue` gives neither, so the user has to
    /// spend the tap to find out — and after they have been surprised once,
    /// they stop tapping it when they are short on time.
    ///
    /// - Parameter opponentName: who the next game is against. The object of
    ///   `Play` is a person, not a quantity: `Play Oscar` is a concrete thing to
    ///   agree to, and it is also the name the Play screen is about to put above
    ///   the board. Nil is the honest fallback for a screen that could not find
    ///   out who is next — a vaguer promise beats a wrong name.
    static func actionTitle(
        for step: TodayStep,
        progress: DailyProgress,
        firstRun: Bool,
        opponentName: String? = nil
    ) -> String {
        let remaining = progress.remaining(step)
        let minutes = estimatedMinutes(
            for: step,
            remaining: remaining,
            target: progress.target(step)
        )

        let phrase: String
        switch step {
        case .game:
            if let opponentName {
                phrase = "Play \(opponentName)"
            } else {
                phrase = firstRun ? "Play your first game" : "Play 1 game"
            }
        case .moments:
            phrase = "Review \(remaining) moment\(remaining == 1 ? "" : "s")"
        case .puzzles:
            phrase = "\(remaining) puzzle\(remaining == 1 ? "" : "s")"
        }
        return priced(phrase, minutes: minutes)
    }

    /// The label for an extra game on a day that is already finished.
    ///
    /// Named like every other CTA — who, and how long — because the bordered
    /// weight is already saying "optional" and the words do not have to say it a
    /// second time. With nobody to name it falls back to describing the game.
    static func extraGameTitle(opponentName: String?) -> String {
        guard let opponentName else { return "Play a free game" }
        return priced("Play \(opponentName)", minutes: TodayStep.game.estimatedMinutes)
    }

    /// Every CTA states its price in the same shape, so the number reads as the
    /// same kind of promise wherever it appears.
    private static func priced(_ phrase: String, minutes: Int) -> String {
        "\(phrase) · ~\(minutes) min"
    }

    /// Cost scaled to what is actually left, never to the whole step.
    ///
    /// Telling someone with 8 of 10 puzzles done that it will take 4 minutes is
    /// a small lie, and small lies about time are how a daily habit loses trust.
    static func estimatedMinutes(for step: TodayStep, remaining: Int, target: Int? = nil) -> Int {
        let target = target ?? step.target
        guard target > 0, remaining > 0 else { return step.estimatedMinutes }
        let fraction = Double(remaining) / Double(target)
        return max(1, Int((Double(step.estimatedMinutes) * fraction).rounded(.up)))
    }

    // MARK: Actions

    /// The bordered alternative for a rung waiting on a coached game.
    ///
    /// Named like every other CTA — what, and how long — and it costs the same
    /// as the sparring game above it, because it *is* that game with up to three
    /// questions in it. The second line is the part that matters: without it the
    /// user has no way to know that the required skill their rung is stuck on is
    /// measured in exactly one place and that no amount of ordinary play will
    /// ever move it.
    static func guidedGameAction(habit: Habit) -> TodayAction {
        TodayAction(
            title: "Guided game · \(habit.microGoalTitle.lowercased()) · "
                + "~\(TodayStep.game.estimatedMinutes) min",
            subtitle: "Your rung is waiting on this one, and a guided game is the only place "
                + "it gets measured.",
            destination: .playGuided(habit),
            emphasis: .tertiary,
            step: .game
        )
    }

    /// - Parameter guidedGate: a habit whose guided metric a *required* skill on
    ///   the current rung needs and nothing has measured. When one exists and
    ///   the day's game is still to be played, the alternative offers the
    ///   coached version of that same game instead of the short step — the
    ///   shortest thing is not worth offering on a day when the loop cannot
    ///   otherwise move.
    static func actions(
        phase: TodayPhase,
        progress: DailyProgress,
        opponentName: String? = nil,
        guidedGate: Habit? = nil
    ) -> (primary: TodayAction, alternative: TodayAction?) {

        if phase == .complete {
            // The CTA stops being filled. A filled accent button pointing at
            // optional extra work teaches the user that "the big button" does
            // not mean "the thing you came for", and once that is learned it is
            // learned everywhere in the app.
            return (
                TodayAction(
                    title: extraGameTitle(opponentName: opponentName),
                    subtitle: nil,
                    destination: .play,
                    emphasis: .secondary,
                    step: nil
                ),
                TodayAction(
                    // Named for the screen it opens. "See your week" promised a
                    // week summary that exists nowhere in the app; the Profile
                    // tab holds the rating chart, the ladder and the leaks.
                    title: "See your progress",
                    destination: .progress,
                    emphasis: .tertiary
                )
            )
        }

        guard let next = nextStep(for: progress, phase: phase) else {
            // Nothing startable, and the day is not finished: the review is
            // still being built. Naming the wait is better than offering an
            // extra game as though the day were over.
            if progress.moments == .analysing {
                return (
                    TodayAction(
                        title: "Open the review — still analysing",
                        destination: .reviewLatestGame,
                        emphasis: .secondary
                    ),
                    nil
                )
            }
            return (
                TodayAction(
                    title: extraGameTitle(opponentName: opponentName),
                    destination: .play,
                    emphasis: .secondary
                ),
                nil
            )
        }

        let primary = TodayAction(
            title: actionTitle(
                for: next,
                progress: progress,
                firstRun: phase == .firstRun,
                opponentName: opponentName
            ),
            subtitle: nil,
            destination: next.destination,
            emphasis: .primary,
            step: next
        )

        // A rung stuck on an unmeasured guided skill outranks the short step.
        // Offering "10 puzzles · ~4 min" there is offering the one thing that
        // cannot unblock the ladder, on the day the ladder is what is stuck.
        if let guidedGate, next == .game {
            return (primary, guidedGameAction(habit: guidedGate))
        }

        // The shortest *other* unblocked step, offered plainly. This is the
        // honest version of "pick the shortest": it is stated as an option
        // rather than substituted for the loop.
        let shortest = unblockedSteps(for: progress)
            .filter { $0 != next }
            .min { lhs, rhs in
                estimatedMinutes(
                    for: lhs, remaining: progress.remaining(lhs), target: progress.target(lhs)
                )
                    < estimatedMinutes(
                        for: rhs, remaining: progress.remaining(rhs), target: progress.target(rhs)
                    )
            }

        let alternative = shortest.map { step in
            TodayAction(
                title: "Short on time? "
                    + actionTitle(
                        for: step,
                        progress: progress,
                        firstRun: false,
                        opponentName: opponentName
                    ),
                destination: step.destination,
                emphasis: .tertiary,
                step: step
            )
        }

        return (primary, alternative)
    }

    // MARK: Plan

    /// - Parameter opponentName: who the next sparring game is against, so the
    ///   CTA can name them. Nil when nothing could be read — the copy degrades
    ///   to naming the step instead of the person rather than guessing.
    static func plan(
        progress: DailyProgress,
        hasHistory: Bool,
        streakBroken: Bool,
        opponentName: String? = nil,
        guidedGate: Habit? = nil
    ) -> TodayPlan {
        let phase = phase(today: progress, hasHistory: hasHistory, streakBroken: streakBroken)
        let actions = actions(
            phase: phase,
            progress: progress,
            opponentName: opponentName,
            guidedGate: guidedGate
        )

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
    /// `completedAt` is the authority, and Today stamps it the moment the live
    /// plan is complete — that plan is the only place the day's real moment
    /// queue is known. A row on its own cannot say whether the review step had
    /// any work in it: a clean game leaves no moments, so `momentsReviewed: 0`
    /// is a finished day and an unfinished one wearing the same clothes.
    /// Judging the unstamped row on the two steps that are always available is
    /// therefore the closest a row alone can get, and it is the version that
    /// does not tell a user who finished everything the app asked for that they
    /// missed the day.
    static func isComplete(_ loop: DailyLoop) -> Bool {
        if loop.completedAt != nil { return true }
        return loop.gamePlayed && loop.puzzlesDone >= DailyProgress.puzzlesTarget
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
