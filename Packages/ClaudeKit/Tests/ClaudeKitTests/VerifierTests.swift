//
//  VerifierTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

@Suite("Coach verification")
struct VerifierTests {

    private let verifier = CoachVerifier()

    // MARK: Happy path

    @Test("A well-formed response passes")
    func validResponsePasses() {
        let result = verifier.verify(response: Fixtures.response(), against: Fixtures.request())
        #expect(result == .valid)
    }

    @Test("A shorter prefix of a PV is still a prefix")
    func shortPrefixPasses() {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(sourcePVIndex: 0, moves: [.init(san: "d4", uci: "d2d4", plyFromRoot: 0)])

        let result = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        )
        #expect(result == .valid)
    }

    @Test("An alternative line from a second PV passes")
    func alternativeLinePasses() {
        var note = Fixtures.validNoteTwo
        note.alternativeLine = .init(
            sourcePVIndex: 1,
            moves: [
                .init(san: "Bc4", uci: "f1c4", plyFromRoot: 0),
                .init(san: "Nf6", uci: "g8f6", plyFromRoot: 1)
            ]
        )

        let result = verifier.verify(
            response: Fixtures.response(notes: [Fixtures.validNoteOne, note]),
            against: Fixtures.request()
        )
        #expect(result == .valid)
    }

    // MARK: Line divergence

    @Test("A line that diverges from the PV at ply 2 is caught, with both moves named")
    func divergenceAtPlyTwo() throws {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d4", uci: "d2d4", plyFromRoot: 0),
                .init(san: "d5", uci: "d7d5", plyFromRoot: 1),
                // PV has c2c4 here.
                .init(san: "e4", uci: "e2e4", plyFromRoot: 2)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.count == 1)
        let violation = try #require(violations.first)
        #expect(violation.kind == .lineDivergence)
        #expect(violation.momentID == "m1")
        #expect(violation.field == "momentNotes[0].keyLine.moves[2].uci")
        #expect(violation.message == "keyLine for m1 diverges from PV 0 at ply 2: model wrote e2e4, PV has c2c4")
    }

    @Test("A line that skips a ply of the PV is caught at the gap")
    func gapInLineCaught() throws {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d4", uci: "d2d4", plyFromRoot: 0),
                // d7d5 skipped.
                .init(san: "c4", uci: "c2c4", plyFromRoot: 2)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .lineDivergence)
        #expect(violation.message.contains("at ply 1"))
        #expect(violation.message.contains("model wrote c2c4, PV has d7d5"))
    }

    @Test("A line that does not start at the root is caught")
    func lineMustStartAtRoot() throws {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d5", uci: "d7d5", plyFromRoot: 1),
                .init(san: "c4", uci: "c2c4", plyFromRoot: 2)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .lineDivergence)
        #expect(violation.message.contains("at ply 0"))
    }

    @Test("A line longer than the PV is caught")
    func lineTooLong() throws {
        var note = Fixtures.validNoteTwo
        note.keyLine = .init(
            sourcePVIndex: 1,  // two plies only
            moves: [
                .init(san: "Bc4", uci: "f1c4", plyFromRoot: 0),
                .init(san: "Nf6", uci: "g8f6", plyFromRoot: 1),
                .init(san: "Nf3", uci: "g1f3", plyFromRoot: 2)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [Fixtures.validNoteOne, note]),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .lineTooLong)
        #expect(violation.message.contains("the line has 3 moves but the PV has 2"))
    }

    @Test("An out-of-range sourcePVIndex is caught")
    func sourcePVIndexOutOfRange() throws {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(sourcePVIndex: 5, moves: [.init(san: "d4", uci: "d2d4", plyFromRoot: 0)])

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.count == 1)
        let violation = try #require(violations.first)
        #expect(violation.kind == .pvIndexOutOfRange)
        #expect(violation.message == "keyLine for m1 names sourcePVIndex 5 but valid indices are 0...1")
    }

    @Test("A mismatched plyFromRoot is caught even when the move itself is right")
    func plyIndexMismatch() throws {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d4", uci: "d2d4", plyFromRoot: 0),
                .init(san: "d5", uci: "d7d5", plyFromRoot: 4)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .plyIndexMismatch)
    }

    // MARK: SAN re-derivation

    @Test("A valid UCI paired with a hallucinated SAN is caught by replaying the line")
    func validUCIWrongSAN() throws {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                // The UCI is copied faithfully; the SAN says something else
                // entirely, and the SAN is what the student reads.
                .init(san: "Nf3", uci: "d2d4", plyFromRoot: 0),
                .init(san: "d5", uci: "d7d5", plyFromRoot: 1)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.count == 1)
        let violation = try #require(violations.first)
        #expect(violation.kind == .sanMismatch)
        #expect(violation.field == "momentNotes[0].keyLine.moves[0].san")
        #expect(violation.message == "keyLine for m1 has the wrong SAN at ply 0: d2d4 is d4 in this position, model wrote Nf3")
    }

    @Test("SAN mismatch is caught deeper in the line, where the position has moved on")
    func wrongSANLaterInLine() throws {
        var note = Fixtures.validNoteTwo
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "Nf3", uci: "g1f3", plyFromRoot: 0),
                // b8c6 is Nc6, not "Nxe5".
                .init(san: "Nxe5", uci: "b8c6", plyFromRoot: 1)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [Fixtures.validNoteOne, note]),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .sanMismatch)
        #expect(violation.message.contains("b8c6 is Nc6 in this position"))
    }

    @Test("Annotation glyphs on a copied SAN are not treated as a different move")
    func annotationGlyphsTolerated() {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(sourcePVIndex: 0, moves: [.init(san: "d4!", uci: "d2d4", plyFromRoot: 0)])

        let result = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        )
        #expect(result == .valid)
    }

    @Test("A UCI that isn't legal in the position it claims is caught")
    func illegalMoveCaught() throws {
        var moment = Fixtures.momentOne
        // A PV the engine could not have produced: the second move is illegal.
        moment.engineLines[0] = .init(
            label: .best,
            evalCp: 25,
            pvSAN: ["d4", "Qh8"],
            pvUCI: ["d2d4", "d8h8"]
        )

        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d4", uci: "d2d4", plyFromRoot: 0),
                .init(san: "Qh8", uci: "d8h8", plyFromRoot: 1)
            ]
        )

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note]),
            against: Fixtures.request(moments: [moment])
        ).violations

        let violation = try #require(violations.first { $0.kind == .illegalMove })
        #expect(violation.message.contains("is not legal in the position reached at this point"))
    }

    @Test("An unparseable fenBefore fails closed rather than passing unverified")
    func invalidFENFailsClosed() throws {
        var moment = Fixtures.momentOne
        moment.fenBefore = "not a fen"

        let violations = verifier.verify(
            response: Fixtures.response(notes: [Fixtures.validNoteOne]),
            against: Fixtures.request(moments: [moment])
        ).violations

        #expect(violations.contains { $0.kind == .unverifiablePosition })
    }

    // MARK: Notation in questions

    @Test("A question that names a legal move is caught")
    func notationInQuestionCaught() throws {
        var note = Fixtures.validNoteOne
        note.question = "What happens if you play d4 here instead?"

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.count == 1)
        let violation = try #require(violations.first)
        #expect(violation.kind == .notationInQuestion)
        #expect(violation.field == "momentNotes[0].question")
        #expect(violation.message.contains("\"d4\""))
    }

    @Test("Piece notation in a question is caught too")
    func pieceNotationInQuestionCaught() throws {
        var note = Fixtures.validNoteTwo
        note.question = "Would Nf3 have been calmer than bringing the queen out?"

        let violations = verifier.verify(
            response: Fixtures.response(notes: [Fixtures.validNoteOne, note]),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .notationInQuestion)
        #expect(violation.message.contains("\"Nf3\""))
    }

    @Test("UCI notation in a question is caught")
    func uciNotationInQuestionCaught() throws {
        var note = Fixtures.validNoteOne
        note.question = "Did you look at d2d4 before choosing a flank pawn?"

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.contains { $0.kind == .notationInQuestion })
    }

    @Test("Notation-shaped text that is not a legal move does not false-positive", arguments: [
        // Square names in ordinary coaching prose. `a1`, `h8` and `b1` all
        // match the SAN regex but none of them is a legal move here.
        "Which of your pieces is still stuck on b1, and what would free it?",
        "Your rook on a1 has no open file yet — what would give it one?",
        "Is the long diagonal towards h8 something you can use later?",
        // Words and phrases that brush against the pattern.
        "Be honest: did you count the defenders before deciding?",
        "Once the centre is fixed, which side of the board is yours?"
    ])
    func noFalsePositives(question: String) {
        var note = Fixtures.validNoteOne
        note.question = question

        let result = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        )

        #expect(result == .valid, "false positive on: \(question)")
    }

    @Test("The scan matches on shape first and only then filters by legality")
    func scanIsTwoStep() throws {
        let replay = try #require(MoveReplay(fen: Fixtures.startFEN))
        let prose = "Which of your pieces is still stuck on b1, and what would free it?"

        // The regex does fire on the square name — the test below is not
        // passing because nothing matched.
        #expect(MoveNotationScanner.matches(in: prose, replay: replay).contains { $0.text == "b1" })
        // It is filtered out because no legal move here is written "b1".
        #expect(MoveNotationScanner.illegalToMention(in: prose, replay: replay).isEmpty)

        // The same sentence with a move that *is* legal is caught.
        let giveaway = "Which of your pieces is still stuck on b4, and what would free it?"
        #expect(MoveNotationScanner.illegalToMention(in: giveaway, replay: replay).map(\.text) == ["b4"])
    }

    @Test("Castling notation in a question is only a violation when castling is legal")
    func castlingNotationOnlyWhenLegal() {
        var note = Fixtures.validNoteOne
        // Castling is not available in the start position, so this is prose.
        note.question = "Was O-O still available to you at that point?"

        let result = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        )
        #expect(result == .valid)
    }

    // MARK: Vocabulary, limits, shape

    @Test("An unknown habit id is caught")
    func unknownHabitCaught() throws {
        let violations = verifier.verify(
            response: Fixtures.response(habitID: "checkThreats"),
            against: Fixtures.request()
        ).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .unknownVocabulary)
        #expect(violation.field == "weeklyFocusSuggestion.habitID")
        #expect(violation.momentID == nil)
    }

    @Test("An unknown suggested cause tag is caught")
    func unknownSuggestedTagCaught() {
        var note = Fixtures.validNoteOne
        note.causeAffirmed = false
        note.suggestedTag = "playedTooFast"

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.contains { $0.kind == .unknownVocabulary && $0.momentID == "m1" })
    }

    @Test("Character limits are enforced on every capped field")
    func characterLimitsCaught() throws {
        var note = Fixtures.validNoteOne
        note.explanation = String(repeating: "a", count: CoachResponse.Limits.explanation + 1)

        let response = Fixtures.response(
            notes: [note, Fixtures.validNoteTwo],
            headline: String(repeating: "b", count: CoachResponse.Limits.headline + 10)
        )

        let violations = verifier.verify(response: response, against: Fixtures.request()).violations

        #expect(violations.count == 2)
        #expect(violations.allSatisfy { $0.kind == .characterLimit })
        #expect(violations.contains { $0.message == "gameNote.headline is 130 characters, limit is 120" })
        #expect(violations.contains { $0.field == "momentNotes[0].explanation" })
    }

    @Test("A note for a moment that was never sent is caught")
    func unknownMomentIDCaught() throws {
        var note = Fixtures.validNoteOne
        note.momentID = "m9"

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.contains { $0.kind == .shape && $0.message.contains("is not one of the moments") })
        // ...and m1 is now missing a note.
        #expect(violations.contains { $0.momentID == "m1" && $0.message.contains("no note was returned") })
    }

    @Test("A missing note is caught")
    func missingNoteCaught() {
        let violations = verifier.verify(
            response: Fixtures.response(notes: [Fixtures.validNoteOne]),
            against: Fixtures.request()
        ).violations

        #expect(violations == [
            Violation(momentID: "m2", field: "momentNotes", kind: .shape, message: "no note was returned for moment m2")
        ])
    }

    @Test("Disputing the cause tag without suggesting a better one is caught")
    func disputeWithoutSuggestionCaught() {
        var note = Fixtures.validNoteOne
        note.causeAffirmed = false
        note.suggestedTag = nil

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo]),
            against: Fixtures.request()
        ).violations

        #expect(violations.contains { $0.field == "momentNotes[0].suggestedTag" })
    }

    @Test("Every violation from a bad response is reported, not just the first")
    func violationsAreCollected() {
        var note = Fixtures.validNoteOne
        note.question = "Should you have played d4 instead?"
        note.keyLine = .init(sourcePVIndex: 9, moves: [.init(san: "d4", uci: "d2d4", plyFromRoot: 0)])

        let violations = verifier.verify(
            response: Fixtures.response(notes: [note, Fixtures.validNoteTwo], habitID: "nope"),
            against: Fixtures.request()
        ).violations

        #expect(violations.count == 3)
        #expect(Set(violations.map(\.kind)) == [.pvIndexOutOfRange, .notationInQuestion, .unknownVocabulary])
    }

    // MARK: Promotion handling

    @Test("A promotion line replays and re-derives its SAN")
    func promotionLine() {
        let moment = CoachRequest.Moment(
            momentID: "p1",
            ply: 80,
            // White pawn on b7, kings far apart: b7b8q promotes without check,
            // so the canonical SAN carries no suffix to hide behind.
            fenBefore: "8/1P6/8/8/k7/8/8/7K w - - 0 1",
            phase: .endgame,
            playedSAN: "Kg1",
            playedUCI: "h1g1",
            bestSAN: "b8=Q",
            bestUCI: "b7b8q",
            deltaEP: 0.9,
            judgment: .missedWin,
            causeTag: "endgameTechnique",
            stepTag: "endgame",
            thinkTimeMs: 1_000,
            criticalityGap: 0.5,
            engineLines: [
                .init(label: .best, evalCp: 900, pvSAN: ["b8=Q"], pvUCI: ["b7b8q"])
            ]
        )

        var note = Fixtures.validNoteOne
        note.momentID = "p1"
        note.keyLine = .init(sourcePVIndex: 0, moves: [.init(san: "b8=Q", uci: "b7b8q", plyFromRoot: 0)])

        let result = CoachVerifier().verify(
            response: Fixtures.response(notes: [note]),
            against: Fixtures.request(moments: [moment])
        )

        #expect(result == .valid)
    }

}
