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
            /// Whether the analysis judged this move a mistake or a blunder.
            ///
            /// Read off the move row's own classification, which covers **every**
            /// ply — unlike ``moments``, which is the slate of at most three the
            /// selector kept. It is the only thing here that knows about the
            /// mistakes that did not make the slate, and it exists to keep them
            /// out of the decoys; see ``moveQuestion(id:prompt:answerPly:input:excludingJudgedMistakes:explanation:)``.
            var isJudgedMistake: Bool = false
        }

        struct Moment: Sendable, Equatable {
            var ply: Int
            var causeTag: String
            /// The move that punished this one, in SAN, when the stored line has
            /// it. Names the reply in the explanation instead of describing it.
            var refutationSAN: String? = nil
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

        if let moment = firstMoment(in: input, causedBy: materialCauses) {
            let question = moveQuestion(
                id: "material",
                prompt: "Where did you lose material?",
                answerPly: moment.ply,
                input: input,
                excludingJudgedMistakes: true,
                explanation: "That is the move material went missing on. Counting what "
                    + "is attacked and what defends it, before you move, is the habit "
                    + "that catches this one."
            )
            if let question { questions.append(question) }
        }

        if let moment = firstMoment(in: input, causedBy: threatCauses) {
            let question = moveQuestion(
                id: "threat",
                prompt: "Which move let your opponent's threat through?",
                answerPly: moment.ply,
                input: input,
                excludingJudgedMistakes: true,
                explanation: threatExplanation(for: moment)
            )
            if let question { questions.append(question) }
        }

        let clock = longestThink(in: input).flatMap { ply in
            moveQuestion(
                id: "clock",
                prompt: "Which move did you spend longest on?",
                answerPly: ply,
                input: input,
                // Not excluded here, unlike the two questions above: the longest
                // think is as likely to be a blunder as anything else, and
                // dropping the mistakes would tell the reader which move it was.
                excludingJudgedMistakes: false,
                explanation: clockExplanation(answerPly: ply, input: input)
            )
        }

        // Always answerable, which is not the same as always worth asking. On a
        // clean game it becomes a one-question quiz whose only answer is Yes,
        // and the card one tap later says "A win with nothing to pick apart" —
        // two readings of the same game on adjacent screens. It goes in only
        // beside a question that could have gone wrong.
        guard !questions.isEmpty || clock != nil else { return [] }

        questions.append(kingQuestion(for: input))

        if let clock { questions.append(clock) }

        return questions
    }

    /// The king question, and the one thing it is careful not to claim.
    ///
    /// "Was your king safe all game?" is marked against the slate, and the slate
    /// holds at most three moments — so a king-exposure moment that lost its slot
    /// to two bigger mistakes leaves this answering "Yes". Saying *your king was
    /// never the problem* there is an assertion nothing verified, on the one
    /// screen whose whole value is being believed. The wording says what the
    /// review actually did, which is also the more useful thing to tell someone:
    /// nothing about your king was among the worst things in this game.
    static func kingQuestion(for input: Input) -> Question {
        let exposed = input.moments.contains { $0.causeTag == kingCause }
        return Question(
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
                : "Nothing the review picked out this game turned on your king. That is "
                    + "not a clean bill of health — the review only pulls out the few "
                    + "moves that cost the most — but your king was not among them."
        )
    }

    /// The threat question's explanation, which depends on which threat it was.
    ///
    /// The two causes grouped under this question are opposites, and one
    /// sentence for both told half the readers the wrong thing.
    /// `missedNewThreat` is a reply you did not see coming; `ignoredStandingThreat`
    /// is one you had already seen and answered badly — the coaching bank's own
    /// words for it are "you already knew about their threat", and the leak it
    /// feeds is titled "A threat left standing". Telling that reader they missed
    /// it contradicts every other screen that mentions the same move.
    static func threatExplanation(for moment: Input.Moment) -> String {
        let reply = moment.refutationSAN.map { " Their answer was \($0)." } ?? ""

        if moment.causeTag == "ignoredStandingThreat" {
            return "You had already seen this threat; the move you chose did not deal with it."
                + reply
                + " Before you commit, check that your move actually answers what they are "
                + "threatening — a move that merely ignores it hands them the idea."
        }
        return "Their reply to this move was the one you had not accounted for."
            + reply
            + " Asking what their last move threatens — every move, before anything else — "
            + "is what turns this into a move you see coming."
    }

    /// The clock question's explanation.
    ///
    /// Whether the longest think landed on a position the review flagged is a
    /// fact this screen holds, and it is the whole point of the question: time
    /// spent on the move that decided the game is time well spent, and the same
    /// three minutes spent elsewhere is the leak. Criticality proper is not
    /// stored on the row, so the claim is kept to what the slate can support.
    static func clockExplanation(answerPly: Int, input: Input) -> String {
        let flagged = input.moments.contains { $0.ply == answerPly }
        if flagged {
            return "That is also one of the positions this game turned on, so the time went "
                + "where the game was. Spending it there is the habit, not the problem."
        }
        return "Nothing the review flagged happened on that move, so the longest think of "
            + "the game went somewhere it was not being decided. Move quickly where only "
            + "one move makes sense, and bank the time for the positions that branch."
    }

    /// Marks a set of answers. Keys are question ids, values are option indices.
    static func score(questions: [Question], answers: [String: Int]) -> Int {
        questions.reduce(into: 0) { total, question in
            if answers[question.id] == question.correct { total += 1 }
        }
    }

    // MARK: Building one question

    /// The earliest moment with one of these causes, because the first time
    /// material went is the one the rest of the game followed from.
    private static func firstMoment(in input: Input, causedBy causes: Set<String>) -> Input.Moment? {
        input.moments
            .filter { causes.contains($0.causeTag) }
            .min { $0.ply < $1.ply }
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
    ///
    /// ## Why the other mistakes are kept out
    ///
    /// The check is marked against the slate, and the slate holds at most three
    /// moments — but at 1000–1500 several hangs a game is normal, so a reader
    /// who names a *different* real blunder was answering the question correctly
    /// and being marked wrong for it. That is the fastest way to teach someone
    /// not to trust the coaching, and there is no per-ply cause tag to mark
    /// against instead.
    ///
    /// What there *is* is the move row's own classification, which covers every
    /// ply of the game. Excluding the moves the analysis judged mistakes leaves
    /// only quiet moves to choose between, so the one wrong-looking move on
    /// offer is the answer and a wrong answer is genuinely wrong. The question
    /// gets easier; it stops being unfair, which matters more.
    ///
    /// Returns `nil` when there is nothing left to choose between: a single
    /// option is not a question.
    private static func moveQuestion(
        id: String,
        prompt: String,
        answerPly: Int,
        input: Input,
        excludingJudgedMistakes: Bool,
        explanation: String
    ) -> Question? {
        let mine = input.moves.filter(\.byUser).sorted { $0.ply < $1.ply }
        let others = mine.filter { move in
            guard move.ply != answerPly else { return false }
            return !(excludingJudgedMistakes && move.isJudgedMistake)
        }
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
        guard options.count >= 2, options.contains(where: { $0.ply == answerPly }) else { return nil }

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
