//
//  CurriculumLadderState.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// Where a rung sits relative to the user.
enum LadderRungStatus: Sendable, Hashable {
    /// Below the current rung. Earned, and never taken back.
    case completed
    case current
    /// Above the current rung.
    case locked
}

/// One skill row inside an expanded rung.
struct LadderSkillRow: Sendable, Hashable, Identifiable {

    let id: String
    let title: String

    /// Required skills gate advancement; the rest are shown and celebrated but
    /// do not block. The distinction is marked in the UI because otherwise a
    /// user stares at an unmet optional skill wondering why it is holding them
    /// up, when it never was.
    let isRequired: Bool

    let isMet: Bool

    /// `0.8 / < 1.0` — the measured value against the threshold it is judged by.
    /// `nil` when nothing has been measured.
    let measurement: String?

    /// Observations still needed before the metric is trustworthy. Non-`nil`
    /// only for unmeasured criteria, and the reason the row says "3 more games
    /// to measure this" instead of rendering a zero that looks like failure.
    let samplesNeeded: Int?

    /// SF Symbol for the leading icon, chosen from the habit the skill trains
    /// so the ladder and the weekly focus speak the same visual language.
    let symbol: String

    var isUnmeasured: Bool { samplesNeeded != nil }
}

/// One accordion section.
struct LadderRungRow: Sendable, Hashable, Identifiable {

    let id: Int
    let title: String
    let ratingBand: ClosedRange<Int>
    let status: LadderRungStatus
    let skills: [LadderSkillRow]

    /// Blockers, on the current rung only. Empty elsewhere.
    let blockers: [AdvancementBlocker]

    var metCount: Int { skills.filter(\.isMet).count }
    var totalCount: Int { skills.count }

    /// The fraction on the collapsed header. A collapsed section that says only
    /// its name carries no information, and the whole point of collapsing the
    /// completed rungs is to keep the ladder short *without* going blank.
    var completionFraction: String { "\(metCount)/\(totalCount)" }

    var requiredSkills: [LadderSkillRow] { skills.filter(\.isRequired) }
    var requiredMetCount: Int { requiredSkills.filter(\.isMet).count }

    /// Plain-language blockers, in the order the domain reports them.
    ///
    /// Unmet *required skills* are folded into one line rather than repeated
    /// per skill: each of them is already an unmet row a few points below, and
    /// restating them here would make a rung with four unmet skills read as
    /// eight problems.
    var blockerMessages: [String] {
        var messages: [String] = []
        let unmetRequired = blockers.filter {
            if case .requiredSkillUnmet = $0 { return true }
            return false
        }.count
        if unmetRequired > 0 {
            messages.append(unmetRequired == 1
                ? "1 required skill to go"
                : "\(unmetRequired) required skills to go")
        }
        for blocker in blockers {
            switch blocker {
            case .insufficientGames(let have, let need):
                messages.append("\(need - have) more games at this rung")
            case .insufficientDays(let have, let need):
                messages.append("\(need - have) more days at this rung")
            case .atTopRung:
                messages.append("Top rung — nothing above this yet")
            case .requiredSkillUnmet:
                continue
            }
        }
        return messages
    }
}

/// The accordion.
///
/// ## Why an accordion and not a path
///
/// A winding-path level map spends a screen and a half encoding an ordering
/// that "RUNG 1, RUNG 2, RUNG 3" already carries, and it makes a training tool
/// look like a game. Four collapsed headers plus one open section fits above
/// the fold, and the collapsed headers still report their completion fraction —
/// so nothing is hidden, it is just not shouting.
struct CurriculumLadderState: Sendable, Hashable {

    private(set) var rungs: [LadderRungRow]

    /// The one open section. Optional because tapping the open header closes
    /// it, and a fully collapsed ladder is a legitimate state — it is the
    /// four-line overview.
    private(set) var expandedRungID: Int?

    init(rungs: [LadderRungRow], expandedRungID: Int?) {
        self.rungs = rungs
        self.expandedRungID = expandedRungID
    }

    /// Builds the ladder for the user's current position.
    ///
    /// Every rung is evaluated against the same snapshot, including the ones
    /// already completed. That can show a completed rung at `3/5`, and it is
    /// deliberate: the metrics are rolling windows, the curriculum never demotes
    /// anyone, and a skill that has decayed should say so rather than sit behind
    /// a permanent tick.
    init(
        ladder: [Rung],
        currentRung: Int,
        metrics: MetricSnapshot,
        blockers: [AdvancementBlocker]
    ) {
        let rows = ladder.map { rung -> LadderRungRow in
            let status: LadderRungStatus =
                rung.id < currentRung ? .completed
                : rung.id == currentRung ? .current
                : .locked

            let skills = rung.skills.map { skill -> LadderSkillRow in
                let evaluation = skill.evaluate(in: metrics)
                return LadderSkillRow(
                    id: skill.id,
                    title: skill.title,
                    isRequired: skill.isRequired,
                    isMet: evaluation.isMet,
                    measurement: Self.measurement(for: skill, in: metrics),
                    samplesNeeded: Self.samplesNeeded(for: evaluation, in: metrics),
                    symbol: Self.symbol(for: skill.habit)
                )
            }

            return LadderRungRow(
                id: rung.id,
                title: rung.title,
                ratingBand: rung.ratingBand,
                status: status,
                skills: skills,
                blockers: status == .current ? blockers : []
            )
        }

        // Open on the rung the user is actually on. Completed rungs are
        // reference material; locked ones are a preview.
        self.init(rungs: rows, expandedRungID: currentRung)
    }

    /// Opens a section, closing whatever was open; re-tapping the open one
    /// closes it.
    mutating func toggle(_ rungID: Int) {
        expandedRungID = (expandedRungID == rungID) ? nil : rungID
    }

    func isExpanded(_ rungID: Int) -> Bool { expandedRungID == rungID }

    func rung(_ id: Int) -> LadderRungRow? { rungs.first { $0.id == id } }

    // MARK: - Row detail

    /// `0.8 / < 1.0` for the criterion the user should look at.
    ///
    /// Multi-criterion skills ("blunders < 4.0 **and** clean-retry ≥ 55%") show
    /// the first one that is failing, falling back to the first overall. Showing
    /// all of them would turn a five-row rung into a fifteen-row wall, which is
    /// the exact problem the accordion exists to solve.
    static func measurement(for skill: Skill, in metrics: MetricSnapshot) -> String? {
        let evaluation = skill.evaluate(in: metrics)
        let criterion = evaluation.failingCriteria.first ?? skill.criteria.first
        guard let criterion else { return nil }
        guard let measured = metrics[criterion.metricKey, criterion.window] else { return nil }
        let value = formatMetricValue(measured.value)
        let threshold = formatMetricValue(criterion.threshold)
        return "\(value) / \(criterion.comparison.symbol) \(threshold)"
    }

    /// How many more observations before the skill can be judged at all.
    ///
    /// `nil` once every criterion is measured. When several criteria are short,
    /// the largest gap wins — that is the one that actually decides when the
    /// skill becomes measurable.
    static func samplesNeeded(for evaluation: SkillEvaluation, in metrics: MetricSnapshot) -> Int? {
        var worst: Int?
        for criterion in evaluation.unmeasuredCriteria {
            let have = metrics[criterion.metricKey, criterion.window]?.sampleCount ?? 0
            let need = max(criterion.minimumSamples - have, 1)
            worst = max(worst ?? 0, need)
        }
        return worst
    }

    static func symbol(for habit: Habit?) -> String {
        switch habit {
        case .whatChanged: return "arrow.triangle.2.circlepath"
        case .scanThreats: return "eye"
        case .candidatesFirst: return "list.bullet"
        case .calcToQuiet: return "function"
        case .blunderCheck: return "checkmark.shield"
        case .kingSafety: return "shield"
        case .endgameTechnique: return "flag.checkered"
        case .convertCleanly: return "arrow.down.right.circle"
        case .clockDiscipline: return "clock"
        case .none: return "circle.grid.2x2"
        }
    }
}
