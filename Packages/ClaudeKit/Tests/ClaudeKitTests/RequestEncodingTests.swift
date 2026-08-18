//
//  RequestEncodingTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

@Suite("Request encoding")
struct RequestEncodingTests {

    @Test("Headers carry the key, the API version and the content type")
    func headers() async throws {
        let recorder = RequestRecorder()
        let transport = MockTransport(onSend: { request in
            await recorder.record(request)
            return .json(Fixtures.messageJSON(text: "{}"))
        })

        let client = makeClient(transport: transport, apiKey: "sk-ant-abc")
        _ = try await client.send(MessageRequest(model: "claude-opus-5", maxTokens: 16, messages: [.init(role: .user, text: "hi")]))

        let request = await recorder.requests[0]
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-abc")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("An empty API key fails before any request is made")
    func missingKey() async throws {
        let transport = MockTransport(onSend: { _ in
            Issue.record("no request should be sent without a key")
            return .json("{}")
        })

        let client = makeClient(transport: transport, apiKey: "")

        await #expect(throws: ClaudeError.missingAPIKey) {
            _ = try await client.send(MessageRequest(model: "m", maxTokens: 1, messages: []))
        }
    }

    @Test("The last system block carries the ephemeral cache breakpoint")
    func systemCacheControl() throws {
        let blocks = CoachPrompt.systemBlocks(for: Fixtures.profile)

        #expect(blocks.count == 2)
        #expect(blocks[0].cacheControl == nil)
        #expect(blocks.last?.cacheControl == .ephemeral)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(blocks))

        #expect(json[0]?["type"]?.stringValue == "text")
        #expect(json[0]?["cache_control"] == nil)
        #expect(json[1]?["cache_control"]?["type"]?.stringValue == "ephemeral")
    }

    @Test("The system prompt is parameterised by rating, rung and habit")
    func systemPromptParameters() {
        let context = CoachPrompt.studentContext(for: Fixtures.profile)

        #expect(context.contains("1180"))
        #expect(context.contains("85"))
        #expect(context.contains("rung2"))
        #expect(context.contains("Tactical Vision"))
        #expect(context.contains("checkOpponentThreats"))
        #expect(context.contains("ignoredStandingThreatRate"))
    }

    @Test("output_config encodes the schema and the effort setting")
    func outputConfigEncoding() throws {
        let schema = CoachSchema.coachResponse(momentIDs: ["m1", "m2"])
        let request = MessageRequest(
            model: "claude-opus-5",
            maxTokens: 2048,
            system: CoachPrompt.systemBlocks(for: Fixtures.profile),
            messages: [.init(role: .user, text: "payload")],
            outputConfig: .init(format: .init(jsonSchema: schema), effort: .medium)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(request))

        #expect(json["max_tokens"]?.intValue == 2048)
        #expect(json["output_config"]?["effort"]?.stringValue == "medium")

        let format = try #require(json["output_config"]?["format"])
        #expect(format["type"]?.stringValue == "json_schema")

        let encodedSchema = try #require(format["schema"])
        #expect(encodedSchema["additionalProperties"]?.boolValue == false)
        #expect(encodedSchema["type"]?.stringValue == "object")

        let required = try #require(encodedSchema["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(Set(required) == ["gameNote", "momentNotes", "weeklyFocusSuggestion", "flags"])

        // The schema survives the JSON round trip unchanged — it is arbitrary
        // JSON, so nothing about it is enforced by the type system.
        #expect(encodedSchema == schema)
    }

    @Test("Every object in the schema is closed and fully required")
    func schemaIsStrict() throws {
        let schema = CoachSchema.coachResponse(momentIDs: ["m1"])

        func assertStrict(_ value: JSONValue, path: String) {
            guard let object = value.objectValue else { return }

            let isObjectSchema = object["type"]?.stringValue == "object"
                || (object["type"]?.arrayValue?.contains(.string("object")) ?? false)

            if isObjectSchema {
                #expect(object["additionalProperties"] == .bool(false), "\(path) is not closed")
                let properties = object["properties"]?.objectValue ?? [:]
                let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
                #expect(required == Set(properties.keys), "\(path) does not require every property")
            }

            // Recursing over every member reaches `properties`, `items` and
            // any nested schema without knowing the schema's shape.
            for (key, child) in object {
                assertStrict(child, path: "\(path).\(key)")
            }
        }

        assertStrict(schema, path: "root")

        // Moves are discrete fields, never prose.
        let moveRef = try #require(
            schema["properties"]?["momentNotes"]?["items"]?["properties"]?["keyLine"]?["properties"]?["moves"]?["items"]
        )
        let moveProperties = try #require(moveRef["properties"]?.objectValue)
        #expect(Set(moveProperties.keys) == ["san", "uci", "plyFromRoot"])

        // Optional fields stay required by being nullable.
        let alternative = try #require(schema["properties"]?["momentNotes"]?["items"]?["properties"]?["alternativeLine"])
        #expect(alternative["type"]?.arrayValue == [.string("object"), .string("null")])
    }

    @Test("The habit enum in the schema matches the verifier's vocabulary")
    func schemaHabitEnum() throws {
        let schema = CoachSchema.coachResponse(momentIDs: ["m1"])
        let values = try #require(
            schema["properties"]?["weeklyFocusSuggestion"]?["properties"]?["habitID"]?["enum"]?.arrayValue
        ).compactMap(\.stringValue)

        #expect(Set(values) == CoachingVocabulary.habitIDs)
    }

    @Test("Character limits in the schema match the limits the verifier enforces")
    func schemaLimits() throws {
        let schema = CoachSchema.coachResponse(momentIDs: ["m1"])
        let notes = try #require(schema["properties"]?["momentNotes"]?["items"]?["properties"])

        #expect(notes["question"]?["maxLength"]?.intValue == CoachResponse.Limits.question)
        #expect(notes["explanation"]?["maxLength"]?.intValue == CoachResponse.Limits.explanation)

        let gameNote = try #require(schema["properties"]?["gameNote"]?["properties"])
        #expect(gameNote["headline"]?["maxLength"]?.intValue == CoachResponse.Limits.headline)
        #expect(gameNote["body"]?["maxLength"]?.intValue == CoachResponse.Limits.body)
    }

    @Test("Caps trim the payload to three moments and eight-ply PVs")
    func capsApplied() {
        var longPV = Fixtures.momentOne
        longPV.engineLines[0].pvUCI = Array(repeating: "d2d4", count: 12)
        longPV.engineLines[0].pvSAN = Array(repeating: "d4", count: 12)

        let request = CoachRequest(
            profile: Fixtures.profile,
            game: Fixtures.game,
            moments: [longPV, Fixtures.momentTwo, Fixtures.momentOne, Fixtures.momentTwo]
        ).capped()

        #expect(request.moments.count == CoachRequest.Caps.maxMoments)
        #expect(request.moments[0].engineLines[0].pvUCI.count == CoachRequest.Caps.maxPVPlies)
        #expect(request.moments[0].engineLines[0].pvSAN.count == CoachRequest.Caps.maxPVPlies)
    }

    @Test("The repair turn echoes the violations back to the model")
    func repairTurnIncludesViolations() throws {
        var request = Fixtures.request()
        request.validationErrors = [
            .init(momentID: "m1", field: "keyLine.moves[2].uci", problem: "diverges from PV 0 at ply 2")
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let message = try CoachPrompt.userMessage(for: request, encoder: encoder)

        #expect(message.contains("rejected"))
        #expect(message.contains("diverges from PV 0 at ply 2"))
        #expect(message.contains("moment m1"))
    }

}
