//
//  Advancement.swift
//  TrainingCore
//

import Foundation

/// Everything advancement is decided from.
public struct AdvancementState: Sendable, Hashable {

    /// The rung the user is currently on, 1-based.
    public var currentRung: Int

    /// Measured skill metrics.
    public var metrics: MetricSnapshot

    /// Games played since arriving at this rung.
    public var gamesAtRung: Int

    /// Whole days since arriving at this rung.
    public var daysAtRung: Int

    public init(currentRung: Int, metrics: MetricSnapshot, gamesAtRung: Int, daysAtRung: Int) {
        self.currentRung = currentRung
        self.metrics = metrics
        self.gamesAtRung = gamesAtRung
        self.daysAtRung = daysAtRung
    }
}

/// A reason the user is not advancing.
public enum AdvancementBlocker: Sendable, Hashable {
    case requiredSkillUnmet(skillID: String, title: String)
    case insufficientGames(have: Int, need: Int)
    case insufficientDays(have: Int, need: Int)
    /// Already on the last rung. Not a failure — there is simply nowhere to go.
    case atTopRung
}

/// The answer.
public struct AdvancementDecision: Sendable, Hashable {

    public var canAdvance: Bool

    public var currentRung: Int

    /// The rung the user moves to, or `nil` if they are staying put.
    public var nextRung: Int?

    /// Per-skill detail, in rung order, for the disclosure UI.
    public var evaluations: [SkillEvaluation]

    public var metSkillIDs: [String]
    public var unmetSkillIDs: [String]

    /// Everything standing in the way, in a stable order: skills first, then
    /// the time and volume gates.
    public var blockers: [AdvancementBlocker]

    /// Fraction of *required* skills met, for the progress ring. A rung with no
    /// required skills reports 1.
    public var requiredSkillProgress: Double

    /// The rung the user is on after this decision is applied. **Never lower
    /// than ``currentRung``.**
    public var resolvedRung: Int { nextRung ?? currentRung }

    public init(
        canAdvance: Bool,
        currentRung: Int,
        nextRung: Int?,
        evaluations: [SkillEvaluation],
        metSkillIDs: [String],
        unmetSkillIDs: [String],
        blockers: [AdvancementBlocker],
        requiredSkillProgress: Double
    ) {
        self.canAdvance = canAdvance
        self.currentRung = currentRung
        self.nextRung = nextRung
        self.evaluations = evaluations
        self.metSkillIDs = metSkillIDs
        self.unmetSkillIDs = unmetSkillIDs
        self.blockers = blockers
        self.requiredSkillProgress = requiredSkillProgress
    }
}

/// Decides whether the user advances a rung.
///
/// Three gates, all of which must pass **simultaneously**:
/// 1. every required skill on the current rung is met,
/// 2. at least ``DomainTuning/Curriculum/minimumGamesAtRung`` games played here,
/// 3. at least ``DomainTuning/Curriculum/minimumDaysAtRung`` days spent here.
///
/// "Simultaneously" is doing real work in gate 1. The metrics are all rolling
/// windows, so a user can meet each required skill at some point over a month
/// without ever meeting them all at once — which would mean advancing on the
/// strength of a skill that has since decayed. Evaluating them against a single
/// snapshot is what prevents that.
///
/// Gates 2 and 3 exist because metric gates alone are gameable and, more
/// importantly, because consolidation is wall-clock bound. Ten games stops a
/// three-game hot streak from promoting anyone; fourteen days stops a heavy
/// weekend from vaulting a user up two rungs into material they cannot play.
///
/// ## No demotion
///
/// This function can return "you advance" or "you stay". It has no third
/// answer. If the user's metrics regress after they reach a rung, they simply
/// stop advancing — the rung they earned is theirs.
///
/// That is a product decision, not an oversight. The ladder is the user's
/// record of what they have learned, and a curriculum that can take a rung back
/// converts a bad fortnight into a visible punishment, which is precisely when
/// a struggling user is most likely to stop opening the app. The rating already
/// moves down and that is honest enough. Skills that have decayed still show as
/// unmet inside the rung, so the information is not hidden — it just does not
/// come with a demotion attached.
public func advancement(
    state: AdvancementState,
    ladder: [Rung] = Curriculum.default,
    tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
) -> AdvancementDecision {

    guard let rung = ladder.first(where: { $0.id == state.currentRung }) else {
        // Unknown rung: report no progress rather than inventing a ladder.
        return AdvancementDecision(
            canAdvance: false,
            currentRung: state.currentRung,
            nextRung: nil,
            evaluations: [],
            metSkillIDs: [],
            unmetSkillIDs: [],
            blockers: [.atTopRung],
            requiredSkillProgress: 0
        )
    }

    let evaluations = rung.skills.map { $0.evaluate(in: state.metrics) }
    let metIDs = evaluations.filter(\.isMet).map(\.skillID)
    let unmetIDs = evaluations.filter { !$0.isMet }.map(\.skillID)

    var blockers: [AdvancementBlocker] = []

    let requiredSkills = rung.requiredSkills
    var requiredMet = 0
    for skill in requiredSkills {
        guard let evaluation = evaluations.first(where: { $0.skillID == skill.id }) else { continue }
        if evaluation.isMet {
            requiredMet += 1
        } else {
            blockers.append(.requiredSkillUnmet(skillID: skill.id, title: skill.title))
        }
    }

    if state.gamesAtRung < tuning.minimumGamesAtRung {
        blockers.append(.insufficientGames(have: state.gamesAtRung, need: tuning.minimumGamesAtRung))
    }
    if state.daysAtRung < tuning.minimumDaysAtRung {
        blockers.append(.insufficientDays(have: state.daysAtRung, need: tuning.minimumDaysAtRung))
    }

    let isTopRung = !ladder.contains { $0.id == state.currentRung + 1 }
    if isTopRung {
        blockers.append(.atTopRung)
    }

    let progress = requiredSkills.isEmpty ? 1 : Double(requiredMet) / Double(requiredSkills.count)
    let canAdvance = blockers.isEmpty

    return AdvancementDecision(
        canAdvance: canAdvance,
        currentRung: state.currentRung,
        nextRung: canAdvance ? state.currentRung + 1 : nil,
        evaluations: evaluations,
        metSkillIDs: metIDs,
        unmetSkillIDs: unmetIDs,
        blockers: blockers,
        requiredSkillProgress: progress
    )
}
