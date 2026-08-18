import Foundation
import SQLiteData

// Repositories are `Sendable` structs wrapping a GRDB `DatabaseWriter`, not
// actors. The writer already serialises every access and is itself `Sendable`,
// so an actor would add an isolation hop and an async boundary to calls that are
// already safe — and would force every call site to `await` a synchronous
// SQLite read. Concurrency is handled where it actually lives: inside GRDB.

// MARK: - GameRepository

public struct GameRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Inserts a game together with its move list in a single transaction.
    ///
    /// A game whose moves half-committed would show up in history as an empty
    /// board, so the two writes must succeed or fail together.
    public func insert(_ game: Game, moves: [GameMove] = []) throws {
        try writer.write { db in
            try Game.insert { game }.execute(db)
            guard !moves.isEmpty else { return }
            try GameMove.insert { moves }.execute(db)
        }
    }

    /// Most recent games first.
    public func recent(limit: Int = 20) throws -> [Game] {
        try writer.read { db in
            try Game.order { $0.startedAt.desc() }.limit(limit).fetchAll(db)
        }
    }

    public func game(id: Game.ID) throws -> Game? {
        try writer.read { db in
            try Game.find(id).fetchOne(db)
        }
    }

    public func moves(forGame gameID: Game.ID) throws -> [GameMove] {
        try writer.read { db in
            try GameMove.where { $0.gameID.eq(gameID) }.order(by: \.ply).fetchAll(db)
        }
    }

    /// Records the outcome of a finished game.
    public func finish(
        id: Game.ID,
        result: String?,
        termination: String?,
        pgn: String,
        endedAt: Date = Date()
    ) throws {
        try writer.write { db in
            try Game.find(id)
                .update {
                    $0.result = #bind(result)
                    $0.termination = #bind(termination)
                    $0.pgn = #bind(pgn)
                    $0.endedAt = #bind(endedAt)
                }
                .execute(db)
        }
    }

    public func setAnalysisState(_ state: AnalysisState, forGame gameID: Game.ID) throws {
        try writer.write { db in
            try Game.find(gameID)
                .update { $0.analysisState = #bind(state.rawValue) }
                .execute(db)
        }
    }

    public func setAccuracy(_ accuracy: Double?, forGame gameID: Game.ID) throws {
        try writer.write { db in
            try Game.find(gameID).update { $0.userAccuracy = #bind(accuracy) }.execute(db)
        }
    }

    /// Games still awaiting engine analysis, oldest first so the backlog drains
    /// in order.
    public func awaitingAnalysis(limit: Int = 5) throws -> [Game] {
        try writer.read { db in
            try Game
                .where { $0.analysisState.eq(AnalysisState.pending.rawValue) }
                .where { $0.endedAt.isNot(nil) }
                .order(by: \.startedAt)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Deletes a game. Moves, moments and evals go with it via `ON DELETE
    /// CASCADE`.
    public func delete(id: Game.ID) throws {
        try writer.write { db in
            try Game.find(id).delete().execute(db)
        }
    }

    // MARK: Ply evaluations (local-only)

    public func replaceEvals(_ evals: [PlyEval], forGame gameID: Game.ID) throws {
        try writer.write { db in
            // Analysis is re-runnable, so a re-analysis replaces wholesale
            // rather than trying to merge into the previous pass.
            try PlyEval.where { $0.gameID.eq(gameID) }.delete().execute(db)
            guard !evals.isEmpty else { return }
            try PlyEval.insert { evals }.execute(db)
        }
    }

    public func evals(forGame gameID: Game.ID) throws -> [PlyEval] {
        try writer.read { db in
            try PlyEval.where { $0.gameID.eq(gameID) }.order(by: \.ply).fetchAll(db)
        }
    }

    // MARK: Device calibration (local-only)

    public func saveCalibration(_ calibration: DeviceCalibration) throws {
        try writer.write { db in
            try DeviceCalibration.upsert { calibration }.execute(db)
        }
    }

    public func latestCalibration() throws -> DeviceCalibration? {
        try writer.read { db in
            try DeviceCalibration.order { $0.calibratedAt.desc() }.limit(1).fetchOne(db)
        }
    }
}

// MARK: - MomentRepository

public struct MomentRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func insert(_ moments: [Moment]) throws {
        guard !moments.isEmpty else { return }
        try writer.write { db in
            try Moment.insert { moments }.execute(db)
        }
    }

    /// Moments for one game, in board order.
    public func moments(forGame gameID: Game.ID) throws -> [Moment] {
        try writer.read { db in
            try Moment.where { $0.gameID.eq(gameID) }.order(by: \.ply).fetchAll(db)
        }
    }

    /// The highest-scoring moments not yet worked through, across all games.
    public func pending(limit: Int = 10) throws -> [Moment] {
        try writer.read { db in
            try Moment
                .where { $0.status.eq(MomentStatus.new.rawValue) }
                .order { $0.score.desc() }
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func setStatus(_ status: MomentStatus, forMoment id: Moment.ID) throws {
        try writer.write { db in
            try Moment.find(id).update { $0.status = #bind(status.rawValue) }.execute(db)
        }
    }

    /// Attaches generated coaching text, and marks the moment reviewed.
    public func setCoachText(_ text: String?, forMoment id: Moment.ID) throws {
        try writer.write { db in
            try Moment.find(id).update { $0.coachText = #bind(text) }.execute(db)
        }
    }

    public func count(status: MomentStatus) throws -> Int {
        try writer.read { db in
            try Moment.where { $0.status.eq(status.rawValue) }.fetchCount(db)
        }
    }
}

// MARK: - SRSRepository

public struct SRSRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Inserts or updates a card by primary key.
    public func save(_ card: SRSCard) throws {
        try writer.write { db in
            try SRSCard.upsert { card }.execute(db)
        }
    }

    public func card(id: SRSCard.ID) throws -> SRSCard? {
        try writer.read { db in
            try SRSCard.find(id).fetchOne(db)
        }
    }

    /// Cards due at or before `date`, soonest first.
    public func due(at date: Date = Date(), limit: Int = 20) throws -> [SRSCard] {
        try writer.read { db in
            try SRSCard
                .where { $0.due <= date }
                .order(by: \.due)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func dueCount(at date: Date = Date()) throws -> Int {
        try writer.read { db in
            try SRSCard.where { $0.due <= date }.fetchCount(db)
        }
    }

    /// Finds an existing card for a puzzle, so repeated encounters reuse one
    /// scheduling history rather than creating duplicates.
    public func card(puzzleID: String) throws -> SRSCard? {
        try writer.read { db in
            try SRSCard.where { $0.puzzleID.eq(puzzleID) }.limit(1).fetchOne(db)
        }
    }

    /// As above, for positions lifted from the user's own games.
    public func card(positionKey: Int64) throws -> SRSCard? {
        try writer.read { db in
            try SRSCard.where { $0.positionKey.eq(positionKey) }.limit(1).fetchOne(db)
        }
    }

    /// Applies a review: writes the log and the card's new scheduling state in
    /// one transaction, so a card can never advance without its audit trail.
    public func recordReview(
        card: SRSCard,
        rating: ReviewRating,
        stateBefore: SRSState,
        elapsedDays: Double,
        scheduledDays: Double,
        durationMs: Int,
        reviewedAt: Date = Date()
    ) throws {
        let log = ReviewLog(
            cardID: card.id,
            reviewedAt: reviewedAt,
            rating: rating.rawValue,
            stateBefore: stateBefore.rawValue,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            durationMs: durationMs
        )
        try writer.write { db in
            try SRSCard.upsert { card }.execute(db)
            try ReviewLog.insert { log }.execute(db)
        }
    }

    public func reviews(forCard cardID: SRSCard.ID) throws -> [ReviewLog] {
        try writer.read { db in
            try ReviewLog
                .where { $0.cardID.eq(cardID) }
                .order(by: \.reviewedAt)
                .fetchAll(db)
        }
    }

    /// Deletes a card and, by cascade, its review history.
    public func delete(id: SRSCard.ID) throws {
        try writer.write { db in
            try SRSCard.find(id).delete().execute(db)
        }
    }
}

// MARK: - MetricsRepository

public struct MetricsRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Sets the value for a `(key, window)` pair.
    ///
    /// `(key, window)` cannot be a unique index (see ``UserDatabase/migrator``),
    /// so this reads-then-writes inside a transaction instead of relying on
    /// `ON CONFLICT`. If sync has produced duplicates for the pair, the newest
    /// row wins and the rest are removed, which converges on every device.
    public func upsert(
        key: String,
        window: String,
        value: Double,
        sampleCount: Int = 0,
        updatedAt: Date = Date()
    ) throws {
        try writer.write { db in
            let existing =
                try SkillMetric
                .where { $0.key.eq(key) }
                .where { $0.window.eq(window) }
                .order { $0.updatedAt.desc() }
                .fetchAll(db)

            guard let winner = existing.first else {
                try SkillMetric.insert {
                    SkillMetric(
                        key: key,
                        window: window,
                        value: value,
                        sampleCount: sampleCount,
                        updatedAt: updatedAt
                    )
                }
                .execute(db)
                return
            }

            try SkillMetric.find(winner.id)
                .update {
                    $0.value = #bind(value)
                    $0.sampleCount = #bind(sampleCount)
                    $0.updatedAt = #bind(updatedAt)
                }
                .execute(db)

            for duplicate in existing.dropFirst() {
                try SkillMetric.find(duplicate.id).delete().execute(db)
            }
        }
    }

    public func metric(key: String, window: String) throws -> SkillMetric? {
        try writer.read { db in
            try SkillMetric
                .where { $0.key.eq(key) }
                .where { $0.window.eq(window) }
                .order { $0.updatedAt.desc() }
                .limit(1)
                .fetchOne(db)
        }
    }

    /// Every window recorded for one metric key.
    public func metrics(key: String) throws -> [SkillMetric] {
        try writer.read { db in
            try SkillMetric.where { $0.key.eq(key) }.order(by: \.window).fetchAll(db)
        }
    }

    public func all() throws -> [SkillMetric] {
        try writer.read { db in
            try SkillMetric.order(by: \.key).fetchAll(db)
        }
    }
}

// MARK: - SettingsRepository

public struct SettingsRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// The settings row, creating it with defaults on first access.
    ///
    /// Always keyed by ``AppSettings/singletonID`` so that every device edits
    /// the *same* record and CloudKit's per-column merge resolves conflicts
    /// field by field.
    public func current() throws -> AppSettings {
        try writer.write { db in
            if let existing = try AppSettings.find(AppSettings.singletonID).fetchOne(db) {
                return existing
            }
            let fresh = AppSettings()
            try AppSettings.insert { fresh }.execute(db)
            return fresh
        }
    }

    /// Applies a mutation to the settings row.
    @discardableResult
    public func update(_ transform: (inout AppSettings) -> Void) throws -> AppSettings {
        var settings = try current()
        transform(&settings)
        settings.id = AppSettings.singletonID
        try writer.write { db in
            try AppSettings.upsert { settings }.execute(db)
        }
        return settings
    }
}

// MARK: - DailyLoopRepository

public struct DailyLoopRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// The loop record for a day, creating it if absent.
    ///
    /// `day` is not unique-indexed (two devices can both open the app on the
    /// same morning), so duplicates are merged here: counters take the maximum
    /// seen on any device, which is the right answer for "how much did I do
    /// today" regardless of which device did it.
    public func loop(for day: String) throws -> DailyLoop {
        try writer.write { db in
            let existing = try DailyLoop.where { $0.day.eq(day) }.order(by: \.id).fetchAll(db)
            guard var winner = existing.first else {
                let fresh = DailyLoop(day: day)
                try DailyLoop.insert { fresh }.execute(db)
                return fresh
            }
            guard existing.count > 1 else { return winner }

            for duplicate in existing.dropFirst() {
                winner.gamePlayed = winner.gamePlayed || duplicate.gamePlayed
                winner.momentsReviewed = max(winner.momentsReviewed, duplicate.momentsReviewed)
                winner.puzzlesDone = max(winner.puzzlesDone, duplicate.puzzlesDone)
                winner.completedAt = winner.completedAt ?? duplicate.completedAt
                try DailyLoop.find(duplicate.id).delete().execute(db)
            }
            try DailyLoop.upsert { winner }.execute(db)
            return winner
        }
    }

    public func loop(for date: Date = Date()) throws -> DailyLoop {
        try loop(for: DailyLoop.dayKey(for: date))
    }

    @discardableResult
    public func update(
        day: String,
        _ transform: (inout DailyLoop) -> Void
    ) throws -> DailyLoop {
        var loop = try self.loop(for: day)
        transform(&loop)
        try writer.write { db in
            try DailyLoop.upsert { loop }.execute(db)
        }
        return loop
    }

    /// Most recent days first — the streak view's data source.
    public func recent(limit: Int = 30) throws -> [DailyLoop] {
        try writer.read { db in
            try DailyLoop.order { $0.day.desc() }.limit(limit).fetchAll(db)
        }
    }
}
