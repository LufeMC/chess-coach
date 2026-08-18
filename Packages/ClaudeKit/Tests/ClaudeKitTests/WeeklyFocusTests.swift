//
//  WeeklyFocusTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

private actor ScriptedWeekly: MessageSending {

    private var responses: [String]
    private(set) var requests: [MessageRequest] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    var callCount: Int { requests.count }

    func send(_ request: MessageRequest) async throws -> MessageResponse {
        requests.append(request)
        let body = responses.isEmpty ? "{}" : responses.removeFirst()
        return MessageResponse(id: "msg", model: "claude-opus-5", content: [.text(body)], stopReason: .endTurn)
    }

}

@Suite("Weekly focus")
struct WeeklyFocusTests {

    private static func request() -> WeeklyFocusRequest {
        WeeklyFocusRequest(
            leakRanking: [
                .init(causeTag: "ignoredStandingThreat", epLostPerGame: 0.31, gamesAffected: 7, trend: .flat),
                .init(causeTag: "hungMovedPiece", epLostPerGame: 0.19, gamesAffected: 4, trend: .improving)
            ],
            metricDeltas: [
                .init(metricID: "ignoredStandingThreatRate", previous: 0.51, current: 0.44, target: 0.2)
            ],
            guidedHitRates: [
                .init(habitID: "checkOpponentThreats", prompts: 22, hits: 12)
            ],
            currentHabitID: "checkOpponentThreats"
        )
    }

    private static func response(
        habit: String = "checkOpponentThreats",
        metric: String = "ignoredStandingThreatRate",
        whyNow: String = "You are still missing threats that were already on the board; this is the cheapest half point available to you."
    ) -> WeeklyFocusResponse {
        WeeklyFocusResponse(
            focusHabit: habit,
            whyNow: whyNow,
            microGoal: .init(metricID: metric, target: 0.3, window: .perGame),
            drillMix: [.init(theme: "hangingPieces", count: 12), .init(theme: "threatSpotting", count: 18)]
        )
    }

    @Test("A coherent weekly focus passes")
    func validPasses() {
        #expect(WeeklyFocusValidator().validate(Self.response()) == .valid)
    }

    @Test("An unknown habit is caught")
    func unknownHabitCaught() throws {
        let violations = WeeklyFocusValidator().validate(Self.response(habit: "beBetterAtChess")).violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .unknownVocabulary)
        #expect(violation.field == "focusHabit")
    }

    @Test("A micro-goal measured by a metric from a different habit is caught")
    func metricMustBelongToHabit() throws {
        // A real metric, but one that belongs to the endgame habit.
        let violations = WeeklyFocusValidator()
            .validate(Self.response(metric: "endgameConversionRate"))
            .violations

        let violation = try #require(violations.first)
        #expect(violation.field == "microGoal.metricID")
        #expect(violation.message.contains("does not belong to habit checkOpponentThreats"))
        #expect(violation.message.contains("ignoredStandingThreatRate"))
    }

    @Test("Every habit's own metrics are accepted", arguments: CoachingVocabulary.habits)
    func everyHabitAcceptsItsMetrics(habit: CoachingVocabulary.Habit) {
        for metric in habit.metricIDs {
            #expect(CoachingVocabulary.metric(metric, belongsTo: habit.id))
        }
    }

    @Test("whyNow has a character limit")
    func whyNowLimit() throws {
        let violations = WeeklyFocusValidator()
            .validate(Self.response(whyNow: String(repeating: "x", count: WeeklyFocusResponse.Limits.whyNow + 1)))
            .violations

        let violation = try #require(violations.first)
        #expect(violation.kind == .characterLimit)
    }

    @Test("An empty drill mix is caught")
    func emptyDrillMix() {
        var response = Self.response()
        response.drillMix = []

        #expect(WeeklyFocusValidator().validate(response).violations.contains { $0.field == "drillMix" })
    }

    @Test("The service retries once, then keeps the student on their current habit")
    func serviceFallsBackToCurrentHabit() async throws {
        let bad = String(decoding: try JSONEncoder().encode(Self.response(habit: "inventedHabit")), as: UTF8.self)
        let model = ScriptedWeekly([bad, bad])
        let service = CoachService(client: model)

        let outcome = try await service.weeklyFocus(Self.request())

        #expect(outcome.attempts == 2)
        #expect(outcome.usedFallback)
        #expect(outcome.response.focusHabit == "checkOpponentThreats")
        #expect(WeeklyFocusValidator().validate(outcome.response) == .valid)
        #expect(await model.callCount == 2)
    }

    @Test("A valid answer is returned on the first call")
    func serviceHappyPath() async throws {
        let good = String(decoding: try JSONEncoder().encode(Self.response()), as: UTF8.self)
        let model = ScriptedWeekly([good])
        let service = CoachService(client: model)

        let outcome = try await service.weeklyFocus(Self.request())

        #expect(outcome.attempts == 1)
        #expect(!outcome.usedFallback)
        #expect(outcome.response.focusHabit == "checkOpponentThreats")
        #expect(outcome.response.drillMix.count == 2)
    }

    @Test("The weekly call runs at higher effort than routine annotations")
    func weeklyUsesHigherEffort() async throws {
        let good = String(decoding: try JSONEncoder().encode(Self.response()), as: UTF8.self)
        let model = ScriptedWeekly([good])
        let service = CoachService(client: model)
        _ = try await service.weeklyFocus(Self.request())

        let request = await model.requests[0]
        #expect(request.outputConfig?.effort == .high)
        #expect(request.system?.last?.cacheControl == .ephemeral)
    }

    @Test("The weekly schema constrains the habit and window enums")
    func schemaEnums() throws {
        let schema = CoachSchema.weeklyFocus()

        let habits = try #require(schema["properties"]?["focusHabit"]?["enum"]?.arrayValue).compactMap(\.stringValue)
        #expect(Set(habits) == CoachingVocabulary.habitIDs)

        let windows = try #require(
            schema["properties"]?["microGoal"]?["properties"]?["window"]?["enum"]?.arrayValue
        ).compactMap(\.stringValue)
        #expect(Set(windows) == Set(WeeklyFocusResponse.Window.allCases.map(\.rawValue)))
    }

}
