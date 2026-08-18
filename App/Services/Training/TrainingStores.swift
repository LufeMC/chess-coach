//
//  TrainingStores.swift
//  ChessCoach
//

import Database
import Foundation

// MARK: - Why these protocols exist
//
// The persistence layer vends `Database`'s repository structs through an
// `AppDatabase` composition root that is owned elsewhere. Depending on that type
// directly would make every service here untestable without a real SQLite file
// and un-buildable until that root lands.
//
// So each service depends on the *narrowest* protocol that describes what it
// actually needs, `Database`'s repositories conform to those protocols with no
// adapter code (the signatures already match), and an in-memory implementation
// of each protocol ships alongside so the services compile, preview and test
// standalone.
//
// The protocols deliberately use `Database`'s own row types rather than
// re-modelling them. Re-modelling would buy nothing — these are already plain
// `Sendable` value types — and would add a mapping layer that can drift.

// MARK: - SRS

protocol SRSCardStore: Sendable {
    func save(_ card: SRSCard) throws
    func card(id: SRSCard.ID) throws -> SRSCard?
    func card(puzzleID: String) throws -> SRSCard?
    func card(positionKey: Int64) throws -> SRSCard?
    func due(at date: Date, limit: Int) throws -> [SRSCard]
    func dueCount(at date: Date) throws -> Int
    func recordReview(
        card: SRSCard,
        rating: Database.ReviewRating,
        stateBefore: Database.SRSState,
        elapsedDays: Double,
        scheduledDays: Double,
        durationMs: Int,
        reviewedAt: Date
    ) throws
    func reviews(forCard cardID: SRSCard.ID) throws -> [ReviewLog]
}

extension SRSRepository: SRSCardStore {}

// MARK: - Puzzles

protocol PuzzleCorpus: Sendable {
    func puzzles(
        ratingRange: ClosedRange<Int>,
        themes: ThemeMask,
        limit: Int,
        excluding excludedIDs: Set<Puzzle.ID>
    ) throws -> [Puzzle]
    func puzzle(id: Puzzle.ID) throws -> Puzzle?
    func count(ratingRange: ClosedRange<Int>) throws -> Int
    func ratingBounds() throws -> ClosedRange<Int>?
}

extension PuzzleRepository: PuzzleCorpus {}

// MARK: - Metrics

protocol MetricStore: Sendable {
    func upsert(key: String, window: String, value: Double, sampleCount: Int, updatedAt: Date) throws
    func metric(key: String, window: String) throws -> SkillMetric?
    func all() throws -> [SkillMetric]
}

extension MetricsRepository: MetricStore {}

// MARK: - Daily loop

protocol DailyLoopStore: Sendable {
    func loop(for day: String) throws -> DailyLoop
    @discardableResult
    func update(day: String, _ transform: (inout DailyLoop) -> Void) throws -> DailyLoop
    func recent(limit: Int) throws -> [DailyLoop]
}

extension DailyLoopRepository: DailyLoopStore {}

// MARK: - Settings

protocol AppSettingsStore: Sendable {
    func current() throws -> AppSettings
    @discardableResult
    func update(_ transform: (inout AppSettings) -> Void) throws -> AppSettings
}

extension SettingsRepository: AppSettingsStore {}

// MARK: - Moments

protocol MomentStore: Sendable {
    func moments(forGame gameID: Game.ID) throws -> [Database.Moment]
    func pending(limit: Int) throws -> [Database.Moment]
    func setStatus(_ status: MomentStatus, forMoment id: Database.Moment.ID) throws
    func setCoachText(_ text: String?, forMoment id: Database.Moment.ID) throws
}

extension MomentRepository: MomentStore {}

// MARK: - Games

protocol GameStore: Sendable {
    func recent(limit: Int) throws -> [Game]
    func game(id: Game.ID) throws -> Game?
    func moves(forGame gameID: Game.ID) throws -> [GameMove]
    func evals(forGame gameID: Game.ID) throws -> [PlyEval]
}

extension GameRepository: GameStore {}

// MARK: - Guided-mode prompts

/// One guided-mode prompt and whether the user answered it.
struct GuidedPromptRecord: Sendable, Hashable {
    var gameID: Game.ID
    /// `TrainingCore.Habit.rawValue`.
    var habit: String
    var hit: Bool

    init(gameID: Game.ID, habit: String, hit: Bool) {
        self.gameID = gameID
        self.habit = habit
        self.hit = hit
    }
}

/// Source of guided-mode prompt outcomes.
///
/// The curriculum gates `r2.threatAwareness` partly on
/// `guided.scanThreats.hitRate`, which is produced by the guided play mode and
/// has no table of its own yet. Rather than invent one here, the metric layer
/// asks this protocol; the default answers "no data", which
/// `Skill.evaluate(in:)` reports as *unmeasured* rather than *failed* — the
/// correct outcome for a user who has never played a guided game.
protocol GuidedPromptLog: Sendable {
    func prompts(forGames gameIDs: [Game.ID]) throws -> [GuidedPromptRecord]
}

/// The shipping default until guided mode persists its prompts.
struct EmptyGuidedPromptLog: GuidedPromptLog {
    func prompts(forGames gameIDs: [Game.ID]) throws -> [GuidedPromptRecord] { [] }
}

// MARK: - In-memory implementations

/// In-memory SRS store, for previews and tests.
///
/// A `final class` behind a lock rather than an actor: the protocol is
/// synchronous (because GRDB's is), so an actor could not conform.
final class InMemorySRSStore: SRSCardStore, @unchecked Sendable {

    private let lock = NSLock()
    private var cards: [SRSCard.ID: SRSCard] = [:]
    private var logs: [ReviewLog] = []

    init(cards: [SRSCard] = []) {
        for card in cards { self.cards[card.id] = card }
    }

    func save(_ card: SRSCard) throws {
        lock.withLock { cards[card.id] = card }
    }

    func card(id: SRSCard.ID) throws -> SRSCard? {
        lock.withLock { cards[id] }
    }

    func card(puzzleID: String) throws -> SRSCard? {
        lock.withLock { cards.values.first { $0.puzzleID == puzzleID } }
    }

    func card(positionKey: Int64) throws -> SRSCard? {
        lock.withLock { cards.values.first { $0.positionKey == positionKey } }
    }

    func due(at date: Date, limit: Int) throws -> [SRSCard] {
        lock.withLock {
            Array(cards.values.filter { $0.due <= date }.sorted { $0.due < $1.due }.prefix(limit))
        }
    }

    func dueCount(at date: Date) throws -> Int {
        lock.withLock { cards.values.filter { $0.due <= date }.count }
    }

    func recordReview(
        card: SRSCard,
        rating: Database.ReviewRating,
        stateBefore: Database.SRSState,
        elapsedDays: Double,
        scheduledDays: Double,
        durationMs: Int,
        reviewedAt: Date
    ) throws {
        lock.withLock {
            cards[card.id] = card
            logs.append(
                ReviewLog(
                    cardID: card.id,
                    reviewedAt: reviewedAt,
                    rating: rating.rawValue,
                    stateBefore: stateBefore.rawValue,
                    elapsedDays: elapsedDays,
                    scheduledDays: scheduledDays,
                    durationMs: durationMs
                )
            )
        }
    }

    func reviews(forCard cardID: SRSCard.ID) throws -> [ReviewLog] {
        lock.withLock { logs.filter { $0.cardID == cardID }.sorted { $0.reviewedAt < $1.reviewedAt } }
    }
}

/// In-memory puzzle corpus, for previews and tests.
struct InMemoryPuzzleCorpus: PuzzleCorpus {

    var puzzles: [Puzzle]

    init(puzzles: [Puzzle] = []) {
        self.puzzles = puzzles
    }

    func puzzles(
        ratingRange: ClosedRange<Int>,
        themes: ThemeMask,
        limit: Int,
        excluding excludedIDs: Set<Puzzle.ID>
    ) throws -> [Puzzle] {
        // Deterministic order, unlike the real corpus's `ORDER BY random()`.
        // Tests want repeatability; production wants variety, and the variety
        // lives in the query rather than in the caller.
        Array(
            puzzles
                .filter { ratingRange.contains($0.rating) }
                .filter { themes.isEmpty || $0.themes.intersects(themes) }
                .filter { !excludedIDs.contains($0.id) }
                .prefix(limit)
        )
    }

    func puzzle(id: Puzzle.ID) throws -> Puzzle? {
        puzzles.first { $0.id == id }
    }

    func count(ratingRange: ClosedRange<Int>) throws -> Int {
        puzzles.filter { ratingRange.contains($0.rating) }.count
    }

    func ratingBounds() throws -> ClosedRange<Int>? {
        guard
            let low = puzzles.map(\.rating).min(),
            let high = puzzles.map(\.rating).max()
        else { return nil }
        return low...high
    }
}

/// In-memory metric store, for previews and tests.
final class InMemoryMetricStore: MetricStore, @unchecked Sendable {

    private let lock = NSLock()
    private var rows: [String: SkillMetric] = [:]

    init() {}

    private func key(_ key: String, _ window: String) -> String { "\(key)|\(window)" }

    func upsert(key: String, window: String, value: Double, sampleCount: Int, updatedAt: Date) throws {
        lock.withLock {
            rows[self.key(key, window)] = SkillMetric(
                key: key,
                window: window,
                value: value,
                sampleCount: sampleCount,
                updatedAt: updatedAt
            )
        }
    }

    func metric(key: String, window: String) throws -> SkillMetric? {
        lock.withLock { rows[self.key(key, window)] }
    }

    func all() throws -> [SkillMetric] {
        lock.withLock { rows.values.sorted { $0.key < $1.key } }
    }
}

/// In-memory daily loop store, for previews and tests.
final class InMemoryDailyLoopStore: DailyLoopStore, @unchecked Sendable {

    private let lock = NSLock()
    private var loops: [String: DailyLoop] = [:]

    init() {}

    func loop(for day: String) throws -> DailyLoop {
        lock.withLock {
            if let existing = loops[day] { return existing }
            let fresh = DailyLoop(day: day)
            loops[day] = fresh
            return fresh
        }
    }

    @discardableResult
    func update(day: String, _ transform: (inout DailyLoop) -> Void) throws -> DailyLoop {
        var loop = try self.loop(for: day)
        transform(&loop)
        lock.withLock { loops[day] = loop }
        return loop
    }

    func recent(limit: Int) throws -> [DailyLoop] {
        lock.withLock { Array(loops.values.sorted { $0.day > $1.day }.prefix(limit)) }
    }
}

/// In-memory settings store, for previews and tests.
final class InMemoryAppSettingsStore: AppSettingsStore, @unchecked Sendable {

    private let lock = NSLock()
    private var settings: AppSettings

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    func current() throws -> AppSettings {
        lock.withLock { settings }
    }

    @discardableResult
    func update(_ transform: (inout AppSettings) -> Void) throws -> AppSettings {
        lock.withLock {
            transform(&settings)
            settings.id = AppSettings.singletonID
            return settings
        }
    }
}

/// In-memory moment store, for previews and tests.
final class InMemoryMomentStore: MomentStore, @unchecked Sendable {

    private let lock = NSLock()
    private var moments: [Database.Moment.ID: Database.Moment] = [:]

    init(moments: [Database.Moment] = []) {
        for moment in moments { self.moments[moment.id] = moment }
    }

    func moments(forGame gameID: Game.ID) throws -> [Database.Moment] {
        lock.withLock { moments.values.filter { $0.gameID == gameID }.sorted { $0.ply < $1.ply } }
    }

    func pending(limit: Int) throws -> [Database.Moment] {
        lock.withLock {
            Array(
                moments.values
                    .filter { $0.status == MomentStatus.new.rawValue }
                    .sorted { $0.score > $1.score }
                    .prefix(limit)
            )
        }
    }

    func setStatus(_ status: MomentStatus, forMoment id: Database.Moment.ID) throws {
        lock.withLock { moments[id]?.status = status.rawValue }
    }

    func setCoachText(_ text: String?, forMoment id: Database.Moment.ID) throws {
        lock.withLock { moments[id]?.coachText = text }
    }

    /// Test accessor.
    func moment(id: Database.Moment.ID) -> Database.Moment? {
        lock.withLock { moments[id] }
    }
}

/// In-memory game store, for previews and tests.
struct InMemoryGameStore: GameStore {

    var games: [Game] = []
    var movesByGame: [Game.ID: [GameMove]] = [:]
    var evalsByGame: [Game.ID: [PlyEval]] = [:]

    init(
        games: [Game] = [],
        movesByGame: [Game.ID: [GameMove]] = [:],
        evalsByGame: [Game.ID: [PlyEval]] = [:]
    ) {
        self.games = games
        self.movesByGame = movesByGame
        self.evalsByGame = evalsByGame
    }

    func recent(limit: Int) throws -> [Game] {
        Array(games.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    func game(id: Game.ID) throws -> Game? {
        games.first { $0.id == id }
    }

    func moves(forGame gameID: Game.ID) throws -> [GameMove] {
        (movesByGame[gameID] ?? []).sorted { $0.ply < $1.ply }
    }

    func evals(forGame gameID: Game.ID) throws -> [PlyEval] {
        (evalsByGame[gameID] ?? []).sorted { $0.ply < $1.ply }
    }
}
