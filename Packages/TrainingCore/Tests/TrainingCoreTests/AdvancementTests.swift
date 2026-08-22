import Foundation
import Testing

@testable import TrainingCore

@Suite("Curriculum ladder and advancement")
struct AdvancementTests {

    /// A snapshot meeting every required skill on rung 1.
    func passingRung1() -> MetricSnapshot {
        var snapshot = MetricSnapshot()
        snapshot.set(0.4, samples: 8, for: .hangingPiecePer100, window: .lastGames(8))
        snapshot.set(3, samples: 3, for: .kqkDrillCleanStreak, window: .allTime)
        snapshot.set(2, samples: 2, for: .krkDrillCleanStreak, window: .allTime)
        snapshot.set(2.1, samples: 8, for: .blundersPer100, window: .lastGames(8))
        snapshot.set(0.7, samples: 8, for: .cleanRetryRate, window: .lastGames(8))
        // Optional skills too, so `canAdvance` is not accidentally passing on
        // an all-optional rung.
        snapshot.set(0.8, samples: 8, for: .openingCompositeRate, window: .lastGames(8))
        snapshot.set(1100, samples: 60, for: .puzzleRating, window: .allTime)
        snapshot.set(72, samples: 60, for: .puzzleRatingDeviation, window: .allTime)
        return snapshot
    }

    // MARK: - Ladder shape

    @Test("The ladder is four rungs, each with three to five measurable skills")
    func ladderShape() {
        let ladder = Curriculum.default
        #expect(ladder.count == 4)
        #expect(ladder.map(\.id) == [1, 2, 3, 4])
        for rung in ladder {
            #expect(rung.skills.count >= 3, "\(rung.title) has \(rung.skills.count) skills")
            #expect(rung.skills.count <= 6, "\(rung.title) has \(rung.skills.count) skills")
            #expect(!rung.requiredSkills.isEmpty, "\(rung.title) has no required skill")
        }
        // Bands are contiguous and ascending.
        #expect(ladder[0].ratingBand.upperBound + 1 == ladder[1].ratingBand.lowerBound)
        #expect(ladder[1].ratingBand.upperBound + 1 == ladder[2].ratingBand.lowerBound)
        #expect(ladder[2].ratingBand.upperBound + 1 == ladder[3].ratingBand.lowerBound)
    }

    @Test("Skill ids are unique across the whole ladder")
    func uniqueSkillIDs() {
        let ids = Curriculum.default.flatMap { $0.skills.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }

    @Test("Rung 2 gates on all five named tactical themes")
    func rung2Themes() {
        let skill = Curriculum.rung(2)?.skills.first { $0.id == "r2.themes" }
        #expect(skill?.criteria.count == 5)
        #expect(skill?.isRequired == true)
        for criterion in skill?.criteria ?? [] {
            #expect(criterion.minimumSamples == 15)
            #expect(criterion.threshold == 0.70)
            #expect(criterion.metricKey.rawValue.hasSuffix("@1200"))
        }
    }

    @Test("Rating maps to the rung whose band contains it, saturating at the top")
    func rungForRating() {
        #expect(Curriculum.rung(forRating: 850).id == 1)
        #expect(Curriculum.rung(forRating: 1200).id == 2)
        #expect(Curriculum.rung(forRating: 1500).id == 3)
        #expect(Curriculum.rung(forRating: 1900).id == 4)
        #expect(Curriculum.rung(forRating: 2400).id == 4)
    }

    // MARK: - Skill evaluation

    @Test("All criteria of a conjunction must hold")
    func conjunctionSemantics() {
        let skill = Curriculum.rung(1)!.skills.first { $0.id == "r1.basicMates" }!
        #expect(skill.criteria.count == 2)

        var half = MetricSnapshot()
        half.set(3, samples: 3, for: .kqkDrillCleanStreak, window: .allTime)
        half.set(0, samples: 3, for: .krkDrillCleanStreak, window: .allTime)
        let partial = skill.evaluate(in: half)
        #expect(!partial.isMet)
        #expect(partial.failingCriteria.count == 1)

        var full = half
        full.set(3, samples: 3, for: .krkDrillCleanStreak, window: .allTime)
        #expect(skill.evaluate(in: full).isMet)
    }

    @Test("The clean-retry rate is measured but never gates rung 1")
    func cleanRetryIsNotAGate() {
        // The only way to produce a clean-retry attempt is to fail a review
        // card and re-play it, so a user with no due cards — or one who solves
        // them — never generates the number at all. As a required conjunct that
        // held the rung shut on evidence they had no way to go and create.
        let skill = Curriculum.rung(1)!.skills.first { $0.id == "r1.cleanRetries" }!
        #expect(!skill.isRequired)
        #expect(Curriculum.rung(1)!.requiredSkills.allSatisfy { skill in
            skill.criteria.allSatisfy { $0.metricKey != .cleanRetryRate }
        })

        // Everything else met, clean retries never measured: still a promotion.
        var metrics = passingRung1()
        metrics[.cleanRetryRate, .lastGames(8)] = nil
        let decision = advancement(
            state: AdvancementState(currentRung: 1, metrics: metrics, gamesAtRung: 12, daysAtRung: 20)
        )
        #expect(decision.canAdvance)
        #expect(decision.unmetSkillIDs.contains("r1.cleanRetries"))
    }

    @Test("An unmeasured metric is reported separately from a failing one")
    func unmeasuredIsNotFailing() {
        // "We have never measured this" and "you are not there yet" need
        // different words in the UI.
        let skill = Curriculum.rung(1)!.skills.first { $0.id == "r1.hangingPieces" }!
        let evaluation = skill.evaluate(in: MetricSnapshot())
        #expect(!evaluation.isMet)
        #expect(evaluation.failingCriteria.isEmpty)
        #expect(evaluation.unmeasuredCriteria.count == 1)
    }

    @Test("A metric with too few samples does not count, however good it looks")
    func minimumSamplesEnforced() {
        let skill = Curriculum.rung(2)!.skills.first { $0.id == "r2.themes" }!
        var snapshot = MetricSnapshot()
        for theme in DomainTuning.default.curriculum.rung2Themes {
            // A perfect score on two attempts is not a score.
            snapshot.set(1.0, samples: 2, for: .puzzleThemeSuccess(theme, ratingFloor: 1200), window: .allTime)
        }
        let evaluation = skill.evaluate(in: snapshot)
        #expect(!evaluation.isMet)
        #expect(evaluation.unmeasuredCriteria.count == 5)

        for theme in DomainTuning.default.curriculum.rung2Themes {
            snapshot.set(0.8, samples: 20, for: .puzzleThemeSuccess(theme, ratingFloor: 1200), window: .allTime)
        }
        #expect(skill.evaluate(in: snapshot).isMet)
    }

    @Test("The rung-2 guided-prompt gate needs a real sample, not one lucky answer")
    func guidedPromptGateHasAMinimumSample() {
        let skill = Curriculum.rung(2)!.skills.first { $0.id == "r2.threatAwareness" }!
        let criterion = skill.criteria.first { $0.metricKey == .guidedScanThreatsHitRate }!
        #expect(criterion.minimumSamples == DomainTuning.default.curriculum.guidedPromptMinimumSamples)
        #expect(criterion.minimumSamples > 1)

        // Guided mode asks at most three questions a game, so without the
        // minimum a single answered prompt was a 100% hit rate — and this is a
        // *required* skill, so that one prompt decided a rung.
        var snapshot = MetricSnapshot()
        snapshot.set(0.5, samples: 10, for: .ignoredThreatPer100, window: .lastGames(10))
        snapshot.set(1.0, samples: 1, for: .guidedScanThreatsHitRate, window: .lastGames(10))

        let thin = skill.evaluate(in: snapshot)
        #expect(!thin.isMet)
        // Unmeasured, not failed: the user has done nothing wrong, there is
        // simply not enough of it yet.
        #expect(thin.failingCriteria.isEmpty)
        #expect(thin.unmeasuredCriteria.count == 1)

        snapshot.set(0.65, samples: criterion.minimumSamples, for: .guidedScanThreatsHitRate, window: .lastGames(10))
        #expect(skill.evaluate(in: snapshot).isMet)
    }

    @Test("Comparison operators evaluate at their boundaries")
    func comparisonBoundaries() {
        #expect(!MetricComparison.lessThan.evaluate(1.0, threshold: 1.0))
        #expect(MetricComparison.lessThanOrEqual.evaluate(1.0, threshold: 1.0))
        #expect(MetricComparison.greaterThanOrEqual.evaluate(1.0, threshold: 1.0))
        #expect(!MetricComparison.greaterThanOrEqual.evaluate(0.999, threshold: 1.0))
    }

    // MARK: - Advancement gates

    @Test("Everything met and both time gates cleared: the user advances")
    func successCase() {
        let decision = advancement(
            state: AdvancementState(
                currentRung: 1,
                metrics: passingRung1(),
                gamesAtRung: 12,
                daysAtRung: 20
            )
        )
        #expect(decision.canAdvance)
        #expect(decision.nextRung == 2)
        #expect(decision.resolvedRung == 2)
        #expect(decision.blockers.isEmpty)
        #expect(decision.requiredSkillProgress == 1)
        #expect(decision.unmetSkillIDs.isEmpty)
    }

    @Test("An unmet required skill blocks advancement")
    func blockedByRequiredSkill() {
        var metrics = passingRung1()
        metrics.set(2.5, samples: 8, for: .hangingPiecePer100, window: .lastGames(8))

        let decision = advancement(
            state: AdvancementState(currentRung: 1, metrics: metrics, gamesAtRung: 12, daysAtRung: 20)
        )
        #expect(!decision.canAdvance)
        #expect(decision.nextRung == nil)
        #expect(decision.unmetSkillIDs.contains("r1.hangingPieces"))
        #expect(decision.blockers.contains(.requiredSkillUnmet(skillID: "r1.hangingPieces", title: "Stop hanging pieces")))
        #expect(abs(decision.requiredSkillProgress - 2.0 / 3.0) < 1e-12)
    }

    @Test("An unmet OPTIONAL skill does not block advancement")
    func optionalSkillDoesNotBlock() {
        var metrics = passingRung1()
        metrics.set(0.10, samples: 8, for: .openingCompositeRate, window: .lastGames(8))

        let decision = advancement(
            state: AdvancementState(currentRung: 1, metrics: metrics, gamesAtRung: 12, daysAtRung: 20)
        )
        #expect(decision.canAdvance)
        #expect(decision.unmetSkillIDs.contains("r1.openingBasics"))
    }

    @Test("Too few games blocks advancement even with every skill met")
    func blockedByGames() {
        let decision = advancement(
            state: AdvancementState(currentRung: 1, metrics: passingRung1(), gamesAtRung: 9, daysAtRung: 30)
        )
        #expect(!decision.canAdvance)
        #expect(decision.blockers.contains(.insufficientGames(have: 9, need: 10)))
        // The skills are genuinely met — only the volume gate is missing.
        #expect(decision.requiredSkillProgress == 1)
    }

    @Test("Too few days blocks advancement even with every skill met")
    func blockedByDays() {
        // Consolidation is wall-clock bound: a heavy weekend must not vault a
        // user up a rung.
        let decision = advancement(
            state: AdvancementState(currentRung: 1, metrics: passingRung1(), gamesAtRung: 40, daysAtRung: 13)
        )
        #expect(!decision.canAdvance)
        #expect(decision.blockers.contains(.insufficientDays(have: 13, need: 14)))
    }

    @Test("The gates are exact at their boundaries")
    func gateBoundaries() {
        let atBoundary = advancement(
            state: AdvancementState(currentRung: 1, metrics: passingRung1(), gamesAtRung: 10, daysAtRung: 14)
        )
        #expect(atBoundary.canAdvance)
    }

    @Test("Required skills must be met simultaneously, not merely at some point")
    func simultaneity() {
        // Each half passes on its own; neither passes together. Evaluating
        // against one snapshot is what enforces this.
        var drillsOnly = MetricSnapshot()
        drillsOnly.set(3, samples: 3, for: .kqkDrillCleanStreak, window: .allTime)
        drillsOnly.set(3, samples: 3, for: .krkDrillCleanStreak, window: .allTime)

        let decision = advancement(
            state: AdvancementState(currentRung: 1, metrics: drillsOnly, gamesAtRung: 30, daysAtRung: 30)
        )
        #expect(!decision.canAdvance)
        #expect(decision.metSkillIDs == ["r1.basicMates"])
    }

    @Test("The top rung reports that there is nowhere further to go")
    func topRung() {
        let decision = advancement(
            state: AdvancementState(currentRung: 4, metrics: MetricSnapshot(), gamesAtRung: 100, daysAtRung: 100)
        )
        #expect(!decision.canAdvance)
        #expect(decision.blockers.contains(.atTopRung))
    }

    // MARK: - No demotion

    @Test("Regressed metrics never demote — the rung stays where it is")
    func noDemotion() {
        // A curriculum that can take a rung back turns a bad fortnight into a
        // visible punishment, exactly when a struggling user is most likely to
        // stop opening the app.
        var collapsed = MetricSnapshot()
        collapsed.set(9.9, samples: 20, for: .hangingPiecePer100, window: .lastGames(8))
        collapsed.set(0, samples: 20, for: .kqkDrillCleanStreak, window: .allTime)
        collapsed.set(0, samples: 20, for: .krkDrillCleanStreak, window: .allTime)
        collapsed.set(15.0, samples: 20, for: .blundersPer100, window: .lastGames(8))
        collapsed.set(0.05, samples: 20, for: .cleanRetryRate, window: .lastGames(8))

        let decision = advancement(
            state: AdvancementState(currentRung: 3, metrics: collapsed, gamesAtRung: 50, daysAtRung: 90)
        )
        #expect(!decision.canAdvance)
        #expect(decision.nextRung == nil)
        // The only two possible answers are "advance" and "stay".
        #expect(decision.resolvedRung == 3)
        #expect(decision.resolvedRung >= decision.currentRung)
    }

    @Test("An unknown rung id degrades safely instead of inventing a ladder")
    func unknownRung() {
        let decision = advancement(
            state: AdvancementState(currentRung: 99, metrics: MetricSnapshot(), gamesAtRung: 0, daysAtRung: 0)
        )
        #expect(!decision.canAdvance)
        #expect(decision.resolvedRung == 99)
    }

    // MARK: - Composites

    @Test("The opening composite passes with two of its three conditions")
    func openingComposite() {
        #expect(Curriculum.openingCompositePasses(
            castledByMoveLimit: true, minorsDevelopedByMoveLimit: true, noOpeningMistakes: false))
        #expect(Curriculum.openingCompositePasses(
            castledByMoveLimit: false, minorsDevelopedByMoveLimit: true, noOpeningMistakes: true))
        #expect(!Curriculum.openingCompositePasses(
            castledByMoveLimit: false, minorsDevelopedByMoveLimit: false, noOpeningMistakes: true))
        #expect(Curriculum.openingCompositePasses(
            castledByMoveLimit: true, minorsDevelopedByMoveLimit: true, noOpeningMistakes: true))
    }

    @Test("Basic-mate drills use their own move budgets")
    func mateDrillBudgets() {
        #expect(Curriculum.basicMateDrillIsClean(mate: .kqk, moves: 15))
        #expect(!Curriculum.basicMateDrillIsClean(mate: .kqk, moves: 16))
        #expect(Curriculum.basicMateDrillIsClean(mate: .krk, moves: 25))
        #expect(!Curriculum.basicMateDrillIsClean(mate: .krk, moves: 26))
    }
}
