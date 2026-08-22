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

    /// Records how the user did on the review's pre-engine questions.
    ///
    /// Also the "this game has been reviewed" flag — see ``Game/selfCheckScore``
    /// for why it is nullable.
    public func setSelfCheckScore(_ score: Int?, forGame gameID: Game.ID) throws {
        try writer.write { db in
            try Game.find(gameID).update { $0.selfCheckScore = #bind(score) }.execute(db)
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

    /// Unworked moments that earned a spaced-repetition card, best first.
    ///
    /// The scheduler cannot decide eligibility itself: it is settled during
    /// analysis from the length of the solution, the criticality gap and the
    /// cause tag, and none of that survives into the moment row except as the
    /// flag this reads. Recomputing it here would mean re-running the engine.
    public func srsEligible(limit: Int = 10) throws -> [Moment] {
        try writer.read { db in
            try Moment
                .where { $0.status.eq(MomentStatus.new.rawValue) }
                .where { $0.srsEligible }
                .order { $0.score.desc() }
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// How many of one game's moments are still worth reviewing.
    ///
    /// A count rather than a fetch: the Today screen needs the number on every
    /// load to size its promise, and decoding the moment payloads to get
    /// `count` would read the largest column in the table for a figure the
    /// index alone can answer.
    public func eligibleCount(forGame gameID: Game.ID) throws -> Int {
        try writer.read { db in
            try Moment
                .where { $0.gameID.eq(gameID) }
                .where { $0.status.eq(MomentStatus.new.rawValue) }
                .where { $0.srsEligible }
                .fetchCount(db)
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

    // MARK: Sample history

    /// Two sample values closer together than this are the same number arriving
    /// twice, not a movement worth a point on a chart.
    ///
    /// Float identity, not a significance threshold: the metrics this history
    /// tracks are stored doubles read straight back out, so anything larger
    /// would start swallowing real rating movement.
    private static let sampleEpsilon = 1e-6

    /// Records one observation into the append-only history — see
    /// ``MetricSample``.
    ///
    /// Two rules, and the interesting part is that they are deliberately
    /// different rules:
    ///
    /// * **A value that moved is stamped `measuredAt`**, the `updatedAt` of the
    ///   metric row it came from — for the playing rating, the end of the game
    ///   that moved it. Stamping it "now" would file every point at the moment
    ///   the user happened to open the app, which is not when they earned it.
    /// * **A value that did not move is stamped `now`, and kept at most once a
    ///   day.** "Still 1187 today" is a real observation, and it is what keeps a
    ///   flat month from emptying the chart's one-month window; recording it
    ///   fifty times because Profile was opened fifty times is not.
    ///
    /// Never files a sample behind the newest one already stored: a point out of
    /// order would draw a line that doubles back on itself.
    ///
    /// - Parameters:
    ///   - measuredAt: When the value was last written.
    ///   - now: The clock, as a parameter so tests need not sleep.
    ///   - calendar: Decides which local day a timestamp falls in.
    public func recordSample(
        key: String,
        window: String,
        value: Double,
        measuredAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        try writer.write { db in
            let newest =
                try MetricSample
                .where { $0.key.eq(key) }
                .where { $0.window.eq(window) }
                .order { $0.recordedAt.desc() }
                .limit(1)
                .fetchOne(db)

            let moved = newest.map { abs($0.value - value) >= Self.sampleEpsilon } ?? true
            let stamp = moved ? measuredAt : now
            let at = max(stamp, newest?.recordedAt ?? stamp)
            let day = DailyLoop.dayKey(for: at, calendar: calendar)

            guard moved || newest?.day != day else {
                try Self.convergeDuplicates(db, key: key, window: window, day: day, value: value)
                return
            }

            try MetricSample.insert {
                MetricSample(key: key, window: window, day: day, value: value, recordedAt: at)
            }
            .execute(db)
        }
    }

    /// Recorded observations of one metric, oldest first.
    ///
    /// `limit` counts back from the newest rather than forward from the oldest:
    /// a series that hit its cap must lose the distant past, not this week.
    public func samples(
        key: String,
        window: String,
        limit: Int = 5_000
    ) throws -> [MetricSample] {
        try writer.read { db in
            let newestFirst =
                try MetricSample
                .where { $0.key.eq(key) }
                .where { $0.window.eq(window) }
                .order { $0.recordedAt.desc() }
                .limit(limit)
                .fetchAll(db)
            return Array(newestFirst.reversed())
        }
    }

    /// Collapses rows two devices both wrote for the same day and value.
    ///
    /// The table carries no unique index by policy, so convergence happens in
    /// code, the same way `DailyLoopRepository.loop(for:)` merges duplicate
    /// days. The *earliest* row wins so the result does not depend on which
    /// device ran the merge, and the id breaks ties the clock cannot.
    private static func convergeDuplicates(
        _ db: Database,
        key: String,
        window: String,
        day: String,
        value: Double
    ) throws {
        let sameDay =
            try MetricSample
            .where { $0.key.eq(key) }
            .where { $0.window.eq(window) }
            .where { $0.day.eq(day) }
            .fetchAll(db)

        let equivalent = sameDay
            .filter { abs($0.value - value) < sampleEpsilon }
            .sorted { ($0.recordedAt, $0.id.uuidString) < ($1.recordedAt, $1.id.uuidString) }

        for duplicate in equivalent.dropFirst() {
            try MetricSample.find(duplicate.id).delete().execute(db)
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

// MARK: - Calibration drafts

/// Reads and writes the single in-progress calibration.
public struct CalibrationDraftRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// The draft, or `nil` when no calibration is in progress.
    public func current() throws -> CalibrationDraft? {
        try writer.read { db in
            try CalibrationDraft.find(CalibrationDraft.singletonID).fetchOne(db)
        }
    }

    /// Replaces the draft wholesale.
    ///
    /// A whole-row write rather than a merge because the payload is one
    /// self-consistent snapshot: a games list and a puzzles list that disagreed
    /// about how far the measurement had got would produce a resumed
    /// calibration that asks the wrong questions.
    public func save(payload: String, at date: Date = Date()) throws {
        try writer.write { db in
            try CalibrationDraft.upsert {
                CalibrationDraft(payload: payload, updatedAt: date)
            }
            .execute(db)
        }
    }

    /// Drops the draft once the measurement is finished.
    public func clear() throws {
        try writer.write { db in
            try CalibrationDraft.delete().where { $0.id.eq(CalibrationDraft.singletonID) }.execute(db)
        }
    }
}

// MARK: - Concept progress

/// What the user has been taught, and how the exercises have gone.
public struct ConceptRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func all() throws -> [ConceptProgress] {
        try writer.read { db in try ConceptProgress.all.fetchAll(db) }
    }

    public func progress(id: String) throws -> ConceptProgress? {
        try writer.read { db in try ConceptProgress.where { $0.id.eq(id) }.fetchOne(db) }
    }

    /// Marks a concept as taught, if it has not been already.
    ///
    /// Idempotent on purpose: the lesson is shown once, and a user who backs
    /// out of a set and re-enters it should not be taught the same thing twice
    /// — nor should they skip the exercise because the first showing counted.
    public func markIntroduced(id: String, at date: Date = Date()) throws {
        try writer.write { db in
            let existing = try ConceptProgress.where { $0.id.eq(id) }.fetchOne(db)
            guard var row = existing else {
                try ConceptProgress.insert { ConceptProgress(id: id, introducedAt: date) }.execute(db)
                return
            }
            guard row.introducedAt == nil else { return }
            row.introducedAt = date
            try ConceptProgress.upsert { row }.execute(db)
        }
    }

    /// Records that a concept was served, without claiming an outcome.
    ///
    /// For concepts whose exercise is an endgame drill: the drill runs on its
    /// own screen after the set closes, so the session that scheduled it never
    /// learns whether it was passed, and `recordAttempt` would have to invent a
    /// correctness it does not have.
    ///
    /// It still has to be recorded. `ConceptScheduler` rotates by `timesSeen`
    /// and then `lastSeenAt`, so a concept that is introduced but never seen
    /// again sits permanently at zero and wins every tie-break — which pinned
    /// the concept slot of every future session onto the same drill. Whether
    /// the drill was passed is tracked separately, as a per-family clean streak,
    /// and that is what the curriculum actually gates on.
    public func markSeen(id: String, at date: Date = Date()) throws {
        try writer.write { db in
            var row = try ConceptProgress.where { $0.id.eq(id) }.fetchOne(db)
                ?? ConceptProgress(id: id)
            row.timesSeen += 1
            row.lastSeenAt = date
            try ConceptProgress.upsert { row }.execute(db)
        }
    }

    /// Records an attempt at a concept's exercise.
    public func recordAttempt(id: String, correct: Bool, at date: Date = Date()) throws {
        try writer.write { db in
            var row = try ConceptProgress.where { $0.id.eq(id) }.fetchOne(db)
                ?? ConceptProgress(id: id)
            row.timesSeen += 1
            if correct { row.timesCorrect += 1 }
            row.lastSeenAt = date
            try ConceptProgress.upsert { row }.execute(db)
        }
    }
}

// MARK: - Erasing everything

extension UserDatabase {

    /// What a wipe would take, in the units a confirmation has to state.
    ///
    /// Counts rather than a sentence, because the screen that asks has to price
    /// the loss for *this* user: "everything" is not a quantity, and a user who
    /// cannot see that it is 37 games has no way to tell a rash tap from a
    /// deliberate one.
    public struct UserDataSummary: Sendable, Hashable {
        public var games: Int
        public var moments: Int
        public var cards: Int
        /// Recorded skill metrics, which is where calibration's result lives.
        ///
        /// Counted because a user can have a measured rating and no games at
        /// all — calibration writes its outcome before the first sparring game
        /// is ever played — and a wipe row disabled on "no games" in front of a
        /// freshly calibrated player would be refusing to delete data that
        /// plainly exists.
        public var metrics: Int
        /// The playing rating that would go back to its default.
        public var rating: Int

        public init(games: Int, moments: Int, cards: Int, metrics: Int, rating: Int) {
            self.games = games
            self.moments = moments
            self.cards = cards
            self.metrics = metrics
            self.rating = rating
        }

        /// True when there is nothing to lose, so the caller can say so rather
        /// than offer a destructive action against an empty database.
        public var isEmpty: Bool {
            games == 0 && moments == 0 && cards == 0 && metrics == 0
        }
    }

    public func userDataSummary() throws -> UserDataSummary {
        let rating = try settings.current().userRating
        return try writer.read { db in
            UserDataSummary(
                games: try Game.all.fetchCount(db),
                moments: try Moment.all.fetchCount(db),
                cards: try SRSCard.all.fetchCount(db),
                metrics: try SkillMetric.all.fetchCount(db),
                rating: Int(rating.rounded())
            )
        }
    }

    /// Empties every table this device owns and returns settings to defaults.
    ///
    /// One transaction, and **not** a file deletion. SQLiteData binds live
    /// `@FetchAll`/`@FetchOne` observers to the open connection: removing the
    /// file out from under them leaves every bound view showing the stale rows
    /// it last read, with no way to re-bind short of relaunching. Deleting rows
    /// through the same writer is what the observers are watching for, so the
    /// screens go empty the moment this returns.
    ///
    /// The settings row is reset in place rather than dropped, and the
    /// presentation preferences — board theme, piece set, sound, haptics —
    /// survive it. Those are not progress: a user clearing their games has not
    /// asked to have the sound turned back on, and silently undoing a choice
    /// they made weeks ago is the app taking more than it said it would.
    /// Everything that *is* a measurement — both ratings, the deviation, the
    /// rung — goes back to its default.
    ///
    /// The device calibration survives for the same kind of reason: it is a
    /// measurement of the *phone*, not of the user, it is explicitly not synced,
    /// and re-running the engine bench after a wipe would cost the user thirty
    /// seconds to learn what the app already knew.
    public func deleteAllUserData() throws {
        let kept = try settings.current()
        try writer.write { db in
            // Games first: moves, moments and ply evals ride out on
            // `ON DELETE CASCADE`, and deleting them separately afterwards
            // would be a second pass over rows that are already gone.
            try Game.delete().execute(db)
            try Moment.delete().execute(db)
            try PlyEval.delete().execute(db)
            try ReviewLog.delete().execute(db)
            try SRSCard.delete().execute(db)
            try MetricSample.delete().execute(db)
            try SkillMetric.delete().execute(db)
            try ConceptProgress.delete().execute(db)
            try DailyLoop.delete().execute(db)
            try CalibrationDraft.delete().execute(db)
            try AppSettings.delete().execute(db)
            try AppSettings.insert {
                AppSettings(
                    claudeModel: kept.claudeModel,
                    effort: kept.effort,
                    boardTheme: kept.boardTheme,
                    pieceSet: kept.pieceSet,
                    soundOn: kept.soundOn,
                    hapticsOn: kept.hapticsOn
                )
            }
            .execute(db)
        }
    }
}
