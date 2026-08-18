//
//  CoachCoordinator.swift
//  ChessCoach
//

import ClaudeKit
import Database
import Foundation
import Observation
import TrainingCore

/// App-layer wiring around `ClaudeKit.CoachService`.
///
/// Deliberately *not* a second coaching service. `ClaudeKit` already owns the
/// part that has to be right — build the prompt, call the model, verify every
/// quoted line against the engine's PV, repair once, fall back per moment — and
/// re-implementing any of that here would give the app two answers to the
/// question "is this coaching text safe to show". This type does the four things
/// that are genuinely the app's job:
///
/// 1. Decide whether the coach is available at all (is there a key?).
/// 2. Turn stored rows into a `CoachRequest` and the answer back into stored
///    rows.
/// 3. Stream, so text appears as it is generated rather than after a long
///    silence.
/// 4. Apply the user's model and effort settings.
@MainActor
@Observable
final class CoachCoordinator {

    // MARK: Availability

    /// Whether coaching can run.
    ///
    /// A first-class state rather than an error, because "you have not added an
    /// API key" is a normal condition for a fresh install and an error dialog on
    /// launch is the wrong way to say it. The Settings screen owns key entry;
    /// this only reads.
    enum Availability: Equatable, Sendable {
        case unknown
        case available
        case unavailable(Reason)

        enum Reason: Equatable, Sendable {
            /// No key stored. The UI offers to add one.
            case noAPIKey
            /// The keychain itself refused — an entitlement problem, not a
            /// missing key. Told apart because the user action is different.
            case keychainUnavailable(String)
        }

        var isAvailable: Bool { self == .available }
    }

    /// What a streaming coaching pass emits.
    enum Event: Sendable {
        /// Provisional text, straight from the model and **not yet verified**.
        case partial([MomentTextFragment])
        /// The verified, repaired, persisted result.
        case finished(CoachService.Outcome)
        case failed(String)
    }

    // MARK: Dependencies

    private nonisolated let keychain: KeychainStore
    private nonisolated let settings: any AppSettingsStore
    private nonisolated let moments: any MomentStore
    private nonisolated let metrics: any MetricStore
    private nonisolated let clock: @Sendable () -> Date
    private nonisolated let makeClient: @Sendable (KeychainStore, ClaudeClient.Configuration) -> ClaudeClient

    init(
        keychain: KeychainStore = KeychainStore(),
        settings: any AppSettingsStore,
        moments: any MomentStore,
        metrics: any MetricStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        makeClient: @escaping @Sendable (KeychainStore, ClaudeClient.Configuration) -> ClaudeClient = {
            ClaudeClient(keyProvider: $0, configuration: $1)
        }
    ) {
        self.keychain = keychain
        self.settings = settings
        self.moments = moments
        self.metrics = metrics
        self.clock = clock
        self.makeClient = makeClient
    }

    // MARK: Observable state

    private(set) var availability: Availability = .unknown
    private(set) var isCoaching = false
    /// Provisional per-moment text while a call is in flight.
    private(set) var fragments: [MomentTextFragment] = []
    private(set) var lastOutcome: CoachService.Outcome?
    private(set) var lastError: String?

    /// Re-reads the keychain. Safe to call on launch and after Settings closes.
    func refreshAvailability() {
        do {
            let key = try keychain.load()
            availability = (key?.isEmpty == false) ? .available : .unavailable(.noAPIKey)
        } catch let error as KeychainStore.KeychainError where error.isEntitlementFailure {
            availability = .unavailable(.keychainUnavailable(String(describing: error)))
        } catch {
            availability = .unavailable(.noAPIKey)
        }
    }

    // MARK: Coaching

    /// Runs a coaching pass and persists the result.
    ///
    /// - Returns: `nil` when the coach is unavailable — which is not an error
    ///   and must not be presented as one.
    @discardableResult
    func coach(_ inputs: CoachRequestBuilder.Inputs) async -> CoachService.Outcome? {
        var outcome: CoachService.Outcome?
        for await event in coachStream(inputs) {
            switch event {
            case .partial:
                break
            case let .finished(result):
                outcome = result
            case .failed:
                break
            }
        }
        return outcome
    }

    /// Runs a coaching pass, emitting text as it arrives.
    ///
    /// The partial fragments are the *unverified* model output and are marked as
    /// such: they exist so the student sees words appearing instead of a
    /// spinner. The `finished` event carries the text that is actually true —
    /// verified against the engine lines, with any rejected note replaced by a
    /// template — and the UI must prefer it once it lands.
    func coachStream(_ inputs: CoachRequestBuilder.Inputs) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await self.run(inputs, emitting: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ inputs: CoachRequestBuilder.Inputs, emitting continuation: AsyncStream<Event>.Continuation) async {
        if availability == .unknown { refreshAvailability() }
        guard availability.isAvailable else {
            continuation.yield(.failed("The coach is not configured."))
            return
        }

        isCoaching = true
        fragments = []
        lastError = nil
        defer { isCoaching = false }

        let stored = (try? settings.current()) ?? AppSettings()
        let request = CoachRequestBuilder.build(inputs)

        // Raw text deltas leave the transport on whatever thread the URL session
        // used; they are funnelled through a stream so the scanner and the
        // observable state stay on the main actor with no locking.
        let (deltas, deltaContinuation) = AsyncStream<String>.makeStream()
        let relay = StreamingMessageRelay(
            client: makeClient(keychain, clientConfiguration(stored)),
            onDelta: { deltaContinuation.yield($0) }
        )

        let scanning = Task { @MainActor [weak self] in
            var scanner = PartialCoachTextScanner()
            for await delta in deltas {
                let current = scanner.consume(delta)
                self?.fragments = current
                continuation.yield(.partial(current))
            }
        }

        let service = CoachService(client: relay, configuration: serviceConfiguration(stored))

        do {
            let outcome = try await service.coach(request)
            deltaContinuation.finish()
            await scanning.value

            persist(outcome)
            lastOutcome = outcome
            continuation.yield(.finished(outcome))
        } catch {
            deltaContinuation.finish()
            await scanning.value
            let message = String(describing: error)
            lastError = message
            continuation.yield(.failed(message))
        }
    }

    /// Writes the verified notes back onto their moments.
    ///
    /// Plain text, not JSON: `Moment.coachText` is read by the review UI and by
    /// anything else that wants a human-readable note, and a column that
    /// sometimes contains a serialised object is a trap for every future reader.
    /// The structured note — including the key line — stays available on
    /// ``lastOutcome`` for as long as the app is running.
    private func persist(_ outcome: CoachService.Outcome) {
        for note in outcome.response.momentNotes {
            guard let id = UUID(uuidString: note.momentID) else { continue }
            let text = [note.question, note.explanation]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            try? moments.setCoachText(text, forMoment: id)
            try? moments.setStatus(.reviewed, forMoment: id)
        }
    }

    // MARK: Weekly focus

    /// Key for the rotation clock. Stored in `skillMetrics` like every other
    /// single-number piece of app state.
    static let weeklyFocusLastRunKey = "coach.weeklyFocusLastRunAt"

    /// Whether the weekly focus call is due.
    ///
    /// Rotation, not per-game: the weekly review is the expensive call and its
    /// answer is a *week's* homework. Running it after every game would cost
    /// seven times as much to produce the same answer, and would let one bad
    /// game rewrite the week.
    func isWeeklyFocusDue(now: Date? = nil, period: TimeInterval = 7 * 86_400) -> Bool {
        let moment = now ?? clock()
        guard let last = metrics.counter(Self.weeklyFocusLastRunKey) else { return true }
        return moment.timeIntervalSince1970 - last.value >= period
    }

    /// Asks the model for the week's habit, and validates the answer.
    ///
    /// Two layers of validation, both necessary:
    ///
    /// 1. `ClaudeKit.WeeklyFocusValidator` (inside `CoachService`) checks the
    ///    answer is a known habit id with a metric that belongs to it.
    /// 2. This method checks the habit is one the **current rung actually
    ///    measures**. A habit that passes layer 1 can still be out of bounds
    ///    here: coaching a rung-4 conversion habit to a rung-1 player means a
    ///    week of work that no gauge in the app will move.
    ///
    /// Anything that fails either layer falls back to `FocusSelector`'s own
    /// choice, which is by construction on-rung.
    func weeklyFocus(
        leaks: [Leak],
        metricDeltas: [WeeklyFocusRequest.MetricDelta] = [],
        guidedHitRates: [WeeklyFocusRequest.GuidedHitRate] = [],
        rung: Int,
        fallback: WeeklyFocus,
        ladder: [Rung] = Curriculum.default
    ) async -> WeeklyFocus {
        if availability == .unknown { refreshAvailability() }
        guard availability.isAvailable else { return fallback }

        let stored = (try? settings.current()) ?? AppSettings()
        let request = WeeklyFocusRequest(
            leakRanking: leaks.prefix(5).map { leak in
                WeeklyFocusRequest.Leak(
                    causeTag: leak.causeTag.rawValue,
                    epLostPerGame: leak.epLostPerGame,
                    gamesAffected: leak.count,
                    trend: CoachVocabularyBridge.trend(forDelta: leak.deltaVsPreviousWeek)
                )
            },
            metricDeltas: metricDeltas,
            guidedHitRates: guidedHitRates,
            currentHabitID: CoachVocabularyBridge.habitID(for: fallback.habit)
        )

        let service = CoachService(
            client: makeClient(keychain, clientConfiguration(stored)),
            configuration: serviceConfiguration(stored)
        )

        do {
            let outcome = try await service.weeklyFocus(request)
            try? metrics.set(
                Self.weeklyFocusLastRunKey,
                value: clock().timeIntervalSince1970,
                sampleCount: 1,
                at: clock()
            )

            guard
                !outcome.usedFallback,
                let habit = CoachVocabularyBridge.habit(forID: outcome.response.focusHabit, rung: rung),
                ladder.first(where: { $0.id == rung })?.habits.contains(habit) == true
            else { return fallback }

            var chosen = fallback
            chosen.habit = habit
            chosen.epLostPerGame = leaks.first { $0.habit == habit }?.epLostPerGame ?? fallback.epLostPerGame
            chosen.primaryCauseTag = leaks.first { $0.habit == habit }?.causeTag ?? fallback.primaryCauseTag
            return chosen
        } catch {
            lastError = String(describing: error)
            return fallback
        }
    }

    // MARK: Configuration

    /// Model and effort come from settings so the user can trade cost for
    /// quality. The defaults — `claude-opus-5` at medium effort — are the app's,
    /// set on the settings row itself.
    private nonisolated func clientConfiguration(_ stored: AppSettings) -> ClaudeClient.Configuration {
        ClaudeClient.Configuration(
            defaultModel: stored.claudeModel,
            defaultEffort: MessageRequest.Effort(rawValue: stored.effort) ?? .medium
        )
    }

    private nonisolated func serviceConfiguration(_ stored: AppSettings) -> CoachService.Configuration {
        let effort = MessageRequest.Effort(rawValue: stored.effort) ?? .medium
        return CoachService.Configuration(
            model: stored.claudeModel,
            coachEffort: effort,
            // The weekly review runs once a week and decides what the user works
            // on for the next seven days. It is worth one step more thinking
            // than a per-game annotation, whatever the routine setting is.
            weeklyFocusEffort: effort == .low ? .medium : .high
        )
    }
}
