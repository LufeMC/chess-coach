//
//  CoachService.swift
//  ClaudeKit
//

import Foundation

/// Coordinates a coaching call: build, send, verify, repair, fall back.
///
/// The policy, in one place because it is the part that has to be right:
///
/// - Verification failure is treated as a *correctable* mistake first. The
///   violations go back to the model as `validationErrors` and it gets one more
///   attempt. Models are good at fixing a named error and bad at avoiding one
///   they were only warned about in the abstract, and a second full call is
///   cheap next to showing a student a line that doesn't exist.
/// - A second failure is not correctable. At that point only the *offending*
///   moment's note is thrown away and replaced with a templated one; notes that
///   passed are kept. Discarding the whole response would punish the student
///   for the model's mistake on an unrelated position.
/// - Response-level problems (an unknown habit id, an over-long game note) are
///   repaired in place, since there is no per-moment unit to drop.
public actor CoachService {

    public struct Configuration: Sendable {
        public var model: String
        public var maxTokens: Int
        /// `.medium` for routine annotations; the weekly review is rarer and
        /// worth more thinking.
        public var coachEffort: MessageRequest.Effort
        public var weeklyFocusEffort: MessageRequest.Effort

        public init(
            model: String = "claude-opus-5",
            maxTokens: Int = 4096,
            coachEffort: MessageRequest.Effort = .medium,
            weeklyFocusEffort: MessageRequest.Effort = .high
        ) {
            self.model = model
            self.maxTokens = maxTokens
            self.coachEffort = coachEffort
            self.weeklyFocusEffort = weeklyFocusEffort
        }
    }

    /// The result of a coaching call, including what had to be repaired.
    ///
    /// The bookkeeping is not decoration: repair rates are the signal that the
    /// prompt has drifted from the schema or that a model update changed
    /// behaviour, and they are invisible if the service silently patches
    /// things up.
    public struct Outcome: Sendable, Equatable {
        public var response: CoachResponse
        /// How many model calls it took (1 or 2).
        public var attempts: Int
        /// Moments whose note came from the template rather than the model.
        public var templatedMomentIDs: [String]
        /// What was wrong on the final attempt, before repair.
        public var violations: [Violation]
        /// True when the model's output could not be used at all.
        public var usedFullFallback: Bool

        public init(
            response: CoachResponse,
            attempts: Int,
            templatedMomentIDs: [String] = [],
            violations: [Violation] = [],
            usedFullFallback: Bool = false
        ) {
            self.response = response
            self.attempts = attempts
            self.templatedMomentIDs = templatedMomentIDs
            self.violations = violations
            self.usedFullFallback = usedFullFallback
        }
    }

    public struct WeeklyFocusOutcome: Sendable, Equatable {
        public var response: WeeklyFocusResponse
        public var attempts: Int
        public var violations: [Violation]
        public var usedFallback: Bool

        public init(
            response: WeeklyFocusResponse,
            attempts: Int,
            violations: [Violation] = [],
            usedFallback: Bool = false
        ) {
            self.response = response
            self.attempts = attempts
            self.violations = violations
            self.usedFallback = usedFallback
        }
    }

    private let client: any MessageSending
    private let verifier: CoachVerifier
    private let fallback: FallbackRenderer
    private let weeklyValidator: WeeklyFocusValidator
    private let configuration: Configuration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        client: any MessageSending,
        verifier: CoachVerifier = CoachVerifier(),
        fallback: FallbackRenderer = FallbackRenderer(),
        weeklyValidator: WeeklyFocusValidator = WeeklyFocusValidator(),
        configuration: Configuration = Configuration()
    ) {
        self.client = client
        self.verifier = verifier
        self.fallback = fallback
        self.weeklyValidator = weeklyValidator
        self.configuration = configuration

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    // MARK: - Coaching

    public func coach(_ request: CoachRequest) async throws -> Outcome {
        let capped = request.capped()

        var attemptRequest = capped
        var lastViolations: [Violation] = []
        var lastResponse: CoachResponse?

        for attempt in 1...2 {
            let response: CoachResponse
            do {
                response = try await callModel(attemptRequest)
            } catch let error as ClaudeError {
                // A malformed body is a contract violation like any other: the
                // first one earns a repair attempt, and a second leaves the
                // student with templated coaching rather than an error screen.
                // Transport and HTTP failures are different — nothing local can
                // fix them — so they propagate.
                guard case .decodingFailed(let detail) = error else { throw error }
                lastViolations = [Violation(
                    momentID: nil,
                    field: "(response)",
                    kind: .shape,
                    message: "the response was not valid JSON for the schema: \(detail)"
                )]
                if attempt == 1 {
                    attemptRequest = capped.withValidationErrors(lastViolations)
                }
                continue
            }

            lastResponse = response
            let result = verifier.verify(response: response, against: capped)

            switch result {
            case .valid:
                return Outcome(response: response, attempts: attempt, violations: [])
            case let .invalid(violations):
                lastViolations = violations
                if attempt == 1 {
                    attemptRequest = capped.withValidationErrors(violations)
                }
            }
        }

        guard let response = lastResponse else {
            // Both attempts failed to produce anything decodable.
            return Outcome(
                response: fallback.response(for: capped),
                attempts: 2,
                templatedMomentIDs: capped.moments.map(\.momentID),
                violations: lastViolations,
                usedFullFallback: true
            )
        }

        return repair(response: response, violations: lastViolations, request: capped)
    }

    /// Rebuilds a response, keeping every note that passed and templating the
    /// rest.
    func repair(response: CoachResponse, violations: [Violation], request: CoachRequest) -> Outcome {
        let offending = Set(violations.compactMap(\.momentID))
        let notesByID = Dictionary(
            response.momentNotes.map { ($0.momentID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var notes: [CoachResponse.MomentNote] = []
        var templated: [String] = []

        // Iterate the request, not the response: a note for a moment that was
        // never asked about is dropped entirely, and a missing note is
        // templated like a failed one.
        for moment in request.moments {
            if !offending.contains(moment.momentID), let note = notesByID[moment.momentID] {
                notes.append(note)
            } else if let note = fallback.note(for: moment) {
                notes.append(note)
                templated.append(moment.momentID)
            }
        }

        var repaired = response
        repaired.momentNotes = notes

        // Response-level repairs. Each one has no per-moment unit to drop, so
        // the value is corrected rather than discarded.
        let responseLevel = violations.filter { $0.momentID == nil }

        for violation in responseLevel {
            switch violation.field {
            case "weeklyFocusSuggestion.habitID":
                repaired.weeklyFocusSuggestion.habitID = fallback.fallbackHabitID(for: request)
            case "weeklyFocusSuggestion.rationale":
                repaired.weeklyFocusSuggestion.rationale = clamp(
                    repaired.weeklyFocusSuggestion.rationale,
                    to: CoachResponse.Limits.rationale
                )
            case "gameNote.headline":
                repaired.gameNote.headline = clamp(repaired.gameNote.headline, to: CoachResponse.Limits.headline)
            case "gameNote.body":
                repaired.gameNote.body = clamp(repaired.gameNote.body, to: CoachResponse.Limits.body)
            default:
                break
            }
        }

        if repaired.gameNote.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || repaired.gameNote.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let template = fallback.response(for: request)
            repaired.gameNote = template.gameNote
        }

        // Flags are derived, so they are recomputed rather than repaired: a
        // dispute whose note was just replaced no longer exists.
        repaired.flags.disagreesWithCauseTag = notes.filter { !$0.causeAffirmed }.map(\.momentID)

        return Outcome(
            response: repaired,
            attempts: 2,
            templatedMomentIDs: templated,
            violations: violations
        )
    }

    private func callModel(_ request: CoachRequest) async throws -> CoachResponse {
        let message = MessageRequest(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: CoachPrompt.systemBlocks(for: request.profile),
            messages: [
                .init(role: .user, text: try CoachPrompt.userMessage(for: request, encoder: encoder))
            ],
            outputConfig: MessageRequest.OutputConfig(
                format: MessageRequest.OutputFormat(
                    jsonSchema: CoachSchema.coachResponse(momentIDs: request.moments.map(\.momentID))
                ),
                effort: configuration.coachEffort
            )
        )

        let response = try await client.send(message)
        return try decode(CoachResponse.self, from: response)
    }

    // MARK: - Weekly focus

    public func weeklyFocus(_ request: WeeklyFocusRequest) async throws -> WeeklyFocusOutcome {
        var attemptRequest = request
        var lastViolations: [Violation] = []
        var lastResponse: WeeklyFocusResponse?

        for attempt in 1...2 {
            let response: WeeklyFocusResponse
            do {
                response = try await callWeeklyFocus(attemptRequest)
            } catch let error as ClaudeError {
                guard case .decodingFailed(let detail) = error else { throw error }
                lastViolations = [Violation(
                    momentID: nil,
                    field: "(response)",
                    kind: .shape,
                    message: "the response was not valid JSON for the schema: \(detail)"
                )]
                if attempt == 1 {
                    attemptRequest.validationErrors = lastViolations.map(CoachRequest.ValidationError.init)
                }
                continue
            }

            lastResponse = response

            switch weeklyValidator.validate(response) {
            case .valid:
                return WeeklyFocusOutcome(response: response, attempts: attempt)
            case let .invalid(violations):
                lastViolations = violations
                if attempt == 1 {
                    attemptRequest.validationErrors = violations.map(CoachRequest.ValidationError.init)
                }
            }
        }

        // No per-item fallback exists here — one habit is the whole answer — so
        // the app keeps the student on their current habit rather than
        // switching them to something it cannot track.
        return WeeklyFocusOutcome(
            response: fallbackWeeklyFocus(for: request, attempted: lastResponse),
            attempts: 2,
            violations: lastViolations,
            usedFallback: true
        )
    }

    private func callWeeklyFocus(_ request: WeeklyFocusRequest) async throws -> WeeklyFocusResponse {
        let message = MessageRequest(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: WeeklyFocusPrompt.systemBlocks(),
            messages: [
                .init(role: .user, text: try WeeklyFocusPrompt.userMessage(for: request, encoder: encoder))
            ],
            outputConfig: MessageRequest.OutputConfig(
                format: MessageRequest.OutputFormat(jsonSchema: CoachSchema.weeklyFocus()),
                effort: configuration.weeklyFocusEffort
            )
        )

        let response = try await client.send(message)
        return try decode(WeeklyFocusResponse.self, from: response)
    }

    /// Keeps the student on a valid habit when the model's pick is unusable.
    func fallbackWeeklyFocus(
        for request: WeeklyFocusRequest,
        attempted: WeeklyFocusResponse?
    ) -> WeeklyFocusResponse {
        let habitID: String = {
            if let current = request.currentHabitID, CoachingVocabulary.habitIDs.contains(current) {
                return current
            }
            if let attempted, CoachingVocabulary.habitIDs.contains(attempted.focusHabit) {
                return attempted.focusHabit
            }
            if let leak = request.leakRanking.first,
               let habit = CoachingVocabulary.habit(forCauseTag: leak.causeTag) {
                return habit.id
            }
            return CoachingVocabulary.habits[0].id
        }()

        let habit = CoachingVocabulary.habit(id: habitID)
        let metricID = habit?.metricIDs.first ?? attempted?.microGoal.metricID ?? habitID

        // Keep the model's target only when it was measuring the right thing.
        let target = attempted?.microGoal.metricID == metricID ? (attempted?.microGoal.target ?? 0) : 0
        let drills = attempted?.drillMix ?? []

        return WeeklyFocusResponse(
            focusHabit: habitID,
            whyNow: "Staying with \(habit?.title ?? habitID) this week — it is still the habit that costs you the most.",
            microGoal: .init(metricID: metricID, target: target, window: .perGame),
            drillMix: drills.isEmpty ? [.init(theme: habitID, count: 10)] : drills
        )
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from response: MessageResponse) throws -> T {
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8), !text.isEmpty else {
            throw ClaudeError.decodingFailed("the response contained no text")
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ClaudeError.decodingFailed(String(describing: error))
        }
    }

    /// Hard character clamp for a field that has to fit a layout.
    private func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

}

private extension CoachRequest {

    func withValidationErrors(_ violations: [Violation]) -> CoachRequest {
        var copy = self
        copy.validationErrors = violations.map(ValidationError.init)
        return copy
    }

}
