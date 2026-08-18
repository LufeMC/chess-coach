import Foundation
import Testing

@testable import TrainingCore

@Suite("Leak aggregation")
struct LeakTests {

    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let day: TimeInterval = 86_400

    /// `count` games, one per day, ending today. Index 0 is the most recent, so
    /// the index in this array is `gamesAgo`.
    func recentGames(_ count: Int) -> [GameRecord] {
        (0..<count).map { GameRecord(id: "g\($0)", playedAt: now.addingTimeInterval(-Double($0) * day)) }
    }

    @Test("Recency weighting halves a leak every ten games")
    func recencyWeighting() {
        let games = recentGames(12)
        let mistakes = [
            MistakeRecord(gameID: "g0", causeTag: .hungMovedPiece, deltaEP: 1.0),
            MistakeRecord(gameID: "g10", causeTag: .missedNewThreat, deltaEP: 1.0)
        ]

        let leaks = LeakAnalyzer.leaks(from: mistakes, games: games, rung: 1, now: now)
        #expect(leaks.count == 2)

        let recent = leaks.first { $0.causeTag == .hungMovedPiece }!
        let old = leaks.first { $0.causeTag == .missedNewThreat }!

        // Identical raw damage; the old one counts half.
        #expect(abs(recent.weightedEPLost - 1.0) < 1e-12)
        #expect(abs(old.weightedEPLost - 0.5) < 1e-12)
        #expect(abs(old.weightedEPLost - recent.weightedEPLost * 0.5) < 1e-12)

        // ...and that ordering is what the chart is sorted by.
        #expect(leaks[0].causeTag == .hungMovedPiece)
    }

    @Test("Five games ago is weighted by the square root of a half")
    func weightCurve() {
        let games = recentGames(12)
        let leaks = LeakAnalyzer.leaks(
            from: [MistakeRecord(gameID: "g5", causeTag: .hungMovedPiece, deltaEP: 2.0)],
            games: games,
            rung: 1,
            now: now
        )
        #expect(abs(leaks[0].weightedEPLost - 2.0 * 0.7071067811865476) < 1e-12)
    }

    @Test("A recent small leak can outrank an old large one")
    func recencyCanOutrankMagnitude() {
        // This is the behaviour that makes the chart a coaching tool rather
        // than a lifetime statistic.
        let games = recentGames(30)
        let leaks = LeakAnalyzer.leaks(
            from: [
                MistakeRecord(gameID: "g0", causeTag: .hungMovedPiece, deltaEP: 1.0),
                MistakeRecord(gameID: "g25", causeTag: .missedNewThreat, deltaEP: 2.5)
            ],
            games: games,
            rung: 1,
            now: now
        )
        #expect(leaks[0].causeTag == .hungMovedPiece)
    }

    @Test("Per-game numbers use the window's game count, including mistake-free games")
    func perGameDenominator() {
        let games = recentGames(10)
        let leaks = LeakAnalyzer.leaks(
            from: [MistakeRecord(gameID: "g0", causeTag: .hungMovedPiece, deltaEP: 3.0)],
            games: games,
            rung: 1,
            now: now
        )
        #expect(leaks[0].count == 1)
        #expect(abs(leaks[0].epLostPerGame - 3.0 / 10.0) < 1e-12)
    }

    @Test("A sparse window is extended back until it holds at least eight games")
    func windowExtendsForSparsePlay() {
        // Three games in the last 21 days plus six much older ones. A fixed day
        // window would build the chart from three games and present it with the
        // same confidence as one built from thirty.
        var games = (0..<3).map {
            GameRecord(id: "recent\($0)", playedAt: now.addingTimeInterval(-Double($0 + 1) * day))
        }
        games += (0..<6).map {
            GameRecord(id: "old\($0)", playedAt: now.addingTimeInterval(-Double(40 + $0) * day))
        }

        // Games ago 0...7 are in the window; the ninth game (index 8) is not.
        let inWindow = LeakAnalyzer.leaks(
            from: [MistakeRecord(gameID: "old4", causeTag: .hungMovedPiece, deltaEP: 1.0)],
            games: games, rung: 1, now: now
        )
        #expect(inWindow.count == 1)
        #expect(inWindow[0].count == 1)

        let outsideWindow = LeakAnalyzer.leaks(
            from: [MistakeRecord(gameID: "old5", causeTag: .hungMovedPiece, deltaEP: 1.0)],
            games: games, rung: 1, now: now
        )
        #expect(outsideWindow.isEmpty)
    }

    @Test("Mistakes from games older than the window are excluded")
    func oldGamesExcluded() {
        var games = recentGames(10)
        games.append(GameRecord(id: "ancient", playedAt: now.addingTimeInterval(-200 * day)))

        let leaks = LeakAnalyzer.leaks(
            from: [MistakeRecord(gameID: "ancient", causeTag: .hungMovedPiece, deltaEP: 50)],
            games: games, rung: 1, now: now
        )
        #expect(leaks.isEmpty)
    }

    @Test("Week-over-week delta is negative when the leak is shrinking")
    func weekOverWeekDelta() {
        var games = (1...4).map { GameRecord(id: "this\($0)", playedAt: now.addingTimeInterval(-Double($0) * day)) }
        games += (8...11).map { GameRecord(id: "prev\($0)", playedAt: now.addingTimeInterval(-Double($0) * day)) }

        let mistakes = [
            MistakeRecord(gameID: "this1", causeTag: .hungMovedPiece, deltaEP: 1.0),
            MistakeRecord(gameID: "this2", causeTag: .hungMovedPiece, deltaEP: 1.0),
            MistakeRecord(gameID: "prev8", causeTag: .hungMovedPiece, deltaEP: 1.0),
            MistakeRecord(gameID: "prev9", causeTag: .hungMovedPiece, deltaEP: 1.0),
            MistakeRecord(gameID: "prev10", causeTag: .hungMovedPiece, deltaEP: 1.0),
            MistakeRecord(gameID: "prev11", causeTag: .hungMovedPiece, deltaEP: 1.0)
        ]

        let leaks = LeakAnalyzer.leaks(from: mistakes, games: games, rung: 1, now: now)
        // 2.0 over 4 games this week vs 4.0 over 4 games last week.
        #expect(abs(leaks[0].deltaVsPreviousWeek - (0.5 - 1.0)) < 1e-12)
    }

    @Test("With no comparable previous week the delta is zero, not a fabricated improvement")
    func incomparableWeek() {
        let games = (1...4).map { GameRecord(id: "this\($0)", playedAt: now.addingTimeInterval(-Double($0) * day)) }
        let leaks = LeakAnalyzer.leaks(
            from: [MistakeRecord(gameID: "this1", causeTag: .hungMovedPiece, deltaEP: 1.0)],
            games: games, rung: 1, now: now
        )
        #expect(leaks[0].deltaVsPreviousWeek == 0)
    }

    @Test("Leaks carry the habit for the user's rung")
    func habitMapping() {
        let games = recentGames(10)
        let mistakes = [MistakeRecord(gameID: "g0", causeTag: .openingPrinciple, deltaEP: 1.0)]

        #expect(LeakAnalyzer.leaks(from: mistakes, games: games, rung: 1, now: now)[0].habit == .blunderCheck)
        #expect(LeakAnalyzer.leaks(from: mistakes, games: games, rung: 2, now: now)[0].habit == .candidatesFirst)
    }

    @Test("Every known cause tag maps to a habit at every rung")
    func mappingIsTotal() {
        for tag in CauseTag.known {
            for rung in 1...4 {
                #expect(tag.habit(rung: rung) != nil, "\(tag.rawValue) unmapped at rung \(rung)")
            }
        }
        // An unknown tag from a newer build maps to nothing rather than crashing.
        #expect(CauseTag("somethingNewAndUnknown").habit(rung: 2) == nil)
    }

    @Test("No games means no leaks rather than a division by zero")
    func emptyInput() {
        #expect(LeakAnalyzer.leaks(from: [], games: [], rung: 1, now: now).isEmpty)
    }
}

@Suite("Weekly focus selection")
struct FocusTests {

    /// 2026-08-17 is a Monday; 2026-08-19 is a Wednesday.
    let monday = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "UTC"),
        year: 2026, month: 8, day: 17, hour: 9
    ).date!

    let wednesday = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "UTC"),
        year: 2026, month: 8, day: 19, hour: 9
    ).date!

    var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func leak(_ tag: CauseTag, _ weight: Double) -> Leak {
        Leak(
            causeTag: tag,
            habit: nil,
            weightedEPLost: weight,
            epLostPerGame: weight / 10,
            count: 3,
            deltaVsPreviousWeek: 0
        )
    }

    /// blunderCheck leads, calcToQuiet second. Both are measured on rung 1.
    var twoLeaks: [Leak] {
        [leak(.hungMovedPiece, 5.0), leak(.miscalculatedTactic, 3.0)]
    }

    @Test("The fixture dates really are a Monday and a Wednesday")
    func fixtureSanity() {
        #expect(utcCalendar.component(.weekday, from: monday) == 2)
        #expect(utcCalendar.component(.weekday, from: wednesday) == 4)
    }

    @Test("With no previous focus, the heaviest mapped leak wins")
    func initialSelection() {
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: nil, weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(), now: wednesday, calendar: utcCalendar
        )
        #expect(focus.habit == .blunderCheck)
        #expect(focus.primaryCauseTag == .hungMovedPiece)
        #expect(focus.reason == .initialSelection)
        #expect(focus.drillQuotaMultiplier == 1)
    }

    @Test("Selection respects the rung's habit mapping")
    func rungMapping() {
        // `openingPrinciple` maps to blunderCheck at rung 1 and candidatesFirst
        // from rung 2 up.
        let leaks = [leak(.openingPrinciple, 4.0)]

        let atRung1 = FocusSelector.selectFocus(
            leaks: leaks, rung: 1, currentFocus: nil, weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(atRung1.habit == .blunderCheck)

        let atRung2 = FocusSelector.selectFocus(
            leaks: leaks, rung: 2, currentFocus: nil, weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(atRung2.habit == .candidatesFirst)
    }

    @Test("A habit the current rung does not measure is skipped in favour of one it does")
    func rungRestriction() {
        // clockDiscipline is only measured on rung 4. On rung 2 the smaller
        // leak that the rung actually tracks must win.
        let leaks = [
            Leak(causeTag: CauseTag("clockPressure"), habit: .clockDiscipline,
                 weightedEPLost: 9.0, epLostPerGame: 0.9, count: 5, deltaVsPreviousWeek: 0),
            leak(.miscalculatedTactic, 2.0)
        ]
        let focus = FocusSelector.selectFocus(
            leaks: leaks, rung: 2, currentFocus: nil, weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(focus.habit == .calcToQuiet)

        // On rung 4, where clock discipline IS measured, the big leak wins.
        let atRung4 = FocusSelector.selectFocus(
            leaks: leaks, rung: 4, currentFocus: nil, weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(atRung4.habit == .clockDiscipline)
    }

    @Test("Leaks are summed per habit, because the habit is the unit of action")
    func leaksAggregateByHabit() {
        // Three small blunder-check leaks beat one larger calculation leak.
        let leaks = [
            leak(.miscalculatedTactic, 4.0),
            leak(.hungMovedPiece, 2.0),
            leak(.hungLeftPiece, 2.0),
            leak(.allowedShallowTactic, 2.0)
        ]
        let focus = FocusSelector.selectFocus(
            leaks: leaks, rung: 1, currentFocus: nil, weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(focus.habit == .blunderCheck)
    }

    @Test("Between rotation points the focus is left alone")
    func noMidWeekThrash() {
        // Without this, one bad game reshuffles the chart and hands the user a
        // different assignment on Wednesday.
        let current = WeeklyFocus(habit: .calcToQuiet, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(), now: wednesday, calendar: utcCalendar
        )
        #expect(focus.habit == .calcToQuiet)
        #expect(focus.reason == .unchanged)
    }

    @Test("Monday rotates to the current heaviest leak")
    func mondayRotation() {
        let current = WeeklyFocus(habit: .calcToQuiet, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(focus.habit == .blunderCheck)
        #expect(focus.reason == .scheduledRotation)
    }

    @Test("Monday keeps the habit when it is still the heaviest leak")
    func mondayKeepsLeader() {
        let current = WeeklyFocus(habit: .blunderCheck, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(focus.habit == .blunderCheck)
        #expect(focus.reason == .unchanged)
    }

    @Test("Anti-thrash: three non-improving weeks force a switch and double the drill quota")
    func forcedSwitchAfterFlatWeeks() {
        let current = WeeklyFocus(habit: .blunderCheck, reason: .scheduledRotation)
        let flat = FocusMetricTrend(
            weeksWithoutImprovement: 3,
            startValue: 4.0,
            currentValue: 3.9
        )
        #expect(flat.isFlat(tolerance: DomainTuning.default.focus.improvementTolerance))

        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: flat, now: wednesday, calendar: utcCalendar
        )
        // Switched to the number-two leak even though blunderCheck is still
        // number one — three weeks of advice that is not working is enough.
        #expect(focus.habit == .calcToQuiet)
        #expect(focus.reason == .forcedSwitchNoImprovement)
        #expect(focus.drillQuotaMultiplier == 2.0)
    }

    @Test("Two flat weeks are not yet enough to force a switch")
    func twoFlatWeeksIsNotEnough() {
        let current = WeeklyFocus(habit: .blunderCheck, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(weeksWithoutImprovement: 2, startValue: 4, currentValue: 3.9),
            now: wednesday, calendar: utcCalendar
        )
        #expect(focus.habit == .blunderCheck)
        #expect(focus.reason == .unchanged)
    }

    @Test("A habit cannot hold the slot for more than three consecutive weeks")
    func maximumWeeksCap() {
        let current = WeeklyFocus(habit: .blunderCheck, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 3,
            metricTrend: FocusMetricTrend(), now: wednesday, calendar: utcCalendar
        )
        #expect(focus.habit == .calcToQuiet)
        #expect(focus.reason == .maximumWeeksReached)
        // The cap is not a failure, so the drill quota is not doubled.
        #expect(focus.drillQuotaMultiplier == 1)
    }

    @Test("Clearing the micro-goal for five consecutive games rotates early")
    func earlyRotation() {
        let current = WeeklyFocus(habit: .blunderCheck, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(consecutiveGamesMeetingMicroGoal: 5),
            now: wednesday, calendar: utcCalendar
        )
        #expect(focus.habit == .calcToQuiet)
        #expect(focus.reason == .earlyRotationGoalCleared)

        // Four is not five.
        let notYet = FocusSelector.selectFocus(
            leaks: twoLeaks, rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(consecutiveGamesMeetingMicroGoal: 4),
            now: wednesday, calendar: utcCalendar
        )
        #expect(notYet.reason == .unchanged)
    }

    @Test("With no leaks at all the current focus is kept rather than reinvented")
    func noLeaks() {
        let current = WeeklyFocus(habit: .scanThreats, reason: .scheduledRotation)
        let focus = FocusSelector.selectFocus(
            leaks: [], rung: 1, currentFocus: current, weeksOnFocus: 1,
            metricTrend: FocusMetricTrend(), now: monday, calendar: utcCalendar
        )
        #expect(focus.habit == .scanThreats)
    }

    @Test("`isFlat` is relative, so it works for rates and percentages alike")
    func flatnessIsRelative() {
        #expect(FocusMetricTrend(startValue: 4.0, currentValue: 3.7).isFlat(tolerance: 0.10))
        #expect(!FocusMetricTrend(startValue: 4.0, currentValue: 3.5).isFlat(tolerance: 0.10))
        #expect(FocusMetricTrend(startValue: 0.55, currentValue: 0.58).isFlat(tolerance: 0.10))
        #expect(!FocusMetricTrend(startValue: 0.55, currentValue: 0.70).isFlat(tolerance: 0.10))
        #expect(FocusMetricTrend(startValue: 0, currentValue: 0).isFlat(tolerance: 0.10))
    }

    // MARK: - Drill mix

    @Test("Puzzle drills are split 60/40 between focus themes and everything else")
    func drillMix() {
        let focus = WeeklyFocus(habit: .blunderCheck)
        let mix = FocusSelector.drillMix(totalPuzzles: 10, focus: focus)
        #expect(mix.focusThemed == 6)
        #expect(mix.dueOrGeneral == 4)
        #expect(mix.total == 10)
    }

    @Test("A doubled quota raises the focus share but never starves the SRS deck")
    func drillMixWithDoubledQuota() {
        // 0.6 x 2.0 would claim the whole session, which is exactly the
        // starvation the split exists to prevent.
        let focus = WeeklyFocus(habit: .blunderCheck, drillQuotaMultiplier: 2.0)
        let mix = FocusSelector.drillMix(totalPuzzles: 10, focus: focus)
        #expect(mix.focusThemed == 8)
        #expect(mix.dueOrGeneral == 2)
    }

    @Test("With no focus every puzzle comes from the SRS deck and the general pool")
    func drillMixWithoutFocus() {
        let mix = FocusSelector.drillMix(totalPuzzles: 10, focus: nil)
        #expect(mix.focusThemed == 0)
        #expect(mix.dueOrGeneral == 10)
        #expect(FocusSelector.drillMix(totalPuzzles: 0, focus: nil).total == 0)
    }
}
