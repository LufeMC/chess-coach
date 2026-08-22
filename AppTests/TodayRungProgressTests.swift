import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The bar on the Today rung card.
///
/// It is the only progress indicator on the screen the user opens first, so what
/// it does before anything has been measured matters more than what it does
/// afterwards: a bar that sits at 0% for a fortnight teaches the reader that it
/// is not worth watching, which is the opposite of what a daily-loop instrument
/// needs.
@Suite("Today rung progress")
struct TodayRungProgressTests {

    /// Every required skill on a rung, with none of its criteria measured —
    /// the state of a user who has just been placed there.
    private func unmeasured(rung: Int) -> [SkillEvaluation] {
        (Curriculum.rung(rung)?.requiredSkills ?? []).map { skill in
            SkillEvaluation(skillID: skill.id, isMet: false, unmeasuredCriteria: skill.criteria)
        }
    }

    private func state(rung: Int, evaluations: [SkillEvaluation]) -> CurriculumState {
        CurriculumState(
            rung: rung,
            snapshot: MetricSnapshot(),
            decision: AdvancementDecision(
                canAdvance: false,
                currentRung: rung,
                nextRung: nil,
                evaluations: evaluations,
                metSkillIDs: evaluations.filter(\.isMet).map(\.skillID),
                unmetSkillIDs: evaluations.filter { !$0.isMet }.map(\.skillID),
                blockers: [],
                // The figure the card used to draw straight onto the bar.
                requiredSkillProgress: 0
            )
        )
    }

    @Test("Nothing measured yet is not zero progress")
    func unmeasuredRungDrawsNoBar() {
        // Rung 2's required skills are all gated on played games and solved
        // puzzles, so "keep going" is a true and actionable note and the card
        // should show it rather than a confident 0% bar.
        #expect(TodayModel.skillProgress(for: state(rung: 2, evaluations: unmeasured(rung: 2))) == nil)
    }

    @Test("A rung gated on something playing cannot produce still shows its count")
    func drillGatedRungKeepsItsCount() throws {
        // Rung 1 requires the basic mates, measured only from endgame-drill
        // runs. "Measuring — a few more games" there is an instruction that does
        // not work: the user plays, nothing moves, and the ladder reads broken.
        let skills = try #require(TodayModel.skillProgress(for: state(rung: 1, evaluations: unmeasured(rung: 1))))
        #expect(skills.met == 0)
        #expect(skills.unmeasured == skills.total)
        #expect(skills.caption.contains("not measured yet"))
    }

    @Test("The caption separates skills that came up short from skills nobody looked at")
    func captionNamesTheUnmeasured() throws {
        var evaluations = unmeasured(rung: 2)
        evaluations[0] = SkillEvaluation(skillID: evaluations[0].skillID, isMet: true)

        let skills = try #require(TodayModel.skillProgress(for: state(rung: 2, evaluations: evaluations)))
        #expect(skills.met == 1)
        #expect(skills.total == evaluations.count)
        #expect(skills.unmeasured == evaluations.count - 1)
        #expect(skills.caption == "1 of 3 met · 2 not measured yet")
        // Still counted against the bar: an unmeasured skill is not a cleared
        // one, and a bar that skipped it would read as further along than the
        // rung actually is.
        #expect(abs(skills.fraction - 1.0 / 3.0) < 1e-12)
    }

    @Test("A cleared rung says so without a caveat")
    func clearedRungHasNoCaveat() throws {
        let evaluations = (Curriculum.rung(2)?.requiredSkills ?? []).map {
            SkillEvaluation(skillID: $0.id, isMet: true)
        }
        let skills = try #require(TodayModel.skillProgress(for: state(rung: 2, evaluations: evaluations)))
        #expect(skills.fraction == 1)
        #expect(skills.caption == "3 of 3 met")
    }
}
