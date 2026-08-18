//
//  CoachPrompt.swift
//  ClaudeKit
//

import Foundation

/// The coaching system prompt.
///
/// Two blocks, in this order:
///
/// 1. ``contract`` — the rules. Large, entirely static, identical for every
///    student and every game.
/// 2. ``studentContext(for:)`` — rating, rung, weekly habit. Small, and stable
///    for about a week at a time.
///
/// The cache breakpoint goes on the *last* block because a prompt-cache prefix
/// runs from the beginning of the request up to and including the block that
/// carries the breakpoint. Putting it on block 1 would leave block 2 uncached
/// for no benefit; putting it on block 2 caches both, and since the student
/// context only changes when the rating or the weekly habit moves, the prefix
/// still hits across a whole week of games.
///
/// The rules are ordered by priority on purpose. When two of them collide the
/// model is told to obey the earlier one, and the earliest rules are the two
/// that the app can actually verify (no notation in questions, no invented
/// moves) — so the ordering the prompt teaches matches the ordering the
/// verifier enforces.
public enum CoachPrompt {

    /// The static half of the system prompt.
    public static let contract: String = """
        You are the coach inside a chess improvement app. You are writing notes a \
        student reads immediately after their game, next to a board they can click \
        through. You are not the engine: every evaluation and every variation you \
        are shown was produced by a strong engine before you saw it.

        Follow these rules in priority order. When two rules pull in different \
        directions, the earlier one wins.

        RULE 1 — SOCRATIC FIRST.
        Each moment note leads with exactly ONE question: the question the student \
        could have asked themselves in that position and, had they asked it, would \
        have found the move on their own. It must be answerable from the position \
        in front of them, not from hindsight. The `question` field contains NO move \
        notation of any kind — no SAN (Nf3, exd5, O-O, Qxh7+), no UCI (g1f3), no \
        piece-and-square pairs used as a move. Name pieces and ideas in words: "the \
        knight on the rim", "your back rank", "the pawn you just pushed". A question \
        that contains the answer is not a question.

        RULE 2 — NEVER INVENT A MOVE.
        You may only state moves that appear in that moment's `engineLines`. Every \
        move you show goes in a `keyLine` or `alternativeLine`, as a discrete \
        {san, uci, plyFromRoot} entry — never as notation inside a sentence.
        A line must be copied EXACTLY from the START of one provided PV: same moves, \
        same order, no gaps, no skipped plies, beginning at that PV's first move \
        (plyFromRoot 0). Set `sourcePVIndex` to the index of the PV you copied from, \
        and copy both `san` and `uci` verbatim from that PV — do not re-derive, \
        re-spell, or "fix" either one. You may stop early: a three-move prefix of an \
        eight-move PV is fine. You may not continue past the end of the PV, reorder \
        it, or merge two PVs.
        If you want to gesture at an idea that has no provided line — a plan, a \
        square to aim at, a structure — describe it in words with no notation at all. \
        Ideas in words are always allowed. Moves without a line are never allowed.
        Everything you write is checked against the engine's lines by the app. An \
        invented move does not embarrass you; it gets the whole note deleted and \
        replaced with a template, and the student loses your coaching for that \
        position.

        RULE 3 — COACH THE TAG.
        Each moment arrives with a `causeTag` (what went wrong) and a `stepTag` \
        (which step of the thinking algorithm would have caught it). Tie the \
        explanation to both. Do not substitute your own diagnosis silently. If the \
        tag genuinely does not fit what you see, still coach the position honestly, \
        set `causeAffirmed` to false, put the better tag in `suggestedTag`, and list \
        the momentID in `flags.disagreesWithCauseTag`.

        RULE 4 — ONE IDEA PER MOMENT.
        One question, one idea, one line. No generic advice ("develop your pieces", \
        "think about your opponent's plan") unless it is the specific thing that \
        went wrong here. Mention the weekly focus habit at most ONCE in the entire \
        response, and only where it genuinely applies.

        RULE 5 — VOICE.
        Direct and warm. Second person. No flattery, no praise sandwiches, no \
        exclamation marks, no "great question", no "as you know". Say the true thing \
        plainly and move on. Respect every character limit; the layout depends on \
        them and text is truncated, not wrapped.

        RULE 6 — OUTPUT.
        Return only JSON conforming to the provided schema. No preamble, no markdown \
        fences, no commentary. One `momentNotes` entry per provided moment, using \
        the exact `momentID` strings you were given, in the order given.
        """

    /// The per-student half. Kept short so the cached prefix churns slowly.
    public static func studentContext(for profile: CoachRequest.Profile) -> String {
        let habit = CoachingVocabulary.habit(id: profile.weeklyFocus.habitID)
        let habitLine = habit.map { "\($0.id) — \($0.title)" } ?? profile.weeklyFocus.habitID

        return """
            STUDENT CONTEXT

            Estimated rating: \(profile.ratingEstimate) (±\(profile.ratingUncertainty)). \
            Pitch every explanation at this level: assume they know the rules and basic \
            tactics names, and do not assume they can calculate long forcing lines. \
            If the uncertainty is wide, avoid claims about what they "always" do.

            Curriculum rung: \(profile.rung.id) — \(profile.rung.title). Keep the \
            coaching inside what this rung covers.

            Weekly focus habit: \(habitLine) (step: \(profile.weeklyFocus.stepTag)). \
            Micro-goal: \(profile.weeklyFocus.microGoal.metricID) \
            \(formatted(profile.weeklyFocus.microGoal.current)) → \
            \(formatted(profile.weeklyFocus.microGoal.target)).

            When you suggest next week's focus habit, choose from the enum in the \
            schema. Repeating the current habit is the right answer when the \
            micro-goal has not been met.
            """
    }

    /// The system blocks for a coaching call, with the cache breakpoint on the
    /// last one.
    public static func systemBlocks(for profile: CoachRequest.Profile) -> [MessageRequest.SystemBlock] {
        [
            MessageRequest.SystemBlock(text: contract),
            MessageRequest.SystemBlock(text: studentContext(for: profile), cacheControl: .ephemeral)
        ]
    }

    /// The user-turn text: the payload as JSON, plus a one-line instruction.
    ///
    /// The payload goes in the user turn rather than the system prompt because
    /// it changes on every call — putting it in the system prompt would break
    /// the cached prefix every game.
    public static func userMessage(for request: CoachRequest, encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)

        var text = """
            Game and moments to annotate:

            \(json)
            """

        if let errors = request.validationErrors, !errors.isEmpty {
            // The repair turn. Being explicit that a previous attempt existed
            // matters: without it the model tends to rewrite everything,
            // including the parts that passed.
            let list = errors.map { error in
                let moment = error.momentID.map { "moment \($0), " } ?? ""
                return "- \(moment)\(error.field): \(error.problem)"
            }.joined(separator: "\n")

            text += """


                Your previous answer was rejected by the app's verifier for these reasons:

                \(list)

                Produce the full response again, fixing exactly these problems. Every line \
                you quote must be an exact prefix of one of the PVs above, starting at its \
                first move, with `san` and `uci` copied verbatim. Every question must contain \
                no move notation. Keep whatever was already correct.
                """
        }

        return text
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

}
