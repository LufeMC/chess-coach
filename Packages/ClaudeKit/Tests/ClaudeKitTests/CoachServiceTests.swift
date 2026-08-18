//
//  CoachServiceTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

/// A `MessageSending` stub that replays canned model output in order.
private actor ScriptedModel: MessageSending {

    private var responses: [String]
    private(set) var requests: [MessageRequest] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    var callCount: Int { requests.count }

    func send(_ request: MessageRequest) async throws -> MessageResponse {
        requests.append(request)
        let body = responses.isEmpty ? "{}" : responses.removeFirst()
        return MessageResponse(
            id: "msg_\(requests.count)",
            model: "claude-opus-5",
            content: [.text(body)],
            stopReason: .endTurn
        )
    }

    /// The JSON payload of the user turn for a given call.
    func userText(at index: Int) -> String {
        requests[index].messages.first?.content.compactMap(\.text).joined() ?? ""
    }

}

private func json(_ response: CoachResponse) -> String {
    String(decoding: try! JSONEncoder().encode(response), as: UTF8.self)
}

@Suite("Coach service policy")
struct CoachServiceTests {

    /// A note for m1 that quotes a line diverging from the PV.
    private var badNoteOne: CoachResponse.MomentNote {
        var note = Fixtures.validNoteOne
        note.keyLine = .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d4", uci: "d2d4", plyFromRoot: 0),
                .init(san: "Nf6", uci: "g8f6", plyFromRoot: 1)
            ]
        )
        return note
    }

    @Test("A valid first answer is used as-is, with one model call")
    func validFirstAttempt() async throws {
        let model = ScriptedModel([json(Fixtures.response())])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())

        #expect(outcome.attempts == 1)
        #expect(outcome.templatedMomentIDs.isEmpty)
        #expect(outcome.violations.isEmpty)
        #expect(outcome.response.momentNotes.count == 2)
        #expect(await model.callCount == 1)
    }

    @Test("A violation triggers exactly one repair attempt, with the violations attached")
    func repairsOnce() async throws {
        let model = ScriptedModel([
            json(Fixtures.response(notes: [badNoteOne, Fixtures.validNoteTwo])),
            json(Fixtures.response())
        ])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())

        #expect(outcome.attempts == 2)
        #expect(outcome.templatedMomentIDs.isEmpty)
        #expect(outcome.violations.isEmpty)
        #expect(await model.callCount == 2)

        // The second call carried the verifier's complaint verbatim.
        let repairText = await model.userText(at: 1)
        #expect(repairText.contains("validationErrors"))
        #expect(repairText.contains("diverges from PV 0 at ply 1"))
        #expect(await model.userText(at: 0).contains("validationErrors") == false)
    }

    @Test("After two failures only the offending moment is templated; valid notes survive")
    func fallbackIsPerMoment() async throws {
        let bad = json(Fixtures.response(notes: [badNoteOne, Fixtures.validNoteTwo]))
        let model = ScriptedModel([bad, bad])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())

        #expect(outcome.attempts == 2)
        #expect(outcome.templatedMomentIDs == ["m1"])
        #expect(outcome.response.momentNotes.count == 2)

        // m2 kept the model's own words.
        let noteTwo = try #require(outcome.response.momentNotes.first { $0.momentID == "m2" })
        #expect(noteTwo == Fixtures.validNoteTwo)

        // m1 was replaced by the template: canned question, engine's own line.
        let noteOne = try #require(outcome.response.momentNotes.first { $0.momentID == "m1" })
        #expect(noteOne.question == FallbackRenderer.questionBank["openingPrinciple"])
        #expect(noteOne.explanation == "The engine preferred d4: d4 d5 c4 e6")
        #expect(noteOne.keyLine.moves.map(\.uci) == ["d2d4", "d7d5", "c2c4", "e7e6"])
    }

    @Test("The repaired response passes verification")
    func repairedResponseIsValid() async throws {
        let bad = json(Fixtures.response(notes: [badNoteOne, Fixtures.validNoteTwo]))
        let model = ScriptedModel([bad, bad])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())
        let result = CoachVerifier().verify(response: outcome.response, against: Fixtures.request())

        #expect(result == .valid)
    }

    @Test("A response-level violation is repaired in place, not by dropping notes")
    func responseLevelRepair() async throws {
        let bad = json(Fixtures.response(habitID: "notAHabit"))
        let model = ScriptedModel([bad, bad])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())

        #expect(outcome.templatedMomentIDs.isEmpty)
        #expect(outcome.response.momentNotes.count == 2)
        // Falls back to the habit the student is already on.
        #expect(outcome.response.weeklyFocusSuggestion.habitID == "checkOpponentThreats")
        #expect(CoachVerifier().verify(response: outcome.response, against: Fixtures.request()) == .valid)
    }

    @Test("A note for a moment that was never sent is dropped entirely")
    func unknownMomentNoteDropped() async throws {
        var stray = Fixtures.validNoteOne
        stray.momentID = "m99"

        let bad = json(Fixtures.response(notes: [stray, Fixtures.validNoteTwo]))
        let model = ScriptedModel([bad, bad])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())

        #expect(outcome.response.momentNotes.map(\.momentID) == ["m1", "m2"])
        #expect(outcome.templatedMomentIDs == ["m1"])
    }

    @Test("Unparseable model output earns one retry, then a fully templated response")
    func fullFallbackOnGarbage() async throws {
        let model = ScriptedModel(["not json at all", "still not json"])
        let service = CoachService(client: model)

        let outcome = try await service.coach(Fixtures.request())

        #expect(outcome.usedFullFallback)
        #expect(outcome.attempts == 2)
        #expect(outcome.response.momentNotes.count == 2)
        #expect(CoachVerifier().verify(response: outcome.response, against: Fixtures.request()) == .valid)
    }

    @Test("The request is capped before it is sent")
    func requestIsCappedBeforeSending() async throws {
        let model = ScriptedModel([json(Fixtures.response())])
        let service = CoachService(client: model)

        var longPV = Fixtures.momentOne
        longPV.engineLines[0].pvUCI = Array(repeating: "d2d4", count: 12)
        longPV.engineLines[0].pvSAN = Array(repeating: "d4", count: 12)

        _ = try? await service.coach(
            CoachRequest(
                profile: Fixtures.profile,
                game: Fixtures.game,
                moments: [longPV, Fixtures.momentTwo, Fixtures.momentOne, Fixtures.momentTwo]
            )
        )

        let sent = await model.userText(at: 0)
        // Four moments in, three out; nine "d2d4" entries in, eight out.
        #expect(sent.components(separatedBy: "\"momentID\"").count - 1 == 3)
    }

    @Test("The system prompt and schema go out on every call")
    func promptAndSchemaAttached() async throws {
        let model = ScriptedModel([json(Fixtures.response())])
        let service = CoachService(client: model)
        _ = try await service.coach(Fixtures.request())

        let request = await model.requests[0]
        #expect(request.system?.count == 2)
        #expect(request.system?.last?.cacheControl == .ephemeral)
        #expect(request.outputConfig?.effort == .medium)
        #expect(request.outputConfig?.format?.type == "json_schema")
        #expect(request.model == "claude-opus-5")
    }

}

@Suite("Fallback rendering")
struct FallbackTests {

    @Test("A templated note is verifiable by construction")
    func templatedNotePasses() throws {
        let renderer = FallbackRenderer()
        let request = Fixtures.request()

        let notes = request.moments.compactMap { renderer.note(for: $0) }
        #expect(notes.count == 2)

        var response = Fixtures.response(notes: notes)
        response.flags.disagreesWithCauseTag = []

        #expect(CoachVerifier().verify(response: response, against: request) == .valid)
    }

    @Test("Every canned question survives the notation scan in a real position")
    func cannedQuestionsContainNoNotation() {
        let replay = MoveReplay(fen: Fixtures.startFEN)

        for (tag, question) in FallbackRenderer.questionBank {
            let matches = MoveNotationScanner.illegalToMention(in: question, replay: replay)
            #expect(matches.isEmpty, "question for \(tag) contains move notation: \(matches)")
        }

        #expect(MoveNotationScanner.illegalToMention(in: FallbackRenderer.defaultQuestion, replay: replay).isEmpty)
    }

    @Test("There is a question for every cause tag the app can produce")
    func questionBankCoversEveryCauseTag() {
        for tag in CoachingVocabulary.causeTags {
            #expect(FallbackRenderer.questionBank[tag] != nil, "no fallback question for \(tag)")
        }
    }

    @Test("An unknown cause tag still gets a question")
    func unknownTagFallsBack() {
        #expect(FallbackRenderer().question(forCauseTag: "somethingNew") == FallbackRenderer.defaultQuestion)
    }

    @Test("The preview shows at most six plies")
    func previewIsCapped() throws {
        var moment = Fixtures.momentOne
        moment.engineLines[0].pvSAN = ["d4", "d5", "c4", "e6", "Nc3", "Nf6", "Bg5", "Be7"]
        moment.engineLines[0].pvUCI = ["d2d4", "d7d5", "c2c4", "e7e6", "b1c3", "g8f6", "c1g5", "f8e7"]

        let note = try #require(FallbackRenderer().note(for: moment))

        #expect(note.keyLine.moves.count == FallbackRenderer.previewPlies)
        #expect(note.explanation == "The engine preferred d4: d4 d5 c4 e6 Nc3 Nf6")
        #expect(CoachVerifier().verify(
            response: Fixtures.response(notes: [note]),
            against: Fixtures.request(moments: [moment])
        ) == .valid)
    }

    @Test("A moment with no engine line produces no note rather than an empty one")
    func noEngineLineNoNote() {
        var moment = Fixtures.momentOne
        moment.engineLines = []

        #expect(FallbackRenderer().note(for: moment) == nil)
    }

}
