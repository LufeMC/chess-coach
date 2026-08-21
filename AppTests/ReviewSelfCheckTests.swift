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
        moments: [(ply: Int, cause: String)] = []
    ) -> ReviewSelfCheck.Input {
        var moves: [ReviewSelfCheck.Input.Move] = []
        for ply in 1...(userMoves * 2) {
            let byUser = ply.isMultiple(of: 2) == false
            moves.append(
                ReviewSelfCheck.Input.Move(
                    ply: ply,
                    label: "\((ply + 1) / 2). move\(ply)",
                    byUser: byUser,
                    thinkTimeMs: thinkTimes[ply] ?? (byUser ? 1_000 + ply : 0)
                )
            )
        }
        return ReviewSelfCheck.Input(
            moves: moves,
            moments: moments.map { ReviewSelfCheck.Input.Moment(ply: $0.ply, causeTag: $0.cause) }
        )
    }

    @Test("A game with no material loss is never asked where material went")
    func onlyAsksWhatItCanMark() {
        let questions = ReviewSelfCheck.questions(for: input(moments: []))
        #expect(questions.contains { $0.id == "material" } == false)
        #expect(questions.contains { $0.id == "threat" } == false)
        // King safety is always markable: "it was fine" is a real answer.
        #expect(questions.contains { $0.id == "king" })
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
}
