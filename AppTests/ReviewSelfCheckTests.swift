//
//  ReviewSelfCheckTests.swift
//  ChessCoachTests
//

import Testing

@testable import ChessCoach

/// A review that opens with the answer teaches the user to read a verdict. The
/// check exists to make them commit first, so its rules are about what can be
/// *marked* — never about filling four slots.
@Suite("Review self-check")
struct ReviewSelfCheckTests {

    private func input(
        userMoves: Int = 10,
        thinkTimes: [Int: Int] = [:],
        moments: [(ply: Int, cause: String)] = [],
        judgedMistakePlies: Set<Int> = [],
        refutationSAN: String? = nil
    ) -> ReviewSelfCheck.Input {
        var moves: [ReviewSelfCheck.Input.Move] = []
        for ply in 1...(userMoves * 2) {
            let byUser = ply.isMultiple(of: 2) == false
            moves.append(
                ReviewSelfCheck.Input.Move(
                    ply: ply,
                    label: "\((ply + 1) / 2). move\(ply)",
                    byUser: byUser,
                    thinkTimeMs: thinkTimes[ply] ?? (byUser ? 1_000 + ply : 0),
                    isJudgedMistake: judgedMistakePlies.contains(ply)
                )
            )
        }
        return ReviewSelfCheck.Input(
            moves: moves,
            moments: moments.map {
                ReviewSelfCheck.Input.Moment(
                    ply: $0.ply,
                    causeTag: $0.cause,
                    refutationSAN: refutationSAN
                )
            }
        )
    }

    @Test("A game with no material loss is never asked where material went")
    func onlyAsksWhatItCanMark() {
        let questions = ReviewSelfCheck.questions(for: input(moments: []))
        #expect(questions.contains { $0.id == "material" } == false)
        #expect(questions.contains { $0.id == "threat" } == false)
        // King safety is markable either way, so it rides along beside a
        // question that could have gone wrong.
        #expect(questions.contains { $0.id == "king" })
    }

    /// Answerable is not the same as worth asking. On its own the king question
    /// is a one-question quiz whose only answer is Yes, and the verdict a tap
    /// later says the game had nothing to pick apart — two readings of one game
    /// on adjacent screens.
    @Test("The king question is not asked on its own")
    func kingQuestionNeverStandsAlone() {
        // Every move took the same time, so there is no clock question either.
        let flat = input(
            thinkTimes: Dictionary(uniqueKeysWithValues: (1...20).map { ($0, 5_000) }),
            moments: []
        )
        #expect(ReviewSelfCheck.questions(for: flat).isEmpty)
    }

    /// The question is marked against the slate, and the slate holds at most
    /// three moments — so a king-exposure moment that lost its slot to two
    /// bigger mistakes leaves this answering "Yes". "Your king was never the
    /// problem in this game" was therefore an assertion nothing had verified, on
    /// the screen whose only asset is being believed.
    @Test("A king the review did not flag is not declared safe")
    func safeKingIsNotAClaimOfSafety() {
        let king = try! #require(
            ReviewSelfCheck.questions(for: input(moments: [])).first { $0.id == "king" }
        )
        #expect(king.explanation.contains("Nothing the review picked out"))
        #expect(king.explanation.contains("not a clean bill of health"))
        #expect(king.explanation.contains("never the problem") == false)
    }

    @Test("Each cause the analysis tagged turns into its own question")
    func buildsFromCauses() {
        let questions = ReviewSelfCheck.questions(
            for: input(moments: [(ply: 7, cause: "hungMovedPiece"), (ply: 13, cause: "missedNewThreat")])
        )
        #expect(questions.map(\.id) == ["material", "threat", "king", "clock"])
        let material = try! #require(questions.first { $0.id == "material" })
        #expect(material.answer.ply == 7)
        let threat = try! #require(questions.first { $0.id == "threat" })
        #expect(threat.answer.ply == 13)
    }

    @Test("The king question flips on the king-exposure tag")
    func kingSafetyIsMarkedBothWays() {
        let safe = ReviewSelfCheck.questions(for: input(moments: []))
            .first { $0.id == "king" }
        #expect(safe?.answer.label == "Yes")

        let exposed = ReviewSelfCheck.questions(for: input(moments: [(ply: 9, cause: "kingExposure")]))
            .first { $0.id == "king" }
        #expect(exposed?.answer.label == "No")
    }

    /// The earliest one, because the first time material went is the one the
    /// rest of the game followed from.
    @Test("The earliest tagged moment is the one asked about")
    func asksAboutTheFirstOne() {
        let questions = ReviewSelfCheck.questions(
            for: input(moments: [(ply: 21, cause: "hungLeftPiece"), (ply: 5, cause: "hungMovedPiece")])
        )
        #expect(questions.first { $0.id == "material" }?.answer.ply == 5)
    }

    @Test("A game where every move took the same time has no clock question")
    func doesNotMarkACoinToss() {
        let flat = input(thinkTimes: Dictionary(uniqueKeysWithValues: (1...20).map { ($0, 5_000) }))
        #expect(ReviewSelfCheck.questions(for: flat).contains { $0.id == "clock" } == false)
    }

    @Test("The clock question names the longest think")
    func findsTheLongestThink() {
        var times = Dictionary(uniqueKeysWithValues: stride(from: 1, through: 19, by: 2).map { ($0, 1_000) })
        times[11] = 90_000
        let questions = ReviewSelfCheck.questions(for: input(thinkTimes: times))
        #expect(questions.first { $0.id == "clock" }?.answer.ply == 11)
    }

    /// Decoys taken from around the mistake would make this a guess between
    /// neighbours; the point is to search the whole game.
    @Test("The choices are the user's own moves, spread across the game")
    func decoysAreSpreadAndOwn() {
        let questions = ReviewSelfCheck.questions(
            for: input(userMoves: 20, moments: [(ply: 15, cause: "hungMovedPiece")])
        )
        let material = try! #require(questions.first { $0.id == "material" })

        #expect(material.options.count == ReviewSelfCheck.optionCount)
        #expect(material.options.allSatisfy { ($0.ply ?? 0).isMultiple(of: 2) == false })
        #expect(Set(material.options.map(\.ply)).count == material.options.count)
        // Sorted by ply, so the answer is not always in the same slot.
        #expect(material.options.map { $0.ply ?? 0 } == material.options.map { $0.ply ?? 0 }.sorted())

        let plies = material.options.compactMap(\.ply)
        #expect((plies.max() ?? 0) - (plies.min() ?? 0) > 10, "the choices should span the game")
    }

    @Test("A game too short to offer choices does not ask a move question")
    func shortGamesDegrade() {
        let questions = ReviewSelfCheck.questions(
            for: input(userMoves: 2, moments: [(ply: 1, cause: "hungMovedPiece")])
        )
        // Still asked, but with only the moves that exist rather than invented ones.
        let material = questions.first { $0.id == "material" }
        #expect(material?.options.count == 2)
        #expect(material?.answer.ply == 1)
    }

    /// At 1000–1500 several hangs a game is normal and the slate keeps three
    /// moments, so a reader naming a *different* real blunder was answering
    /// correctly and being marked wrong. There is no per-ply cause tag to mark
    /// against, but there is a per-ply classification — so the other mistakes
    /// come off the menu instead.
    @Test("A mistake the slate left out is never offered as a decoy")
    func otherMistakesAreNotDecoys() {
        let questions = ReviewSelfCheck.questions(
            for: input(
                userMoves: 20,
                moments: [(ply: 15, cause: "hungMovedPiece")],
                judgedMistakePlies: [3, 9, 27, 33]
            )
        )
        let material = try! #require(questions.first { $0.id == "material" })
        let offered = Set(material.options.compactMap(\.ply))

        #expect(offered.contains(15), "the answer is still on the menu")
        #expect(offered.isDisjoint(with: [3, 9, 27, 33]))
    }

    /// The clock question is not one of them: the longest think is as likely to
    /// land on a blunder as anywhere, and dropping the mistakes from its choices
    /// would tell the reader which move it was.
    @Test("The clock question still offers every move")
    func clockQuestionKeepsItsDecoys() {
        var times = Dictionary(uniqueKeysWithValues: stride(from: 1, through: 39, by: 2).map { ($0, 1_000) })
        times[11] = 90_000
        let questions = ReviewSelfCheck.questions(
            for: input(userMoves: 20, thinkTimes: times, judgedMistakePlies: [3, 9, 27, 33])
        )
        let clock = try! #require(questions.first { $0.id == "clock" })
        #expect(clock.options.count == ReviewSelfCheck.optionCount)
    }

    /// The two causes grouped under one question are opposites. The coaching
    /// bank's words for `ignoredStandingThreat` are "you already knew about
    /// their threat", and the leak it feeds is titled "A threat left standing" —
    /// so telling that reader they had missed it contradicted every other screen
    /// that mentions the same move.
    @Test("The threat explanation matches which threat it was")
    func threatExplanationFollowsTheCause() {
        let missed = ReviewSelfCheck.threatExplanation(
            for: .init(ply: 13, causeTag: "missedNewThreat", refutationSAN: nil)
        )
        let standing = ReviewSelfCheck.threatExplanation(
            for: .init(ply: 13, causeTag: "ignoredStandingThreat", refutationSAN: nil)
        )

        #expect(missed.contains("had not accounted for"))
        #expect(standing.contains("already seen this threat"))
        #expect(standing.contains("had not accounted for") == false)
    }

    @Test("The refuting move is named when the stored line has it")
    func threatExplanationNamesTheReply() {
        let named = ReviewSelfCheck.threatExplanation(
            for: .init(ply: 13, causeTag: "missedNewThreat", refutationSAN: "Nxe5")
        )
        #expect(named.contains("Their answer was Nxe5."))
    }

    /// The point of asking is whether the time went where the game was being
    /// decided, and the review already knows which positions those were.
    @Test("The clock explanation says whether the long think was on a flagged move")
    func clockExplanationUsesTheSlate() {
        let onAMoment = ReviewSelfCheck.clockExplanation(
            answerPly: 11,
            input: input(moments: [(ply: 11, cause: "hungMovedPiece")])
        )
        let elsewhere = ReviewSelfCheck.clockExplanation(
            answerPly: 11,
            input: input(moments: [(ply: 21, cause: "hungMovedPiece")])
        )

        #expect(onAMoment.contains("the time went where the game was"))
        #expect(elsewhere.contains("not being decided"))
    }

    @Test("Scoring counts only the questions actually answered correctly")
    func marksAnswers() {
        let questions = ReviewSelfCheck.questions(
            for: input(moments: [(ply: 7, cause: "hungMovedPiece")])
        )
        let material = try! #require(questions.first { $0.id == "material" })
        let king = try! #require(questions.first { $0.id == "king" })

        let answers = [material.id: material.correct, king.id: 1 - king.correct]
        #expect(ReviewSelfCheck.score(questions: questions, answers: answers) == 1)
        #expect(ReviewSelfCheck.score(questions: questions, answers: [:]) == 0)
    }

    /// The whole reason to answer before the engine speaks is to find out which
    /// of your own judgements to trust. A score that is written to the database
    /// and never shown cannot do that.
    @Test("The questions end with a line the reader can act on")
    func resultLineNamesWhatWasMissed() {
        let questions = ReviewSelfCheck.questions(
            for: input(moments: [(ply: 7, cause: "hungMovedPiece")])
        )
        let material = try! #require(questions.first { $0.id == "material" })
        let line = try! #require(
            ReviewModel.resultLine(
                questions: questions,
                answers: [material.id: (material.correct + 1) % material.options.count]
            )
        )
        #expect(line.hasPrefix("Before the engine: 0 of \(questions.count)"))
        #expect(line.contains("you missed \(material.answer.label)"))
        #expect(line.contains("skipped"))

        let clean = try! #require(
            ReviewModel.resultLine(
                questions: questions,
                answers: Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0.correct) })
            )
        )
        #expect(clean == "Before the engine: \(questions.count) of \(questions.count)")

        // Nothing answered is nothing to report — see `skipSelfCheck`.
        #expect(ReviewModel.resultLine(questions: questions, answers: [:]) == nil)
    }
}
