//
//  ReviewSelfCheck.swift
//  ChessCoach
//

import Foundation

/// The questions asked *before* the engine's verdict is uncovered.
///
/// ## Why a review opens with questions
///
/// Reading an engine's conclusions is not reviewing a game. The value is in
/// forming your own answer first and finding out where it was wrong, because
/// that is the only thing that tells you which of your judgements to trust —
/// and a review that opens with the verdict never lets that happen. The user
/// scrolls, nods at a number, and learns that they lost on move 23 without ever
/// having had to look for it.
///
/// So the verdict, the filmstrip and the coaching are held back behind four
/// questions the analysis can already mark: where material went, which threat
/// was missed, whether the king was safe, and where the clock went. Each is
/// answered from rows the analysis wrote, so every question is scored against
/// something checkable rather than against a rubric.
///
/// ## Multiple choice, not free text
///
/// A free-text answer cannot be marked, and an unmarked answer is a diary
/// entry. Offering the real move among decoys drawn from the same game keeps
/// the question honest — the user has to *find* the move rather than recognise
/// that something bad happened — while staying scoreable.
///
/// ## Nothing is asked that cannot be marked
///
/// A game with no material loss is not asked where material went. The
/// alternative is a question whose correct answer is "nothing happened", which
/// teaches the user that the questions are decorative. Same doctrine as
/// ``PuzzleReason``: silence beats a question with no answer behind it.
enum ReviewSelfCheck {

    // MARK: Input

    /// What the check needs, mapped out of the review's own rows so the logic
    /// is testable from literals.
    struct Input: Sendable, Equatable {

        struct Move: Sendable, Equatable {
            var ply: Int
            /// `"23. Nf3"`, already formatted by the move list.
            var label: String
            var byUser: Bool
            var thinkTimeMs: Int
        }

        struct Moment: Sendable, Equatable {
            var ply: Int
            var causeTag: String
        }

        var moves: [Move]
        var moments: [Moment]

        init(moves: [Move], moments: [Moment]) {
            self.moves = moves
            self.moments = moments
        }
    }

    // MARK: Questions

    struct Question: Identifiable, Sendable, Equatable {

        struct Option: Identifiable, Sendable, Equatable {
            var id: String
            var label: String
            /// The ply this option points at, so answering can move the board
            /// to the move being discussed. Nil for a yes/no answer.
            var ply: Int?
        }

        var id: String
        var prompt: String
        var options: [Option]
        /// Index into ``options``.
        var correct: Int
        /// Shown after answering, whichever way it went. Written to be worth
        /// reading when the answer was right, too.
        var explanation: String

        var answer: Option { options[correct] }
    }

    /// Causes that mean material went missing.
    static let materialCauses: Set<String> = [
        "hungMovedPiece", "hungLeftPiece", "miscountedExchange"
    ]
    /// Causes that mean the opponent was allowed something.
    static let threatCauses: Set<String> = [
        "missedNewThreat", "ignoredStandingThreat"
    ]
    static let kingCause = "kingExposure"

    /// How many choices a move question offers, the real one included.
    static let optionCount = 4

    /// Builds the questions this particular game can mark.
    static func questions(for input: Input) -> [Question] {
        var questions: [Question] = []

        if let ply = firstMoment(in: input, causedBy: materialCauses) {
            questions.append(
                moveQuestion(
                    id: "material",
                    prompt: "Where did you lose material?",
                    answerPly: ply,
                    input: input,
                    explanation: "That is the move material went missing on. Counting what "
                        + "is attacked and what defends it, before you move, is the habit "
                        + "that catches this one."
                )
            )
        }

        if let ply = firstMoment(in: input, causedBy: threatCauses) {
            questions.append(
                moveQuestion(
                    id: "threat",
                    prompt: "Which move let your opponent's threat through?",
                    answerPly: ply,
                    input: input,
                    explanation: "Their reply to this move was the one you had not accounted "
                        + "for. Asking what their last move threatens — every move, before "
                        + "anything else — is what turns this into a move you see coming."
                )
            )
        }

        // Always askable: a game with no king trouble is a *fact about the
        // game*, and "yes, it was safe" is worth being right about.
        let exposed = input.moments.contains { $0.causeTag == kingCause }
        questions.append(
            Question(
                id: "king",
                prompt: "Was your king safe all game?",
                options: [
                    Question.Option(id: "king-yes", label: "Yes", ply: nil),
                    Question.Option(id: "king-no", label: "No", ply: nil)
                ],
                correct: exposed ? 1 : 0,
                explanation: exposed
                    ? "The analysis found your king exposed. Shelter is easier to keep than "
                        + "to rebuild — castling early and not pushing the pawns in front of "
                        + "the king is most of it."
                    : "Your king was never the problem in this game. Worth knowing: it means "
                        + "the mistakes to work on here are elsewhere."
            )
        )

        if let ply = longestThink(in: input) {
            questions.append(
                moveQuestion(
                    id: "clock",
                    prompt: "Which move did you spend longest on?",
                    answerPly: ply,
                    input: input,
                    explanation: "Time is only well spent where the position is genuinely "
                        + "critical. If this was a quiet move, the thinking went somewhere "
                        + "the game was not being decided."
                )
            )
        }

        return questions
    }

    /// Marks a set of answers. Keys are question ids, values are option indices.
    static func score(questions: [Question], answers: [String: Int]) -> Int {
        questions.reduce(into: 0) { total, question in
            if answers[question.id] == question.correct { total += 1 }
        }
    }

    // MARK: Building one question

    private static func firstMoment(in input: Input, causedBy causes: Set<String>) -> Int? {
        input.moments
            .filter { causes.contains($0.causeTag) }
            .map(\.ply)
            .min()
    }

    private static func longestThink(in input: Input) -> Int? {
        let candidates = input.moves.filter { $0.byUser && $0.thinkTimeMs > 0 }
        // A game where every move took the same time has no answer to this, and
        // asking it anyway would be marking a coin toss.
        guard candidates.count >= optionCount,
            let longest = candidates.max(by: { $0.thinkTimeMs < $1.thinkTimeMs }),
            candidates.contains(where: { $0.thinkTimeMs < longest.thinkTimeMs })
        else { return nil }
        return longest.ply
    }

    /// A question whose options are moves from this game.
    ///
    /// Decoys are the user's own moves, spread across the game rather than
    /// taken from around the answer: three plies either side of the mistake are
    /// all plausible, which makes the question a guess between neighbours
    /// instead of a search through the game.
    private static func moveQuestion(
        id: String,
        prompt: String,
        answerPly: Int,
        input: Input,
        explanation: String
    ) -> Question {
        let mine = input.moves.filter(\.byUser).sorted { $0.ply < $1.ply }
        let others = mine.filter { $0.ply != answerPly }
        let wanted = optionCount - 1

        var decoys: [Input.Move] = []
        if others.count <= wanted {
            decoys = others
        } else {
            // Evenly spaced picks, so the choices span the game.
            let step = Double(others.count) / Double(wanted)
            for slot in 0..<wanted {
                let index = min(others.count - 1, Int((Double(slot) + 0.5) * step))
                let candidate = others[index]
                if !decoys.contains(where: { $0.ply == candidate.ply }) { decoys.append(candidate) }
            }
            // Spacing can collide on a short game; fill from whatever is left.
            for candidate in others where decoys.count < wanted {
                if !decoys.contains(where: { $0.ply == candidate.ply }) { decoys.append(candidate) }
            }
        }

        let answer = input.moves.first { $0.ply == answerPly }
        let all = (decoys + [answer].compactMap { $0 }).sorted { $0.ply < $1.ply }
        let options = all.map {
            Question.Option(id: "\(id)-\($0.ply)", label: $0.label, ply: $0.ply)
        }

        return Question(
            id: id,
            prompt: prompt,
            options: options,
            // Ordering by ply is what keeps the answer from always sitting in
            // the same slot; its index falls wherever the move falls.
            correct: options.firstIndex { $0.ply == answerPly } ?? 0,
            explanation: explanation
        )
    }
}
