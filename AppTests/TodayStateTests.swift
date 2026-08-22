//
//  TodayStateTests.swift
//  ChessCoachTests
//

import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// MARK: - Fixtures

private enum Fixture {

    /// Fixed to UTC and a Sunday-start week so slot positions are deterministic
    /// wherever the suite runs.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    /// Wednesday, 19 August 2026.
    static var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 12))!
    }

    static func date(daysBefore days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: today)!
    }

    static func key(daysBefore days: Int) -> String {
        DailyLoop.dayKey(for: date(daysBefore: days), calendar: calendar)
    }

    static func completedLoop(daysBefore days: Int) -> DailyLoop {
        DailyLoop(
            day: key(daysBefore: days),
            gamePlayed: true,
            momentsReviewed: 3,
            puzzlesDone: 10
        )
    }

    static func partialLoop(daysBefore days: Int) -> DailyLoop {
        DailyLoop(day: key(daysBefore: days), gamePlayed: true)
    }

    /// A row created merely by opening the app — all zeroes.
    static func emptyLoop(daysBefore days: Int) -> DailyLoop {
        DailyLoop(day: key(daysBefore: days))
    }

    static let midProgress = DailyProgress(gamePlayed: true, momentsReviewed: 1, puzzlesDone: 0)
    static let allDone = DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 10)
}

// MARK: - Phase selection

@Suite("Today — which of the four states")
struct TodayPhaseTests {

    @Test("No history at all is the first run")
    func firstRun() {
        let phase = TodayPlanner.phase(today: .zero, hasHistory: false, streakBroken: false)
        #expect(phase == .firstRun)
    }

    @Test("Partway through a day with history is in progress")
    func inProgress() {
        let phase = TodayPlanner.phase(
            today: Fixture.midProgress,
            hasHistory: true,
            streakBroken: false
        )
        #expect(phase == .inProgress)
    }

    @Test("All three steps done is the complete state")
    func complete() {
        let phase = TodayPlanner.phase(today: Fixture.allDone, hasHistory: true, streakBroken: false)
        #expect(phase == .complete)
    }

    @Test("Finishing on the very first day shows complete, not onboarding")
    func completeOnFirstDay() {
        let phase = TodayPlanner.phase(
            today: Fixture.allDone,
            hasHistory: false,
            streakBroken: false
        )
        #expect(phase == .complete)
    }

    @Test("A gap plus an untouched day is the restarted state")
    func streakRestarted() {
        let phase = TodayPlanner.phase(today: .zero, hasHistory: true, streakBroken: true)
        #expect(phase == .streakRestarted)
    }

    @Test("The restart message stops once the user has done anything today")
    func restartMessageIsSaidOnce() {
        let phase = TodayPlanner.phase(
            today: DailyProgress(gamePlayed: true),
            hasHistory: true,
            streakBroken: true
        )
        #expect(phase == .inProgress)
    }

    @Test("A broken streak never reaches a first-run user")
    func brokenStreakNeedsHistory() {
        let phase = TodayPlanner.phase(today: .zero, hasHistory: false, streakBroken: true)
        #expect(phase == .firstRun)
    }
}

// MARK: - Copy

@Suite("Today — returning copy")
struct TodayReturnCopyTests {

    @Test("The greeting leads with the present, before anything about the streak")
    func greetingLeads() {
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: true, streakBroken: true)
        #expect(plan.greeting == "Good to see you.")
        #expect(plan.streakNote == "Your streak restarted.")
    }

    @Test("The streak note carries no number and no blame")
    func streakNoteIsNumberless() {
        let note = TodayPlanner.streakNote(for: .streakRestarted) ?? ""
        let hasDigit = note.contains { $0.isNumber }
        #expect(!hasDigit)
        for word in ["lost", "broke", "broken", "failed", "missed"] {
            #expect(!note.lowercased().contains(word))
        }
    }

    @Test("Only the restarted state greets")
    func otherStatesDoNotGreet() {
        for phase in [TodayPhase.firstRun, .inProgress, .complete] {
            #expect(TodayPlanner.greeting(for: phase) == nil)
            #expect(TodayPlanner.streakNote(for: phase) == nil)
        }
    }

    @Test("The completion note is identity framing, not praise or heat")
    func completionIsIdentityFramed() {
        let plan = TodayPlanner.plan(
            progress: Fixture.allDone,
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.completionNote == TodayPlanner.completionNote)
        #expect(TodayPlanner.completionHeadline == "Done for today.")

        let note = TodayPlanner.completionNote.lowercased()
        for banned in ["fire", "streak", "amazing", "crushing", "hot", "blazing", "!"] {
            #expect(!note.contains(banned))
        }
    }

    @Test("Only the complete state carries a completion note")
    func completionNoteIsScoped() {
        let plan = TodayPlanner.plan(
            progress: Fixture.midProgress,
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.completionNote == nil)
    }
}

// MARK: - CTA

@Suite("Today — CTA copy and routing")
struct TodayActionTests {

    @Test("First run names the game and states its cost")
    func firstRunCTA() {
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: false, streakBroken: false)
        #expect(plan.primary.title == "Play your first game · ~25 min")
        #expect(plan.primary.destination == .play)
        #expect(plan.primary.emphasis == .primary)
        #expect(plan.primary.step == .game)
    }

    @Test("A returning user with no game today is asked for one game")
    func gameCTA() {
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: true, streakBroken: false)
        #expect(plan.primary.title == "Play 1 game · ~25 min")
        #expect(plan.primary.destination == .play)
    }

    @Test("With a game played, the CTA moves to the moments and routes to review")
    func momentsCTA() {
        let plan = TodayPlanner.plan(
            progress: DailyProgress(gamePlayed: true),
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.primary.title == "Review 3 moments · ~5 min")
        #expect(plan.primary.destination == .reviewLatestGame)
        #expect(plan.primary.step == .moments)
    }

    @Test("The last moment is singular, and priced for what is left")
    func momentsSingular() {
        let plan = TodayPlanner.plan(
            progress: DailyProgress(gamePlayed: true, momentsReviewed: 2),
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.primary.title == "Review 1 moment · ~2 min")
    }

    @Test("Puzzle cost scales to the puzzles actually left, not the whole set")
    func puzzleCTAScalesCost() {
        let plan = TodayPlanner.plan(
            progress: DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 4),
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.primary.title == "6 puzzles · ~3 min")
        #expect(plan.primary.destination == .train)
        #expect(plan.primary.step == .puzzles)
    }

    @Test("A whole puzzle set is priced at the full four minutes")
    func fullPuzzleSetCost() {
        let plan = TodayPlanner.plan(
            progress: DailyProgress(gamePlayed: true, momentsReviewed: 3),
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.primary.title == "10 puzzles · ~4 min")
    }

    @Test("The completed state's CTA is secondary, never a filled button")
    func completeCTAIsSecondary() {
        let plan = TodayPlanner.plan(
            progress: Fixture.allDone,
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.primary.emphasis == .secondary)
        #expect(plan.primary.title == "Play a free game")
        #expect(plan.primary.destination == .play)

        // Named for the screen it opens: the Profile tab, which has a rating
        // chart and a ladder and no week view anywhere in it.
        #expect(plan.alternative?.title == "See your progress")
        #expect(plan.alternative?.emphasis == .tertiary)
        #expect(plan.alternative?.destination == .progress)
    }

    @Test("Exactly one primary action exists, and only when work remains")
    func oneFilledButtonAtMost() {
        let states: [(DailyProgress, Bool, Bool)] = [
            (.zero, false, false),
            (.zero, true, true),
            (Fixture.midProgress, true, false),
            (Fixture.allDone, true, false)
        ]
        for (progress, hasHistory, broken) in states {
            let plan = TodayPlanner.plan(
                progress: progress,
                hasHistory: hasHistory,
                streakBroken: broken
            )
            let actions = [plan.primary, plan.alternative].compactMap { $0 }
            let filled = actions.filter { $0.emphasis == .primary }
            #expect(filled.count == (plan.phase == .complete ? 0 : 1))
        }
    }

    @Test("No state ever ships a generic CTA")
    func neverGeneric() {
        let banned = ["continue", "next", "go", "start", "let's go", "ok"]
        let states: [(DailyProgress, Bool, Bool)] = [
            (.zero, false, false),
            (.zero, true, false),
            (.zero, true, true),
            (DailyProgress(gamePlayed: true), true, false),
            (DailyProgress(gamePlayed: true, momentsReviewed: 3), true, false),
            (Fixture.allDone, true, false)
        ]
        for (progress, hasHistory, broken) in states {
            let plan = TodayPlanner.plan(
                progress: progress,
                hasHistory: hasHistory,
                streakBroken: broken
            )
            #expect(!banned.contains(plan.primary.title.lowercased()))
        }
    }

    @Test("Every incomplete state's CTA states a duration")
    func costIsAlwaysStated() {
        let states: [DailyProgress] = [
            .zero,
            DailyProgress(gamePlayed: true),
            DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 9)
        ]
        for progress in states {
            let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)
            #expect(plan.primary.title.contains("min"))
        }
    }

    @Test("A broken streak does not change what today asks for")
    func restartedStateKeepsNormalCTA() {
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: true, streakBroken: true)
        #expect(plan.primary.title == "Play 1 game · ~25 min")
        #expect(plan.primary.destination == .play)
    }
}

// MARK: - Dependencies

@Suite("Today — dependency dimming")
struct TodayDependencyTests {

    @Test("Moments are locked until a game exists, and say why")
    func momentsLockedWithoutGame() throws {
        let steps = TodayPlanner.steps(for: .zero, phase: .firstRun)
        let moments = try #require(steps.first { $0.step == .moments })

        #expect(moments.status == .locked)
        #expect(moments.status.isDimmed)
        #expect(moments.note == "after your game")
        // A locked row shows its reason, not a 0/3 the user could not move.
        #expect(moments.tally == nil)
    }

    @Test("Puzzles are independent and are never locked")
    func puzzlesAreIndependent() throws {
        let steps = TodayPlanner.steps(for: .zero, phase: .firstRun)
        let puzzles = try #require(steps.first { $0.step == .puzzles })

        #expect(puzzles.status == .available)
        #expect(!puzzles.status.isDimmed)
        #expect(puzzles.tally == .of(0, 10))
    }

    @Test("Playing a game unlocks the moments")
    func gameUnlocksMoments() {
        let steps = TodayPlanner.steps(
            for: DailyProgress(gamePlayed: true),
            phase: .inProgress
        )
        #expect(steps.first { $0.step == .game }?.status == .done)
        #expect(steps.first { $0.step == .moments }?.status == .current)
        #expect(steps.first { $0.step == .puzzles }?.status == .available)
    }

    @Test("Exactly one row is current while work remains")
    func oneCurrentRow() {
        for progress in [DailyProgress.zero, DailyProgress(gamePlayed: true), Fixture.midProgress] {
            let steps = TodayPlanner.steps(for: progress, phase: .inProgress)
            let current = steps.filter { $0.status == .current }
            #expect(current.count == 1)
        }
    }

    @Test("The completed state replays all three rows, checked")
    func completedStateReplaysRows() {
        let steps = TodayPlanner.steps(for: Fixture.allDone, phase: .complete)
        let done = steps.filter { $0.status == .done }
        let current = steps.filter { $0.status == .current }
        #expect(steps.count == 3)
        #expect(done.count == 3)
        #expect(steps.map(\.step) == TodayStep.allCases)
        #expect(current.isEmpty)
    }

    @Test("The first run shows the real screen zeroed — three rows, no swap-out")
    func firstRunShowsRealRows() {
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: false, streakBroken: false)
        #expect(plan.steps.count == 3)
        #expect(plan.headerQualifier == .of(0, 3))
    }

    @Test("The shortest independent alternative is offered, and named")
    func shortestAlternative() throws {
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: true, streakBroken: false)
        let alternative = try #require(plan.alternative)

        #expect(alternative.step == .puzzles)
        #expect(alternative.destination == .train)
        #expect(alternative.title == "Short on time? 10 puzzles · ~4 min")
        #expect(alternative.emphasis == .tertiary)
    }

    @Test("No alternative when only one step remains")
    func noAlternativeWhenNothingElseIsAvailable() {
        let plan = TodayPlanner.plan(
            progress: DailyProgress(gamePlayed: true, momentsReviewed: 3),
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.alternative == nil)
    }

    @Test("The tally lives on the header, not in the button")
    func tallyIsOnTheHeader() {
        let plan = TodayPlanner.plan(
            progress: Fixture.midProgress,
            hasHistory: true,
            streakBroken: false
        )
        #expect(plan.headerQualifier == .of(1, 3))
        #expect(plan.headerQualifier.accessibilityText == "1 of 3")
        #expect(!plan.primary.title.contains("of 3"))
    }
}

// MARK: - Streak strip

@Suite("Today — streak strip markers")
struct StreakStripTests {

    private func slot(_ slots: [DaySlot], daysBefore days: Int) -> DaySlot? {
        let key = Fixture.key(daysBefore: days)
        return slots.first { $0.dayKey == key }
    }

    @Test("Completed, missed, today and tomorrow each get their own marker")
    func markerStates() {
        // Wednesday. Sunday and Monday done, Tuesday missed.
        let completed: Set<String> = [Fixture.key(daysBefore: 3), Fixture.key(daysBefore: 2)]
        let slots = StreakCalculator.weekSlots(
            completedDays: completed,
            today: Fixture.today,
            calendar: Fixture.calendar,
            hasHistory: true
        )

        #expect(slots.count == 7)
        #expect(slot(slots, daysBefore: 3)?.marker == .done)
        #expect(slot(slots, daysBefore: 2)?.marker == .done)
        #expect(slot(slots, daysBefore: 1)?.marker == .missed)
        #expect(slot(slots, daysBefore: 0)?.marker == .today)
        #expect(slot(slots, daysBefore: -1)?.marker == .tomorrow)
        #expect(slot(slots, daysBefore: -2)?.marker == .upcoming)
    }

    @Test("Tomorrow is distinct from a miss")
    func tomorrowIsNotAMiss() {
        let slots = StreakCalculator.weekSlots(
            completedDays: [],
            today: Fixture.today,
            calendar: Fixture.calendar,
            hasHistory: true
        )
        #expect(slot(slots, daysBefore: -1)?.marker == .tomorrow)
        #expect(slot(slots, daysBefore: 1)?.marker == .missed)
    }

    @Test("On a first run nothing is marked missed — you cannot miss what you could not play")
    func firstRunHasNoMisses() {
        let slots = StreakCalculator.weekSlots(
            completedDays: [],
            today: Fixture.today,
            calendar: Fixture.calendar,
            hasHistory: false
        )
        let missed = slots.filter { $0.marker == .missed }
        let upcoming = slots.filter { $0.marker == .upcoming }
        #expect(missed.isEmpty)
        #expect(upcoming.count == 5)
        #expect(slot(slots, daysBefore: 0)?.marker == .today)
    }

    @Test("Finishing today marks today done rather than open")
    func completedTodayIsDone() {
        let slots = StreakCalculator.weekSlots(
            completedDays: [Fixture.key(daysBefore: 0)],
            today: Fixture.today,
            calendar: Fixture.calendar,
            hasHistory: true
        )
        #expect(slot(slots, daysBefore: 0)?.marker == .done)
    }

    @Test("There is no failure marker to reach for")
    func markersCarryNoVerdict() {
        let slots = StreakCalculator.weekSlots(
            completedDays: [Fixture.key(daysBefore: 4)],
            today: Fixture.today,
            calendar: Fixture.calendar,
            hasHistory: true
        )
        let allowed: Set<DayMarker> = [.done, .missed, .today, .tomorrow, .upcoming]
        let unexpected = slots.filter { !allowed.contains($0.marker) }
        #expect(unexpected.isEmpty)
    }

    @Test("Weekday initials are rotated to the calendar's own first weekday")
    func weekdayInitialsRotate() {
        var monday = Fixture.calendar
        monday.firstWeekday = 2
        let sundayFirst = StreakCalculator.weekdayInitials(calendar: Fixture.calendar)
        let mondayFirst = StreakCalculator.weekdayInitials(calendar: monday)

        #expect(sundayFirst.count == 7)
        #expect(mondayFirst.count == 7)
        #expect(mondayFirst.first == sundayFirst[1])
    }
}

// MARK: - Streak arithmetic

@Suite("Today — streak arithmetic")
struct StreakCalculatorTests {

    @Test("Only a fully completed loop counts as a day")
    func partialDaysDoNotCount() {
        let loops = [Fixture.partialLoop(daysBefore: 1), Fixture.completedLoop(daysBefore: 2)]
        let completed = StreakCalculator.completedDays(loops)
        #expect(completed == [Fixture.key(daysBefore: 2)])
    }

    @Test("A row created by merely opening the app is not a completed day")
    func emptyRowsDoNotCount() {
        let completed = StreakCalculator.completedDays([Fixture.emptyLoop(daysBefore: 1)])
        #expect(completed.isEmpty)
    }

    @Test("Consecutive completed days are counted")
    func countsConsecutiveDays() {
        let completed: Set<String> = Set((0...3).map(Fixture.key(daysBefore:)))
        let streak = StreakCalculator.currentStreak(
            completedDays: completed,
            today: Fixture.today,
            calendar: Fixture.calendar
        )
        #expect(streak == 4)
    }

    @Test("An unfinished today does not zero the streak — it is still today")
    func todayInProgressKeepsTheStreak() {
        let completed: Set<String> = Set((1...3).map(Fixture.key(daysBefore:)))
        let streak = StreakCalculator.currentStreak(
            completedDays: completed,
            today: Fixture.today,
            calendar: Fixture.calendar
        )
        #expect(streak == 3)
    }

    @Test("A gap ends the count")
    func gapEndsTheCount() {
        let completed: Set<String> = [
            Fixture.key(daysBefore: 1),
            Fixture.key(daysBefore: 3),
            Fixture.key(daysBefore: 4)
        ]
        let streak = StreakCalculator.currentStreak(
            completedDays: completed,
            today: Fixture.today,
            calendar: Fixture.calendar
        )
        #expect(streak == 1)
    }

    @Test("A missed yesterday with earlier history is a break")
    func detectsBreak() {
        let completed: Set<String> = [
            Fixture.key(daysBefore: 4),
            Fixture.key(daysBefore: 5)
        ]
        #expect(
            StreakCalculator.isStreakBroken(
                completedDays: completed,
                today: Fixture.today,
                calendar: Fixture.calendar
            )
        )
    }

    @Test("Yesterday completed is not a break")
    func yesterdayIsNotABreak() {
        #expect(
            !StreakCalculator.isStreakBroken(
                completedDays: [Fixture.key(daysBefore: 1)],
                today: Fixture.today,
                calendar: Fixture.calendar
            )
        )
    }

    @Test("Nothing to break when there is no history")
    func noHistoryIsNotABreak() {
        #expect(
            !StreakCalculator.isStreakBroken(
                completedDays: [],
                today: Fixture.today,
                calendar: Fixture.calendar
            )
        )
    }

    @Test("A day with any progress counts as history, an all-zero row does not")
    func historyDetection() {
        let todayKey = Fixture.key(daysBefore: 0)
        #expect(
            StreakCalculator.hasHistory(
                [Fixture.partialLoop(daysBefore: 2)],
                todayKey: todayKey
            )
        )
        #expect(
            !StreakCalculator.hasHistory(
                [Fixture.emptyLoop(daysBefore: 2)],
                todayKey: todayKey
            )
        )
        // Today's own row is never history.
        #expect(
            !StreakCalculator.hasHistory(
                [Fixture.completedLoop(daysBefore: 0)],
                todayKey: todayKey
            )
        )
    }
}

// MARK: - Progress

@Suite("Today — daily progress")
struct DailyProgressTests {

    @Test("Completion needs all three targets")
    func completion() {
        #expect(Fixture.allDone.isComplete)
        #expect(!DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 9).isComplete)
        #expect(DailyProgress(gamePlayed: true, momentsReviewed: 5, puzzlesDone: 12).isComplete)
    }

    @Test("Untouched means nothing at all has happened")
    func untouched() {
        #expect(DailyProgress.zero.isUntouched)
        #expect(!DailyProgress(puzzlesDone: 1).isUntouched)
    }

    @Test("Tallies clamp to the target rather than overshooting the row")
    func talliesClamp() {
        let progress = DailyProgress(gamePlayed: true, momentsReviewed: 9, puzzlesDone: 25)
        #expect(progress.completed(.moments) == 3)
        #expect(progress.completed(.puzzles) == 10)
        #expect(progress.remaining(.puzzles) == 0)
    }

    @Test("A DailyLoop row maps straight across")
    func fromLoop() {
        let progress = DailyProgress(Fixture.completedLoop(daysBefore: 0))
        #expect(progress == Fixture.allDone)
    }
}

// MARK: - The moments step promises only what the game produced

/// The moments step is the one step whose work the user does not create by
/// showing up. A clean game or a two-move resignation leaves nothing to review,
/// and a fixed "Review 3 moments" CTA then opens a review screen with nothing
/// in it — which is the single worst thing the Today screen can do, because the
/// CTA is the promise the whole daily loop rests on.
@Suite("Today · moments availability")
struct TodayMomentsAvailabilityTests {

    @Test("An uncounted queue keeps the nominal target")
    func unknownKeepsNominalTarget() {
        let progress = DailyProgress(gamePlayed: true, moments: .unknown)
        #expect(progress.momentsTarget == 3)
        #expect(!progress.isDone(.moments))
    }

    @Test("A game with fewer moments than the target promises only what it has")
    func targetShrinksToWhatExists() {
        let progress = DailyProgress(gamePlayed: true, moments: .counted(total: 2, reviewed: 0))
        #expect(progress.momentsTarget == 2)
        #expect(progress.remaining(.moments) == 2)

        let title = TodayPlanner.actionTitle(
            for: .moments,
            progress: progress,
            firstRun: false
        )
        #expect(title.contains("Review 2 moments"))
    }

    @Test("The target holds steady as the moments are worked through")
    func targetDoesNotShrinkWithTheWork() {
        // The bug this pins: sizing the step from *unread* moments meant the
        // target fell as fast as the tally rose. Opening the review marks its
        // first card reviewed, so the step read "1 of 2" and then ticked done
        // at two of three — and the third moment, often the most instructive,
        // was never asked for.
        let opened = DailyProgress(
            gamePlayed: true,
            momentsReviewed: 1,
            moments: .counted(total: 3, reviewed: 1)
        )
        #expect(opened.momentsTarget == 3)
        #expect(opened.completed(.moments) == 1)
        #expect(!opened.isDone(.moments))

        let title = TodayPlanner.actionTitle(for: .moments, progress: opened, firstRun: false)
        #expect(title.contains("Review 2 moments"))

        let two = DailyProgress(
            gamePlayed: true,
            momentsReviewed: 2,
            moments: .counted(total: 3, reviewed: 2)
        )
        #expect(!two.isDone(.moments))

        let all = DailyProgress(
            gamePlayed: true,
            momentsReviewed: 3,
            moments: .counted(total: 3, reviewed: 3)
        )
        #expect(all.isDone(.moments))
        #expect(all.completed(.moments) == 3)
    }

    @Test("A second game the same day reopens the step for its own moments")
    func secondGameReopensTheStep() {
        // The day counter says three moments were worked through — from the
        // first game. The second game's queue is untouched, and the step that
        // teaches must ask for it rather than staying gold.
        let progress = DailyProgress(
            gamePlayed: true,
            momentsReviewed: 3,
            puzzlesDone: 10,
            moments: .counted(total: 3, reviewed: 0)
        )
        #expect(!progress.isDone(.moments))
        #expect(progress.completed(.moments) == 0)

        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)
        #expect(plan.primary.step == .moments)
        #expect(plan.primary.title == "Review 3 moments · ~5 min")
    }

    @Test("While the pass is running the CTA promises no count")
    func analysingPromisesNothing() throws {
        let progress = DailyProgress(gamePlayed: true, moments: .analysing)
        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)

        let moments = try #require(plan.steps.first { $0.step == .moments })
        #expect(moments.status == .waiting)
        #expect(moments.note == "analysing")
        #expect(moments.tally == nil)

        // The loop moves to the step that has work in it rather than sending
        // the one filled button at an empty review screen.
        #expect(plan.primary.step == .puzzles)
        #expect(!plan.primary.title.contains("moment"))
    }

    @Test("A stalled pass names the wait instead of offering an extra game")
    func analysingWithNothingElseLeftSaysSo() {
        let progress = DailyProgress(
            gamePlayed: true,
            puzzlesDone: 10,
            moments: .analysing
        )
        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)

        #expect(plan.phase != .complete)
        #expect(plan.primary.title == "Open the review — still analysing")
        #expect(plan.primary.destination == .reviewLatestGame)
        #expect(plan.primary.emphasis == .secondary)
    }

    @Test("A failed pass is said plainly and does not park the day")
    func failedAnalysisDoesNotBlockTheDay() throws {
        let progress = DailyProgress(
            gamePlayed: true,
            puzzlesDone: 10,
            moments: .unavailable
        )
        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)

        let moments = try #require(plan.steps.first { $0.step == .moments })
        // Not a gold check: the pass failing is the app's doing, not work the
        // user did — but it must not hold the day hostage either.
        #expect(moments.status == .empty)
        #expect(moments.note == "not analysed")
        #expect(progress.isComplete)
    }

    @Test("A game that produced nothing does not advertise a review")
    func nothingToReviewIsNotPromised() throws {
        let progress = DailyProgress(gamePlayed: true, moments: .counted(total: 0, reviewed: 0))

        // The step is satisfied rather than parked: there is no work in it.
        #expect(progress.isDone(.moments))

        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)
        // The loop moves on to the step that does have work.
        #expect(plan.primary.step == .puzzles)
        #expect(!plan.primary.title.contains("moment"))

        // And the square says it had nothing, rather than wearing the same
        // gold check as a day three moments were worked through.
        let moments = try #require(plan.steps.first { $0.step == .moments })
        #expect(moments.status == .empty)
        #expect(moments.note == "none today")
    }

    @Test("A zero target never ticks the moments row before the day's game")
    func zeroTargetDoesNotPreCompleteTheRow() throws {
        // Yesterday's game produced nothing, and today has not started. The
        // row must still read locked — a green check for work that was never
        // available today is a lie about the day.
        let progress = DailyProgress(gamePlayed: false, moments: .counted(total: 0, reviewed: 0))
        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)

        let moments = try #require(plan.steps.first { $0.step == .moments })
        #expect(moments.status == .locked)
        #expect(moments.note == "after your game")
        #expect(plan.primary.step == .game)
    }

    @Test("The header counts nothing before the day has been touched")
    func headerStartsAtZero() throws {
        // Yesterday's game, fully reviewed yesterday. Today has not started, so
        // the tally must read 0 of 3 — a `1 of 3` before the user has done
        // anything spends the trust of the one count on the screen.
        let progress = DailyProgress(
            gamePlayed: false,
            momentsReviewed: 0,
            moments: .counted(total: 3, reviewed: 3)
        )
        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)

        #expect(plan.headerQualifier == .of(0, 3))
        let moments = try #require(plan.steps.first { $0.step == .moments })
        #expect(moments.status == .locked)
    }

    @Test("Moments reviewed today from an older game still read as done")
    func reviewingYesterdaysGameCounts() throws {
        // The legitimate case the locked rule must not break: play Monday,
        // review Tuesday.
        let progress = DailyProgress(
            gamePlayed: false,
            momentsReviewed: 3,
            moments: .counted(total: 3, reviewed: 3)
        )
        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)

        let moments = try #require(plan.steps.first { $0.step == .moments })
        #expect(moments.status == .done)
    }

    @Test("Emptying a short queue never shows a tally over its own denominator")
    func clearedShortQueueReadsCleanly() {
        let progress = DailyProgress(
            gamePlayed: true,
            momentsReviewed: 2,
            moments: .counted(total: 2, reviewed: 2)
        )
        #expect(progress.momentsTarget == 2)
        #expect(progress.completed(.moments) == 2)
        #expect(progress.remaining(.moments) == 0)
        #expect(progress.isDone(.moments))
    }

    @Test("A count that arrives below what was already reviewed cannot regress the row")
    func lateCountCannotRegressProgress() {
        // Re-analysis can replace a game's moments while the day's work is
        // already done. The row must not turn into a `3 of 0`.
        let progress = DailyProgress(
            gamePlayed: true,
            momentsReviewed: 3,
            moments: .counted(total: 0, reviewed: 3)
        )
        #expect(progress.momentsTarget == 3)
        #expect(progress.completed(.moments) == 3)
        #expect(progress.isDone(.moments))
    }

    @Test("The row label names the real number, and says so when there is none")
    func rowLabelIsHonest() {
        #expect(TodayStep.moments.title(target: 3) == "3 moments")
        #expect(TodayStep.moments.title(target: 1) == "1 moment")
        #expect(TodayStep.moments.title(target: 0) == "No moments to review")
    }

    @Test("A short review is priced for the work that is actually left")
    func costScalesToTheShortQueue() {
        let full = DailyProgress(gamePlayed: true, moments: .counted(total: 3, reviewed: 0))
        let short = DailyProgress(gamePlayed: true, moments: .counted(total: 1, reviewed: 0))

        let fullMinutes = TodayPlanner.estimatedMinutes(
            for: .moments, remaining: full.remaining(.moments), target: full.momentsTarget
        )
        let shortMinutes = TodayPlanner.estimatedMinutes(
            for: .moments, remaining: short.remaining(.moments), target: short.momentsTarget
        )
        // One moment out of a possible one is still the whole step, so this is
        // not a fraction of the full estimate — but it must never exceed it.
        #expect(shortMinutes <= fullMinutes)
        #expect(shortMinutes >= 1)
    }
}

// MARK: - The set is as long as the user said it was

/// Today prices and tallies the puzzle step from the length chosen on Train.
/// Two screens negotiating one decision is how "10 puzzles · ~4 min" becomes a
/// set of five, and a `5 of 10` that can never be finished.
@Suite("Today · puzzle set length")
struct TodayPuzzleTargetTests {

    @Test("A shorter chosen set is what the row and the CTA name")
    func shortSetIsNamed() throws {
        let progress = DailyProgress(gamePlayed: true, puzzleTarget: 5)
        #expect(progress.target(.puzzles) == 5)

        let plan = TodayPlanner.plan(progress: progress, hasHistory: true, streakBroken: false)
        let puzzles = try #require(plan.steps.first { $0.step == .puzzles })
        #expect(puzzles.title == "5 puzzles")
        #expect(puzzles.tally == .of(0, 5))
    }

    @Test("A finished short set completes the step rather than reading 5 of 10")
    func shortSetCompletes() {
        let progress = DailyProgress(gamePlayed: true, puzzlesDone: 5, puzzleTarget: 5)
        #expect(progress.isDone(.puzzles))
        #expect(progress.completed(.puzzles) == 5)
        #expect(progress.remaining(.puzzles) == 0)
    }

    @Test("A longer chosen set is not marked done at ten")
    func longSetIsNotDoneEarly() {
        let progress = DailyProgress(gamePlayed: true, puzzlesDone: 10, puzzleTarget: 15)
        #expect(!progress.isDone(.puzzles))
        #expect(progress.remaining(.puzzles) == 5)
    }
}

// MARK: - The day the screen calls done is the day the streak counts

/// The completion banner and the streak strip have to agree. They did not: the
/// screen judged the day against the moments the game actually produced, and
/// the streak judged the stored row against a fixed three.
@Suite("Today · a finished day counts")
struct TodayCompletionCreditTests {

    @Test("A stamped day counts however few moments the game left")
    func stampedDayCounts() {
        var loop = DailyLoop(
            day: "2026-08-19",
            gamePlayed: true,
            momentsReviewed: 1,
            puzzlesDone: 10
        )
        #expect(StreakCalculator.isComplete(loop))

        loop.completedAt = Date()
        #expect(StreakCalculator.isComplete(loop))
    }

    @Test("A clean game's day is not a missed day")
    func cleanGameDayCounts() {
        // No moments were produced, so none were reviewed. The screen showed
        // three gold squares and "Done for today."; the strip used to grey the
        // day out and the next morning opened with "Your streak restarted."
        let loop = DailyLoop(
            day: "2026-08-19",
            gamePlayed: true,
            momentsReviewed: 0,
            puzzlesDone: 10,
            completedAt: Date()
        )
        #expect(StreakCalculator.isComplete(loop))
    }

    @Test("An unfinished day still does not count")
    func unfinishedDayDoesNotCount() {
        let played = DailyLoop(day: "2026-08-19", gamePlayed: true)
        let puzzlesOnly = DailyLoop(day: "2026-08-19", puzzlesDone: 10)
        #expect(!StreakCalculator.isComplete(played))
        #expect(!StreakCalculator.isComplete(puzzlesOnly))
    }
}

// MARK: - The guided gate

/// `r2.threatAwareness` is a *required* rung-2 skill, and one of its criteria is
/// `guided.scanThreats.hitRate` — a number written only when a guided prompt
/// fires and is answered. Following the daily CTA plays sparring games, so a
/// user could clear every other criterion on the rung and still never advance,
/// with nothing on any screen naming the door that was shut.
@Suite("Guided-game alternative")
struct TodayGuidedGateTests {

    private func progress(gamePlayed: Bool) -> DailyProgress {
        DailyProgress(gamePlayed: gamePlayed, momentsReviewed: 0, puzzlesDone: 0)
    }

    @Test("An unmeasured guided metric replaces the short alternative")
    func guidedGameIsOffered() {
        let actions = TodayPlanner.actions(
            phase: .inProgress,
            progress: progress(gamePlayed: false),
            opponentName: "Oscar",
            guidedGate: .scanThreats
        )
        #expect(actions.alternative?.destination == .playGuided(.scanThreats))
        #expect(actions.alternative?.title == "Guided game · check opponent threats · ~25 min")
        // The button cannot say why on its own, and without the why there is no
        // reason to choose a coached game over the one above it.
        #expect(actions.alternative?.subtitle != nil)
        // Same game, same price: guided is sparring with questions in it.
        #expect(actions.primary.title == "Play Oscar · ~25 min")
    }

    @Test("With no gate the short step is still what is offered")
    func shortStepSurvives() {
        let actions = TodayPlanner.actions(
            phase: .inProgress,
            progress: progress(gamePlayed: false),
            opponentName: "Oscar"
        )
        #expect(actions.alternative?.destination == .train)
    }

    @Test("The gate does not hijack a day whose game is already played")
    func noGuidedOfferAfterTheGame() {
        let actions = TodayPlanner.actions(
            phase: .inProgress,
            progress: progress(gamePlayed: true),
            opponentName: "Oscar",
            guidedGate: .scanThreats
        )
        // The game step is done; asking for a second one as the "alternative"
        // would be offering a 25-minute detour in the slot reserved for the
        // cheapest thing left.
        #expect(actions.alternative?.destination != .playGuided(.scanThreats))
    }

    @Test("Only metrics with no other producer map to a guided habit")
    func guidedHabitMapping() {
        #expect(TodayModel.guidedHabit(for: .guidedScanThreatsHitRate) == .scanThreats)
        #expect(TodayModel.guidedHabit(for: .ignoredThreatPer100) == nil)
        #expect(TodayModel.guidedHabit(for: .kpkDrillCleanSetStreak) == nil)
    }
}
