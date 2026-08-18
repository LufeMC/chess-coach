//
//  WeeklyFocus.swift
//  ClaudeKit
//

import Foundation

/// Input for the weekly review call.
///
/// A much smaller ask than the per-game one: no positions, no lines, so no
/// chess claims to verify — only the enum and coherence rules below.
public struct WeeklyFocusRequest: Codable, Sendable, Equatable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Leaks ordered by cost, biggest first.
    public var leakRanking: [Leak]
    /// How the tracked metrics moved this week.
    public var metricDeltas: [MetricDelta]
    /// How often the student answered guided-mode prompts correctly, by habit.
    public var guidedHitRates: [GuidedHitRate]
    public var currentHabitID: String?
    public var validationErrors: [CoachRequest.ValidationError]?

    public init(
        schemaVersion: Int = WeeklyFocusRequest.currentSchemaVersion,
        leakRanking: [Leak],
        metricDeltas: [MetricDelta],
        guidedHitRates: [GuidedHitRate],
        currentHabitID: String? = nil,
        validationErrors: [CoachRequest.ValidationError]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.leakRanking = leakRanking
        self.metricDeltas = metricDeltas
        self.guidedHitRates = guidedHitRates
        self.currentHabitID = currentHabitID
        self.validationErrors = validationErrors
    }

    public struct Leak: Codable, Sendable, Equatable {
        public var causeTag: String
        public var epLostPerGame: Double
        public var gamesAffected: Int
        public var trend: CoachRequest.Trend

        public init(causeTag: String, epLostPerGame: Double, gamesAffected: Int, trend: CoachRequest.Trend) {
            self.causeTag = causeTag
            self.epLostPerGame = epLostPerGame
            self.gamesAffected = gamesAffected
            self.trend = trend
        }
    }

    public struct MetricDelta: Codable, Sendable, Equatable {
        public var metricID: String
        public var previous: Double
        public var current: Double
        public var target: Double?

        public init(metricID: String, previous: Double, current: Double, target: Double? = nil) {
            self.metricID = metricID
            self.previous = previous
            self.current = current
            self.target = target
        }
    }

    public struct GuidedHitRate: Codable, Sendable, Equatable {
        public var habitID: String
        public var prompts: Int
        public var hits: Int

        public init(habitID: String, prompts: Int, hits: Int) {
            self.habitID = habitID
            self.prompts = prompts
            self.hits = hits
        }
    }

}

/// The weekly focus the model proposes.
public struct WeeklyFocusResponse: Codable, Sendable, Equatable {

    public enum Limits {
        public static let whyNow = 250
    }

    /// Exactly one habit. The app never runs two at once — a "focus" the
    /// student has to split is not a focus.
    public var focusHabit: String
    public var whyNow: String
    public var microGoal: MicroGoal
    public var drillMix: [Drill]

    public init(focusHabit: String, whyNow: String, microGoal: MicroGoal, drillMix: [Drill]) {
        self.focusHabit = focusHabit
        self.whyNow = whyNow
        self.microGoal = microGoal
        self.drillMix = drillMix
    }

    public struct MicroGoal: Codable, Sendable, Equatable {
        public var metricID: String
        public var target: Double
        public var window: Window

        public init(metricID: String, target: Double, window: Window) {
            self.metricID = metricID
            self.target = target
            self.window = window
        }
    }

    public enum Window: String, Codable, Sendable, CaseIterable {
        case perGame
        case perWeek
        case next10Games
    }

    public struct Drill: Codable, Sendable, Equatable {
        public var theme: String
        public var count: Int

        public init(theme: String, count: Int) {
            self.theme = theme
            self.count = count
        }
    }

}

/// Validates a weekly focus response.
///
/// Two rules the app enforces rather than trusts:
///
/// 1. `focusHabit` is one of the known habits — an unknown id selects no
///    drills, no metric and no progress tracking, and would fail silently.
/// 2. `microGoal.metricID` belongs to `focusHabit` — a goal measured by a
///    metric the habit does not move can never be met by doing the habit, and
///    the student would practise all week for a bar that never fills.
public struct WeeklyFocusValidator: Sendable {

    private let habitIDs: Set<String>

    public init(habitIDs: Set<String> = CoachingVocabulary.habitIDs) {
        self.habitIDs = habitIDs
    }

    public func validate(_ response: WeeklyFocusResponse) -> VerificationResult {
        var violations: [Violation] = []

        guard habitIDs.contains(response.focusHabit) else {
            violations.append(Violation(
                momentID: nil,
                field: "focusHabit",
                kind: .unknownVocabulary,
                message: "\"\(response.focusHabit)\" is not an allowed habit id (allowed: \(habitIDs.sorted().joined(separator: ", ")))"
            ))
            // Without a valid habit the metric rule has nothing to check
            // against, so report one clear problem instead of two confusing
            // ones.
            return .from(violations + limitViolations(response))
        }

        if !CoachingVocabulary.metric(response.microGoal.metricID, belongsTo: response.focusHabit) {
            let allowed = CoachingVocabulary.habit(id: response.focusHabit)?.metricIDs.joined(separator: ", ") ?? ""
            violations.append(Violation(
                momentID: nil,
                field: "microGoal.metricID",
                kind: .unknownVocabulary,
                message: "metric \"\(response.microGoal.metricID)\" does not belong to habit \(response.focusHabit) (its metrics: \(allowed))"
            ))
        }

        if response.drillMix.isEmpty {
            violations.append(Violation(
                momentID: nil,
                field: "drillMix",
                kind: .shape,
                message: "drillMix is empty; the week needs at least one drill theme"
            ))
        }

        if response.drillMix.contains(where: { $0.count <= 0 }) {
            violations.append(Violation(
                momentID: nil,
                field: "drillMix",
                kind: .shape,
                message: "every drill theme needs a count of at least 1"
            ))
        }

        return .from(violations + limitViolations(response))
    }

    private func limitViolations(_ response: WeeklyFocusResponse) -> [Violation] {
        var violations: [Violation] = []

        if response.whyNow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(momentID: nil, field: "whyNow", kind: .shape, message: "whyNow is empty"))
        } else if response.whyNow.count > WeeklyFocusResponse.Limits.whyNow {
            violations.append(Violation(
                momentID: nil,
                field: "whyNow",
                kind: .characterLimit,
                message: "whyNow is \(response.whyNow.count) characters, limit is \(WeeklyFocusResponse.Limits.whyNow)"
            ))
        }

        return violations
    }

}

/// System prompt for the weekly review.
public enum WeeklyFocusPrompt {

    public static let contract: String = """
        You are the coach inside a chess improvement app, choosing what one \
        student works on for the coming week.

        You are given their leak ranking (what is costing them the most), how \
        their tracked metrics moved, and how often they answered guided-mode \
        prompts correctly. You are not given games or positions, so make no \
        claims about specific moves.

        Rules, in priority order:

        1. Choose exactly ONE habit, from the enum in the schema. Not two, not a \
        blend. If last week's habit has not taken hold — the guided hit rate is \
        still low, or its metric barely moved — keeping it is usually the right \
        answer, and saying so plainly is better than inventing novelty.
        2. The micro-goal must be measured by a metric that belongs to the habit \
        you chose. A goal the habit cannot move is worse than no goal.
        3. Make the target reachable in one week from where they are now. Reference \
        the current value, not an ideal.
        4. `whyNow` explains the choice to the student in their terms: what it is \
        costing them, and what will change. Direct and warm, second person, no \
        flattery, no exclamation marks.
        5. The drill mix supports the habit. Themes should be the ones that \
        rehearse the chosen behaviour, not a survey of everything they are weak at.
        6. Return only JSON conforming to the schema.
        """

    public static func systemBlocks() -> [MessageRequest.SystemBlock] {
        [MessageRequest.SystemBlock(text: contract, cacheControl: .ephemeral)]
    }

    public static func userMessage(for request: WeeklyFocusRequest, encoder: JSONEncoder) throws -> String {
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)

        var text = """
            This week's data:

            \(json)
            """

        if let errors = request.validationErrors, !errors.isEmpty {
            let list = errors.map { "- \($0.field): \($0.problem)" }.joined(separator: "\n")
            text += """


                Your previous answer was rejected for these reasons:

                \(list)

                Answer again, fixing exactly these problems.
                """
        }

        return text
    }

}
