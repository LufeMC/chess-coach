//
//  CurriculumDeadEndTests.swift
//  ChessCoachTests
//

import AnalysisKit
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The curriculum must never require something the app cannot let you practise.
///
/// Three separate dead ends were found by tracing every rung criterion to the
/// thing that writes its metric and then to the gate that lets that thing
/// happen. They share a shape: the ladder asks for evidence, and some *other*
/// system — a rating floor, a CTA condition, a cause-tag map — quietly refuses
/// to produce it. None of them is visible as a failure; the row simply never
/// ticks, and the user has no way to know which door is shut.
@Suite("Curriculum dead ends")
struct CurriculumDeadEndTests {

    /// A decision carrying one evaluation, with the rest at their defaults.
    static func decision(with evaluation: SkillEvaluation) -> AdvancementDecision {
        AdvancementDecision(
            canAdvance: false,
            currentRung: 2,
            nextRung: 3,
            evaluations: [evaluation],
            metSkillIDs: [],
            unmetSkillIDs: [evaluation.skillID],
            blockers: [],
            requiredSkillProgress: 0
        )
    }

    // MARK: The coached-game door

    /// `guided.scanThreats.hitRate` has exactly one producer: a guided prompt
    /// that fired and was answered. The CTA that offers a coached game used to
    /// appear only while the criterion was *unmeasured*, so a user practising
    /// badly lost the door at the moment it started mattering.
    @Test("A failing guided metric still offers the coached game that measures it")
    func failingGuidedMetricKeepsItsDoor() {
        let failing = SkillEvaluation(
            skillID: "r2.threatAwareness",
            isMet: false,
            failingCriteria: [
                SkillCriterion(
                    metricKey: .guidedScanThreatsHitRate,
                    window: .lastGames(10),
                    threshold: 0.6,
                    comparison: .greaterThanOrEqual,
                    minimumSamples: 8
                )
            ]
        )
        let state = CurriculumState(
            rung: 2,
            snapshot: MetricSnapshot(),
            decision: Self.decision(with: failing)
        )

        #expect(
            TodayModel.guidedGate(for: state) == .scanThreats,
            """
            A user below the hit-rate bar is failing the one required criterion whose only \
            producer is a coached game. Withholding the coached game leaves them failing it forever.
            """
        )
    }

    @Test("An unmeasured guided metric offers it too")
    func unmeasuredGuidedMetricOffersTheDoor() {
        let unmeasured = SkillEvaluation(
            skillID: "r2.threatAwareness",
            isMet: false,
            unmeasuredCriteria: [
                SkillCriterion(
                    metricKey: .guidedScanThreatsHitRate,
                    window: .lastGames(10),
                    threshold: 0.6,
                    comparison: .greaterThanOrEqual,
                    minimumSamples: 8
                )
            ]
        )
        let state = CurriculumState(
            rung: 2,
            snapshot: MetricSnapshot(),
            decision: Self.decision(with: unmeasured)
        )
        #expect(TodayModel.guidedGate(for: state) == .scanThreats)
    }

    /// The gate stays narrow. Anything a sparring game or a drill can move must
    /// not open a second CTA competing with the daily loop.
    @Test("A metric an ordinary game can move does not open the coached-game door")
    func ordinaryMetricsDoNotOpenIt() {
        #expect(TodayModel.guidedHabit(for: .guidedScanThreatsHitRate) == .scanThreats)
        #expect(TodayModel.guidedHabit(for: .blundersPer100) == nil)
        #expect(TodayModel.guidedHabit(for: .kqkDrillCleanStreak) == nil)
    }

    // MARK: The weekly focus

    /// `CauseTag.habit(rung:)` maps the detectors' tags onto six habits, so
    /// three of the nine can never be nominated by a leak. A rung whose required
    /// skill names one of those three had no way to point a week at it.
    @Test("Habits no cause tag can nominate are identified, not assumed")
    func unbackedHabitsAreKnown() {
        #expect(!Habit.hasCauseTag(.convertCleanly))
        #expect(!Habit.hasCauseTag(.clockDiscipline))
        // The ones the detectors do produce.
        #expect(Habit.hasCauseTag(.blunderCheck))
        #expect(Habit.hasCauseTag(.scanThreats))
        #expect(Habit.hasCauseTag(.calcToQuiet))
        #expect(Habit.hasCauseTag(.candidatesFirst))
        #expect(Habit.hasCauseTag(.whatChanged))
        #expect(Habit.hasCauseTag(.endgameTechnique))
    }

    /// The bug: rung 4 requires `r4.conversion` with `habit: .convertCleanly`,
    /// and every focus candidate was built from a leak, so it could not be
    /// chosen — the app required a skill and had no way to aim a week at it.
    @Test("A rung's own habit can become the focus even when no leak nominates it")
    func rungHabitsAreReachableAsFocus() {
        let focus = FocusSelector.selectFocus(
            leaks: [],
            rung: 4,
            currentFocus: nil,
            weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(weeksWithoutImprovement: 0, consecutiveGamesMeetingMicroGoal: 0)
        )
        // It used to fall through to the blunder-check default, which is a
        // rung-1 habit and measures nothing rung 4 asks for.
        #expect(focus.habit == .convertCleanly || focus.habit == .clockDiscipline)
        #expect(!Habit.hasCauseTag(focus.habit))
    }

    /// And they rank last, so a real measured leak always outranks them.
    @Test("A measured leak still outranks a habit nobody has evidence for")
    func measuredLeaksOutrankSeededHabits() {
        let focus = FocusSelector.selectFocus(
            leaks: [
                Leak(
                    causeTag: .hungMovedPiece,
                    habit: .blunderCheck,
                    weightedEPLost: 2.4,
                    epLostPerGame: 0.4,
                    count: 6,
                    deltaVsPreviousWeek: 0
                )
            ],
            rung: 4,
            currentFocus: nil,
            weeksOnFocus: 0,
            metricTrend: FocusMetricTrend(weeksWithoutImprovement: 0, consecutiveGamesMeetingMicroGoal: 0)
        )
        #expect(focus.habit == .blunderCheck, "a measured leak outranks a seeded fallback")
    }
}
