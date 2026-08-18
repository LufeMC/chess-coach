import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

@Suite("Curriculum ladder accordion")
struct CurriculumLadderStateTests {

    /// A two-rung ladder with a known mix of required and optional skills, so
    /// the fractions in these tests are readable at a glance.
    static func ladder() -> [Rung] {
        [
            Rung(
                id: 1,
                title: "Board Vision",
                ratingBand: 0...999,
                skills: [
                    Skill(
                        id: "a", title: "Stop hanging pieces",
                        metricKey: "m.a", window: .lastGames(8), threshold: 1.0,
                        comparison: .lessThan, isRequired: true, habit: .blunderCheck,
                        minimumSamples: 8
                    ),
                    Skill(
                        id: "b", title: "Clean retries",
                        metricKey: "m.b", window: .lastGames(8), threshold: 0.55,
                        comparison: .greaterThanOrEqual, isRequired: true, habit: .whatChanged,
                        minimumSamples: 8
                    ),
                    Skill(
                        id: "c", title: "Sound openings",
                        metricKey: "m.c", window: .lastGames(8), threshold: 0.7,
                        comparison: .greaterThanOrEqual, isRequired: false, habit: .candidatesFirst,
                        minimumSamples: 8
                    )
                ]
            ),
            Rung(
                id: 2,
                title: "Tactical Vision",
                ratingBand: 1000...1399,
                skills: [
                    Skill(
                        id: "d", title: "See the threats",
                        metricKey: "m.d", window: .lastGames(8), threshold: 0.6,
                        comparison: .greaterThanOrEqual, isRequired: true,
                        minimumSamples: 8
                    )
                ]
            )
        ]
    }

    static func metrics() -> MetricSnapshot {
        var snapshot = MetricSnapshot()
        snapshot.set(0.8, samples: 12, for: "m.a", window: .lastGames(8))   // met (< 1.0)
        snapshot.set(0.40, samples: 12, for: "m.b", window: .lastGames(8))  // unmet (< 0.55)
        // "m.c" deliberately absent: unmeasured, not failed.
        return snapshot
    }

    // MARK: - Expansion

    @Test("Opens on the rung the user is on")
    func opensOnCurrentRung() {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: Self.metrics(), blockers: []
        )
        #expect(state.expandedRungID == 2)
        #expect(state.isExpanded(2))
        #expect(!state.isExpanded(1))
    }

    @Test("Exactly one section is open at a time")
    func onlyOneOpen() {
        var state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: Self.metrics(), blockers: []
        )
        state.toggle(2)
        #expect(state.expandedRungID == 2)
        #expect(!state.isExpanded(1))
        #expect(state.rungs.filter { state.isExpanded($0.id) }.count == 1)
    }

    @Test("Re-tapping the open header collapses it")
    func collapseOnRetap() {
        var state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: Self.metrics(), blockers: []
        )
        state.toggle(1)
        #expect(state.expandedRungID == nil)
        state.toggle(1)
        #expect(state.expandedRungID == 1)
    }

    // MARK: - Status

    @Test("Rungs below the current one are completed, above are locked")
    func statuses() {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: Self.metrics(), blockers: []
        )
        #expect(state.rung(1)?.status == .completed)
        #expect(state.rung(2)?.status == .current)
    }

    @Test("Only the current rung carries blockers")
    func blockersOnCurrentOnly() {
        let state = CurriculumLadderState(
            ladder: Self.ladder(),
            currentRung: 1,
            metrics: Self.metrics(),
            blockers: [.insufficientGames(have: 6, need: 10)]
        )
        #expect(state.rung(1)?.blockers.count == 1)
        #expect(state.rung(2)?.blockers.isEmpty == true)
    }

    // MARK: - Skill evaluation and the collapsed fraction

    @Test("Met, failed and unmeasured skills are told apart")
    func skillEvaluation() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: Self.metrics(), blockers: []
        )
        let rung = try #require(state.rung(1))

        let met = try #require(rung.skills.first { $0.id == "a" })
        #expect(met.isMet)
        #expect(met.isRequired)
        #expect(met.measurement == "0.8 / < 1.0")
        #expect(met.samplesNeeded == nil)

        let failed = try #require(rung.skills.first { $0.id == "b" })
        #expect(!failed.isMet)
        // A failure shows the number that fell short, not an empty state.
        #expect(failed.measurement == "0.4 / ≥ 0.55")
        #expect(failed.samplesNeeded == nil)

        let unmeasured = try #require(rung.skills.first { $0.id == "c" })
        #expect(!unmeasured.isMet)
        #expect(unmeasured.isUnmeasured)
        #expect(unmeasured.measurement == nil)
        #expect(unmeasured.samplesNeeded == 8)
        // Optional skills must be marked apart: they never gate advancement.
        #expect(!unmeasured.isRequired)
    }

    @Test("A value with too few samples is unmeasured, not failed")
    func belowMinimumSamplesIsUnmeasured() throws {
        var metrics = Self.metrics()
        metrics.set(0.9, samples: 3, for: "m.c", window: .lastGames(8))
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: metrics, blockers: []
        )
        let skill = try #require(state.rung(1)?.skills.first { $0.id == "c" })
        #expect(skill.isUnmeasured)
        // 8 required, 3 observed.
        #expect(skill.samplesNeeded == 5)
    }

    @Test("Collapsed header fraction counts met skills over all skills")
    func completionFraction() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: Self.metrics(), blockers: []
        )
        let rung = try #require(state.rung(1))
        #expect(rung.metCount == 1)
        #expect(rung.totalCount == 3)
        #expect(rung.completionFraction == "1/3")
        #expect(rung.requiredMetCount == 1)
        #expect(rung.requiredSkills.count == 2)
    }

    @Test("A locked rung with no data reads as zero of its skills")
    func lockedRungFraction() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: Self.metrics(), blockers: []
        )
        let locked = try #require(state.rung(2))
        #expect(locked.status == .locked)
        #expect(locked.completionFraction == "0/1")
    }

    // MARK: - Blocker copy

    @Test("Blockers read as plain sentences")
    func blockerMessages() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(),
            currentRung: 1,
            metrics: Self.metrics(),
            blockers: [
                .requiredSkillUnmet(skillID: "b", title: "Clean retries"),
                .insufficientGames(have: 6, need: 10),
                .insufficientDays(have: 9, need: 14)
            ]
        )
        let messages = try #require(state.rung(1)?.blockerMessages)
        #expect(messages == [
            "1 required skill to go",
            "4 more games at this rung",
            "5 more days at this rung"
        ])
    }

    @Test("Several unmet required skills collapse into one line")
    func blockerMessagesFoldRequiredSkills() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(),
            currentRung: 1,
            metrics: Self.metrics(),
            blockers: [
                .requiredSkillUnmet(skillID: "a", title: "A"),
                .requiredSkillUnmet(skillID: "b", title: "B")
            ]
        )
        #expect(state.rung(1)?.blockerMessages == ["2 required skills to go"])
    }

    @Test("The top rung says so rather than reporting a failure")
    func topRung() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: Self.metrics(), blockers: [.atTopRung]
        )
        #expect(state.rung(2)?.blockerMessages == ["Top rung — nothing above this yet"])
    }

    // MARK: - Multi-criterion skills

    @Test("A multi-criterion skill shows the criterion that is failing")
    func multiCriterionShowsFailure() {
        let skill = Skill(
            id: "multi",
            title: "Two things at once",
            criteria: [
                SkillCriterion(metricKey: "m.x", window: .allTime, threshold: 4.0, comparison: .lessThan),
                SkillCriterion(metricKey: "m.y", window: .allTime, threshold: 0.55, comparison: .greaterThanOrEqual)
            ],
            isRequired: true
        )
        var metrics = MetricSnapshot()
        metrics.set(2.0, samples: 10, for: "m.x", window: .allTime)   // passes
        metrics.set(0.30, samples: 10, for: "m.y", window: .allTime)  // fails

        #expect(CurriculumLadderState.measurement(for: skill, in: metrics) == "0.3 / ≥ 0.55")
    }
}
