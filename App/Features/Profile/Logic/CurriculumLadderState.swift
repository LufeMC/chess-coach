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

/// What a skill is still waiting for before it can be judged.
///
/// Carries the noun as well as the count. "Needs 15 more games" was the only
/// copy this row had, and it is wrong for most of the ladder: the rung-2 theme
/// gate counts puzzle attempts, the rung-3 critical-moment gate counts critical
/// moments, and the drill gates count runs of a drill that no amount of playing
/// will ever start. A user who plays ten games and watches the number sit still
/// concludes the ladder is broken, and they are half right.
struct LadderSkillPending: Sendable, Hashable {

    let count: Int
    let noun: String
    let nounSingular: String

    /// Where the observation comes from when playing will not produce one.
    let source: String?

    /// `Needs 15 more puzzles rated 1200+` / `Not run yet — Train › Endgames`.
    var note: String {
        if let source { return "Not run yet — \(source)" }
        return count == 1 ? "Needs 1 more \(nounSingular)" : "Needs \(count) more \(noun)"
    }
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

    /// `Hanging pieces 0.8 per 100 moves · need under 1.0` — the quantity, the
    /// value, its unit, and the threshold it is judged by. `nil` when nothing
    /// has been measured.
    ///
    /// The name and the unit are not decoration. Without them the row under
    /// "Blunder control" read `0.4 / ≥ 0.55`, and 0.4 of what was answerable
    /// only by reading the curriculum table in source.
    let measurement: String?

    /// Non-`nil` only for unmeasured criteria, and the reason the row says what
    /// it is still waiting for instead of rendering a zero that looks like
    /// failure.
    let pending: LadderSkillPending?

    /// SF Symbol for the leading icon, chosen from the habit the skill trains
    /// so the ladder and the weekly focus speak the same visual language.
    let symbol: String

    var isUnmeasured: Bool { pending != nil }
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

    /// What the collapsed header actually prints on the right.
    ///
    /// A rung the user was *placed above* at calibration has nothing measured
    /// under it on day one, and "✓ 0/5" beside a tick reads either as a
    /// rendering fault or as the app claiming work the user never did. The two
    /// states the fraction has to tell apart are "skipped by placement" and
    /// "earned, then decayed" — and a decayed rung has skills that were measured
    /// and came up short, which is exactly the case the fraction exists for.
    var completionSummary: String {
        skills.allSatisfy(\.isUnmeasured) ? "Not measured" : completionFraction
    }

    var requiredSkills: [LadderSkillRow] { skills.filter(\.isRequired) }
    var requiredMetCount: Int { requiredSkills.filter(\.isMet).count }

    /// Nothing left holding the current rung: the promotion is sitting there
    /// waiting to be taken.
    ///
    /// Gated on ``status`` because completed and locked rungs are built with an
    /// empty blocker list by construction — without the check, every rung on
    /// the ladder would announce itself as ready.
    ///
    /// The skills are checked as well as the blocker list, and not out of
    /// caution: the placeholder snapshot the screen draws before its first read
    /// lands is built with no metrics *and* no blockers, so blockers alone would
    /// congratulate a brand-new user on a rung they have not started. When the
    /// list came from a real decision the two always agree — an unmet required
    /// skill is a blocker — so this can only ever suppress a claim, never make
    /// one, which is the direction a wrong answer should fail in.
    var isReadyToAdvance: Bool {
        status == .current && blockers.isEmpty && requiredSkills.allSatisfy(\.isMet)
    }

    /// Plain-language blockers, in the order the domain reports them.
    ///
    /// Unmet *required skills* are folded into one line rather than repeated
    /// per skill: each of them is already an unmet row a few points below, and
    /// restating them here would make a rung with four unmet skills read as
    /// eight problems.
    ///
    /// A rung with nothing outstanding used to produce an empty list, which the
    /// section renders as no line at all — so the one state worth telling the
    /// user about, the one where they have earned the next rung, was the only
    /// state that said nothing. Promotion is a tap on the Train tab and never a
    /// side effect of a recompute, so the line has to name where that tap is.
    var blockerMessages: [String] {
        if isReadyToAdvance { return ["Ready for Rung \(id + 1) — take it on the Train tab"] }
        var messages: [String] = []
        let unmetRequired = blockers.filter {
            if case .requiredSkillUnmet = $0 { return true }
            return false
        }.count
        if unmetRequired > 0 {
            messages.append(unmetRequired == 1
                ? "1 required skill"
                : "\(unmetRequired) required skills")
        }
        for blocker in blockers {
            switch blocker {
            case .insufficientGames(let have, let need):
                messages.append("\(need - have) more games")
            case .insufficientDays(let have, let need):
                messages.append("\(need - have) more days here")
            case .atTopRung:
                messages.append("Top rung — nothing above this yet")
            case .requiredSkillUnmet:
                continue
            }
        }
        return messages
    }

    var isAtTopRung: Bool {
        blockers.contains {
            if case .atTopRung = $0 { return true }
            return false
        }
    }

    /// The blockers as one sentence, framed as what they are conditions *for*.
    ///
    /// The bare list — "2 required skills · 4 more games · 5 more days here" —
    /// states three true things without once saying that meeting them moves the
    /// user up a rung, which is the only reason any of them is on screen.
    var blockerSummary: String? {
        let messages = blockerMessages
        guard !messages.isEmpty else { return nil }
        // Already a whole sentence about the rung above, so wrapping it in
        // "To reach Rung 3:" would say the same thing twice.
        guard !isReadyToAdvance else { return messages[0] }
        guard !isAtTopRung else { return messages.joined(separator: " · ") }
        let list: String
        if messages.count == 1 {
            list = messages[0]
        } else {
            list = messages.dropLast().joined(separator: ", ") + " and " + messages[messages.count - 1]
        }
        return "To reach Rung \(id + 1): \(list)."
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
                    pending: Self.pending(for: evaluation, in: metrics),
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

    // MARK: - Unmeasurable criteria

    /// The ladder with every criterion this build cannot produce removed.
    ///
    /// `prophylactic.findRate` has no detector behind it, so a criterion on it
    /// never resolves: left in, the rung-4 row reads "keep playing" from the day
    /// the user arrives there to the end of the year, and it holds the rung's
    /// fraction below full for the same forever. A skill left with no criteria
    /// at all drops out of the rung rather than sitting permanently pending.
    ///
    /// The set is a parameter rather than a lookup because this directory is
    /// pure — see the note at the top of `ProfileNumbers.swift` — and which
    /// metrics the analysis pass emits is a fact about the app layer.
    static func measurable(_ ladder: [Rung], unsupported: Set<String>) -> [Rung] {
        guard !unsupported.isEmpty else { return ladder }
        return ladder.map { rung in
            var trimmed = rung
            trimmed.skills = rung.skills.compactMap { skill -> Skill? in
                let kept = skill.criteria.filter { !unsupported.contains($0.metricKey.rawValue) }
                guard !kept.isEmpty else { return nil }
                guard kept.count != skill.criteria.count else { return skill }
                var copy = skill
                copy.criteria = kept
                return copy
            }
            return trimmed
        }
    }

    // MARK: - Row detail

    /// `Hanging pieces 0.8 per 100 moves · need under 1.0` for the criterion the
    /// user should look at.
    ///
    /// Multi-criterion skills ("blunders < 4.0 **and** clean-retry ≥ 55%") show
    /// the first one that is failing, falling back to the first overall. Showing
    /// all of them would turn a five-row rung into a fifteen-row wall, which is
    /// the exact problem the accordion exists to solve — which is also why the
    /// criterion has to name itself. Under a title like "Blunder control" the
    /// old `0.4 / ≥ 0.55` gave no way to tell which of the two conjuncts was
    /// being reported, let alone what 0.4 counted.
    static func measurement(for skill: Skill, in metrics: MetricSnapshot) -> String? {
        let evaluation = skill.evaluate(in: metrics)
        let criterion = evaluation.failingCriteria.first ?? skill.criteria.first
        guard let criterion else { return nil }
        guard let measured = metrics[criterion.metricKey, criterion.window] else { return nil }
        let presentation = criterion.metricKey.presentation
        let value = presentation.formatted(measured.value)
        // The threshold is written bare: the unit is already on the value, and
        // repeating it turns a glanceable line into a paragraph.
        let threshold = presentation.style.format(criterion.threshold)
        return "\(presentation.name) \(value) · \(criterion.comparison.need) \(threshold)"
    }

    /// What the skill is still waiting for before it can be judged at all.
    ///
    /// `nil` once every criterion is measured. When several criteria are short,
    /// the largest gap wins — that is the one that actually decides when the
    /// skill becomes measurable — and the noun comes from *that* criterion, so
    /// a rung-2 theme gate asks for puzzles and a drill gate sends the user to
    /// the drill instead of asking for a game that cannot move it.
    static func pending(for evaluation: SkillEvaluation, in metrics: MetricSnapshot) -> LadderSkillPending? {
        var worst: (need: Int, criterion: SkillCriterion)?
        for criterion in evaluation.unmeasuredCriteria {
            let have = metrics[criterion.metricKey, criterion.window]?.sampleCount ?? 0
            let need = max(criterion.minimumSamples - have, 1)
            if need > (worst?.need ?? 0) { worst = (need, criterion) }
        }
        guard let worst else { return nil }
        let presentation = worst.criterion.metricKey.presentation
        return LadderSkillPending(
            count: worst.need,
            noun: presentation.sampleNoun,
            nounSingular: presentation.sampleNounSingular,
            source: presentation.sampleSource
        )
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
