import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

@Suite("Curriculum ladder accordion")
struct CurriculumLadderStateTests {

    /// A two-rung ladder with a known mix of required and optional skills, so
    /// the fractions in these tests are readable at a glance.
    ///
    /// Real metric keys, not placeholders: the row's copy is derived from the
    /// key's presentation, so a ladder built on `m.a` would exercise only the
    /// unknown-key fallback and pin none of the strings a user actually reads.
    static func ladder() -> [Rung] {
        [
            Rung(
                id: 1,
                title: "Board Vision",
                ratingBand: 0...999,
                skills: [
                    Skill(
                        id: "a", title: "Stop hanging pieces",
                        metricKey: .hangingPiecePer100, window: .lastGames(8), threshold: 1.0,
                        comparison: .lessThan, isRequired: true, habit: .blunderCheck,
                        minimumSamples: 8
                    ),
                    Skill(
                        id: "b", title: "Clean retries",
                        metricKey: .cleanRetryRate, window: .lastGames(8), threshold: 0.55,
                        comparison: .greaterThanOrEqual, isRequired: true, habit: .whatChanged,
                        minimumSamples: 8
                    ),
                    Skill(
                        id: "c", title: "Sound openings",
                        metricKey: .openingCompositeRate, window: .lastGames(8), threshold: 0.7,
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
                        metricKey: .ignoredThreatPer100, window: .lastGames(8), threshold: 1.5,
                        comparison: .lessThan, isRequired: true,
                        minimumSamples: 8
                    )
                ]
            )
        ]
    }

    static func metrics() -> MetricSnapshot {
        var snapshot = MetricSnapshot()
        snapshot.set(0.8, samples: 12, for: .hangingPiecePer100, window: .lastGames(8))  // met (< 1.0)
        snapshot.set(0.40, samples: 12, for: .cleanRetryRate, window: .lastGames(8))     // unmet (< 0.55)
        // The opening composite is deliberately absent: unmeasured, not failed.
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
        // The quantity, its unit and the target — not a bare `0.8 / < 1.0`.
        #expect(met.measurement == "Hanging pieces 0.8 per 100 moves · need under 1.0")
        #expect(met.pending == nil)

        let failed = try #require(rung.skills.first { $0.id == "b" })
        #expect(!failed.isMet)
        // A failure shows the number that fell short, not an empty state.
        #expect(failed.measurement == "Clean retries 40% · need at least 55%")
        #expect(failed.pending == nil)

        let unmeasured = try #require(rung.skills.first { $0.id == "c" })
        #expect(!unmeasured.isMet)
        #expect(unmeasured.isUnmeasured)
        #expect(unmeasured.measurement == nil)
        #expect(unmeasured.pending?.count == 8)
        #expect(unmeasured.pending?.note == "Needs 8 more games")
        // Optional skills must be marked apart: they never gate advancement.
        #expect(!unmeasured.isRequired)
    }

    @Test("A value with too few samples is unmeasured, not failed")
    func belowMinimumSamplesIsUnmeasured() throws {
        var metrics = Self.metrics()
        metrics.set(0.9, samples: 3, for: .openingCompositeRate, window: .lastGames(8))
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: metrics, blockers: []
        )
        let skill = try #require(state.rung(1)?.skills.first { $0.id == "c" })
        #expect(skill.isUnmeasured)
        // 8 required, 3 observed.
        #expect(skill.pending?.count == 5)
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
        #expect(rung.completionSummary == "1/3")
        #expect(rung.requiredMetCount == 1)
        #expect(rung.requiredSkills.count == 2)
    }

    @Test("A rung with nothing measured under it says so instead of showing 0/n")
    func nothingMeasuredIsNotZero() throws {
        // The day-one shape for a player placed onto rung 3: the rungs beneath
        // are marked complete by position, and a tick beside "0/5" reads as
        // either a rendering fault or a claim about work never done.
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: MetricSnapshot(), blockers: []
        )
        let skipped = try #require(state.rung(1))
        #expect(skipped.status == .completed)
        #expect(skipped.completionFraction == "0/3")
        #expect(skipped.completionSummary == "Not measured")
    }

    @Test("A rung with a measured failure still reports its fraction")
    func decayedRungKeepsItsFraction() throws {
        // The other state the fraction exists for: earned, then decayed. It has
        // measurements behind it, so the number is meaningful and stays.
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: Self.metrics(), blockers: []
        )
        #expect(state.rung(1)?.completionSummary == "1/3")
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

    // MARK: - What an unmeasured row asks for

    @Test("A drill gate sends the user to the drill, not to another game")
    func drillGateNamesTheDrill() throws {
        let ladder = [
            Rung(
                id: 1, title: "Board Vision", ratingBand: 0...999,
                skills: [
                    Skill(
                        id: "mates", title: "Mate with the queen",
                        metricKey: .kqkDrillCleanStreak, window: .allTime, threshold: 2,
                        comparison: .greaterThanOrEqual, isRequired: true
                    )
                ]
            )
        ]
        let state = CurriculumLadderState(
            ladder: ladder, currentRung: 1, metrics: MetricSnapshot(), blockers: []
        )
        let skill = try #require(state.rung(1)?.skills.first)
        // Playing sparring games never writes a drill streak, so "Needs 1 more
        // game" was an instruction that could not work.
        #expect(skill.pending?.note == "Not run yet — a training set")
    }

    @Test("A puzzle-theme gate counts puzzles, and a critical-moment gate counts moments")
    func gatesCountWhatTheyMeasure() throws {
        let ladder = [
            Rung(
                id: 1, title: "Tactical Vision", ratingBand: 0...999,
                skills: [
                    Skill(
                        id: "themes", title: "Forks",
                        metricKey: .puzzleThemeSuccess(.fork, ratingFloor: 1200),
                        window: .allTime, threshold: 0.7,
                        comparison: .greaterThanOrEqual, isRequired: true,
                        minimumSamples: 15
                    ),
                    Skill(
                        id: "critical", title: "Hold the critical moments",
                        metricKey: .criticalMomentHitRate, window: .lastGames(12), threshold: 0.55,
                        comparison: .greaterThanOrEqual, isRequired: true,
                        minimumSamples: 25
                    )
                ]
            )
        ]
        let state = CurriculumLadderState(
            ladder: ladder, currentRung: 1, metrics: MetricSnapshot(), blockers: []
        )
        let rung = try #require(state.rung(1))
        #expect(
            rung.skills.first { $0.id == "themes" }?.pending?.note
                == "Needs 15 more puzzles rated 1200+"
        )
        #expect(
            rung.skills.first { $0.id == "critical" }?.pending?.note
                == "Needs 25 more critical moments"
        )
    }

    @Test("A count of one uses the singular noun")
    func singularNoun() {
        let pending = LadderSkillPending(
            count: 1, noun: "guided games", nounSingular: "guided game", source: nil
        )
        #expect(pending.note == "Needs 1 more guided game")
    }

    // MARK: - Criteria this build cannot measure

    @Test("An unmeasurable criterion is dropped rather than shown as pending forever")
    func unsupportedCriteriaAreDropped() throws {
        let ladder = [
            Rung(
                id: 4, title: "Conversion & Prophylaxis", ratingBand: 1800...2000,
                skills: [
                    Skill(
                        id: "r4.prophylaxis", title: "Stop ideas before they start",
                        criteria: [
                            SkillCriterion(
                                metricKey: .ignoredThreatPer100, window: .lastGames(12),
                                threshold: 0.7, comparison: .lessThan
                            ),
                            SkillCriterion(
                                metricKey: .prophylacticFindRate, window: .lastGames(12),
                                threshold: 0.45, comparison: .greaterThanOrEqual
                            )
                        ],
                        isRequired: false
                    ),
                    Skill(
                        id: "only.unsupported", title: "Nothing behind it",
                        metricKey: .prophylacticFindRate, window: .lastGames(12), threshold: 0.45,
                        comparison: .greaterThanOrEqual, isRequired: false
                    )
                ]
            )
        ]
        let trimmed = CurriculumLadderState.measurable(
            ladder, unsupported: MetricComputer.unsupportedMetrics
        )
        let rung = try #require(trimmed.first)
        // The skill keeps the half this build can measure and loses the half it
        // cannot; a skill with nothing left drops out entirely rather than
        // holding the rung's fraction below full forever.
        #expect(rung.skills.count == 1)
        let prophylaxis = try #require(rung.skills.first)
        #expect(prophylaxis.criteria.count == 1)
        #expect(prophylaxis.criteria.first?.metricKey == .ignoredThreatPer100)
    }

    @Test("A ladder with nothing unsupported is returned untouched")
    func measurableIsIdentityWhenNothingIsUnsupported() {
        let ladder = Self.ladder()
        #expect(CurriculumLadderState.measurable(ladder, unsupported: []) == ladder)
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
            "1 required skill",
            "4 more games",
            "5 more days here"
        ])
        // The list on its own never says what the conditions are conditions for.
        #expect(
            state.rung(1)?.blockerSummary
                == "To reach Rung 2: 1 required skill, 4 more games and 5 more days here."
        )
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
        #expect(state.rung(1)?.blockerMessages == ["2 required skills"])
        #expect(state.rung(1)?.blockerSummary == "To reach Rung 2: 2 required skills.")
    }

    /// Both required skills on rung 1 met, the optional one still unmeasured —
    /// the shape a user is in the moment they have earned the next rung.
    static func metricsClearingRung1() -> MetricSnapshot {
        var snapshot = MetricSnapshot()
        snapshot.set(0.8, samples: 12, for: .hangingPiecePer100, window: .lastGames(8))
        snapshot.set(0.70, samples: 12, for: .cleanRetryRate, window: .lastGames(8))
        return snapshot
    }

    @Test("A current rung with nothing outstanding says the promotion is waiting")
    func readyToAdvance() throws {
        // The one state the blocker slot never described: every gate cleared,
        // and promotion sitting on the Train tab waiting for a tap that the
        // ladder never mentioned.
        let state = CurriculumLadderState(
            ladder: Self.ladder(),
            currentRung: 1,
            metrics: Self.metricsClearingRung1(),
            blockers: []
        )
        let rung = try #require(state.rung(1))
        #expect(rung.isReadyToAdvance)
        #expect(rung.blockerMessages == ["Ready for Rung 2 — take it on Home"])
        // Not wrapped in "To reach Rung 2:" — it is already a whole sentence.
        #expect(rung.blockerSummary == "Ready for Rung 2 — take it on Home")
    }

    @Test("Completed and locked rungs never claim a promotion is waiting")
    func onlyTheCurrentRungIsReady() throws {
        // Every rung but the current one is built with an empty blocker list,
        // so an unguarded emptiness check would announce a promotion on all
        // four of them at once.
        var metrics = Self.metricsClearingRung1()
        metrics.set(0.9, samples: 12, for: .ignoredThreatPer100, window: .lastGames(8))
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: metrics, blockers: []
        )
        #expect(state.rung(1)?.isReadyToAdvance == false)
        #expect(state.rung(1)?.blockerSummary == nil)
        #expect(state.rung(2)?.isReadyToAdvance == true)
    }

    @Test("An unmeasured rung never claims a promotion, however empty its blocker list")
    func nothingMeasuredIsNotReady() throws {
        // The placeholder snapshot the Profile screen draws before its first
        // read lands carries no metrics and no blockers. Reading the blocker
        // list alone would congratulate a brand-new user on a rung they have
        // not started.
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 1, metrics: MetricSnapshot(), blockers: []
        )
        #expect(state.rung(1)?.isReadyToAdvance == false)
        #expect(state.rung(1)?.blockerSummary == nil)
    }

    @Test("The top rung says so rather than reporting a failure")
    func topRung() throws {
        let state = CurriculumLadderState(
            ladder: Self.ladder(), currentRung: 2, metrics: Self.metrics(), blockers: [.atTopRung]
        )
        #expect(state.rung(2)?.blockerMessages == ["Top rung — nothing above this yet"])
        // No "to reach Rung 3": there is no rung 3.
        #expect(state.rung(2)?.blockerSummary == "Top rung — nothing above this yet")
    }

    // MARK: - Multi-criterion skills

    @Test("A multi-criterion skill shows the criterion that is failing, named")
    func multiCriterionShowsFailure() {
        let skill = Skill(
            id: "multi",
            title: "Blunder control",
            criteria: [
                SkillCriterion(
                    metricKey: .blundersPer100, window: .allTime,
                    threshold: 4.0, comparison: .lessThan
                ),
                SkillCriterion(
                    metricKey: .cleanRetryRate, window: .allTime,
                    threshold: 0.55, comparison: .greaterThanOrEqual
                )
            ],
            isRequired: true
        )
        var metrics = MetricSnapshot()
        metrics.set(2.0, samples: 10, for: .blundersPer100, window: .allTime)   // passes
        metrics.set(0.30, samples: 10, for: .cleanRetryRate, window: .allTime)  // fails

        // Under a title naming neither conjunct, the row has to say which of the
        // two it is reporting.
        #expect(
            CurriculumLadderState.measurement(for: skill, in: metrics)
                == "Clean retries 30% · need at least 55%"
        )
    }
}
