import Foundation
import SQLiteData

#if canImport(CloudKit)
    import CloudKit
#endif

/// The read/write database holding everything the user creates: games, moments,
/// review history, settings.
///
/// Unlike ``PuzzleDatabase`` this one is migrated, written to, and (from a later
/// milestone) synchronised to CloudKit. See ``syncedTableNames`` for which parts
/// travel.
public struct UserDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Repositories

    public var games: GameRepository { GameRepository(writer: writer) }
    public var moments: MomentRepository { MomentRepository(writer: writer) }
    public var srs: SRSRepository { SRSRepository(writer: writer) }
    public var metrics: MetricsRepository { MetricsRepository(writer: writer) }
    public var settings: SettingsRepository { SettingsRepository(writer: writer) }
    public var dailyLoop: DailyLoopRepository { DailyLoopRepository(writer: writer) }
    public var calibrationDrafts: CalibrationDraftRepository { CalibrationDraftRepository(writer: writer) }

    // MARK: - Opening

    /// Opens (creating if needed) the user database and runs all migrations.
    ///
    /// - Parameters:
    ///   - url: Where to store the database. `nil` uses SQLiteData's
    ///     context-aware default, which is a temporary file under test and in
    ///     previews, and the application support directory in a live app.
    ///   - excludeFromBackup: Whether to keep the file out of iCloud/iTunes
    ///     device backups. Defaults to `false`: user games and review history
    ///     are exactly the data worth restoring onto a new device, and until
    ///     CloudKit sync ships, backup is the *only* thing protecting it.
    public static func open(
        at url: URL? = nil,
        excludeFromBackup: Bool = false
    ) throws -> UserDatabase {
        var configuration = Configuration()
        // Cascades are the mechanism that keeps moves, moments and evals from
        // outliving their game, and the sync engine reads the same foreign keys
        // to decide record ordering. Both break silently if this is off.
        configuration.foreignKeysEnabled = true

        let writer = try defaultDatabase(path: url?.path, configuration: configuration)

        if excludeFromBackup, !writer.path.isEmpty {
            try? PuzzleDatabase.excludeFromBackup(URL(fileURLWithPath: writer.path))
        }

        try migrator.migrate(writer)
        return UserDatabase(writer: writer)
    }

    /// An ephemeral, fully migrated database. For tests and previews.
    public static func inMemory() throws -> UserDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(queue)
        return UserDatabase(writer: queue)
    }

    // MARK: - Table inventory

    /// Tables replicated to CloudKit.
    ///
    /// Order matters: parents come before children so that the sync engine can
    /// resolve foreign keys.
    public static let syncedTableNames: [String] = [
        Game.tableName,
        GameMove.tableName,
        Moment.tableName,
        SRSCard.tableName,
        ReviewLog.tableName,
        SkillMetric.tableName,
        MetricSample.tableName,
        DailyLoop.tableName,
        AppSettings.tableName,
    ]

    /// Tables deliberately kept on-device.
    ///
    /// `plyEvals` is a large, regenerable analysis cache; `deviceCalibrations`
    /// describes *this* hardware and would be actively wrong on another device.
    public static let localOnlyTableNames: [String] = [
        PlyEval.tableName,
        DeviceCalibration.tableName,
        CalibrationDraft.tableName,
    ]

    // MARK: - Migrations

    /// The full migration chain.
    ///
    /// # Rules for adding migrations
    ///
    /// Once a version ships, its rows exist on devices you do not control, and
    /// CloudKit will hand you records written by *older* builds forever. So:
    ///
    /// * **Never** rename or drop a column or table. CloudKit has no way to
    ///   express either, and older peers keep sending the old shape.
    /// * **Never** add a `UNIQUE` index outside the primary key. Two offline
    ///   devices creating "the same" row is normal, and a unique index turns
    ///   that into an unresolvable sync failure.
    /// * Every new `NOT NULL` column needs `ON CONFLICT REPLACE DEFAULT <x>`.
    ///   Older devices will insert rows without it, and the sync engine writes
    ///   an explicit `NULL` for columns it does not know; the `ON CONFLICT
    ///   REPLACE` clause is what turns that `NULL` into the default instead of
    ///   an error. It must sit directly after `NOT NULL`.
    /// * Foreign keys must use `ON DELETE CASCADE` (or `SET NULL` / `SET
    ///   DEFAULT`). `RESTRICT` and `NO ACTION` are rejected by the sync engine.
    ///
    /// `SyncSafetyAudit` enforces the mechanical parts of this in tests.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Deliberately NOT setting `eraseDatabaseOnSchemaChange`, even in debug:
        // it silently destroys the local database, which is indistinguishable
        // from data loss once sync is on.
        migrator.registerMigration("v1.createUserSchema", migrate: createUserSchema)
        migrator.registerMigration("v2.analysisDetail", migrate: addAnalysisDetail)
        migrator.registerMigration("v3.ladderAssistedRetry", migrate: addLadderAssistedRetry)
        migrator.registerMigration("v4.metricSampleHistory", migrate: addMetricSampleHistory)
        migrator.registerMigration("v5.calibrationDraft", migrate: addCalibrationDraft)
        return migrator
    }

    private static func createUserSchema(_ db: Database) throws {
        // Synced tables ------------------------------------------------------
        //
        // Every primary key is `TEXT ... DEFAULT (uuid())` rather than an
        // autoincrementing integer: two devices offline at once must be able to
        // mint IDs that cannot collide.

        try #sql(
            """
            CREATE TABLE "games" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "startedAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now')),
              "endedAt" TEXT,
              "mode" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'sparring',
              "userColor" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'white',
              "opponentParams" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '{}',
              "opponentRating" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1200,
              "result" TEXT,
              "termination" TEXT,
              "pgn" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "userAccuracy" REAL,
              "analysisState" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'pending',
              "isRated" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "gameMoves" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "gameID" TEXT NOT NULL REFERENCES "games"("id") ON DELETE CASCADE,
              "ply" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "san" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "uci" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "classification" TEXT,
              "winPctBefore" REAL,
              "winPctAfter" REAL,
              "thinkTimeMs" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "moments" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "gameID" TEXT NOT NULL REFERENCES "games"("id") ON DELETE CASCADE,
              "ply" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "fen" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "kind" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "causeTag" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "stepTag" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "modifiers" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
              "playedSAN" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "playedUCI" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "bestSAN" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "bestUCI" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "deltaEP" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "score" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "coachText" TEXT,
              "status" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'new',
              "createdAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now'))
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "srsCards" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "kind" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'puzzle',
              "puzzleID" TEXT,
              "positionKey" INTEGER,
              "fen" TEXT,
              "due" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now')),
              "stability" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "difficulty" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "state" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'new',
              "reps" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "lapses" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "lastReview" TEXT
            ) STRICT
            """
        )
        .execute(db)

        // No CHECK on "rating": a build with a wider grading scale must still be
        // able to sync its reviews down to this one. The range is enforced in
        // `SRSRepository` on the way in.
        try #sql(
            """
            CREATE TABLE "reviewLogs" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "cardID" TEXT NOT NULL REFERENCES "srsCards"("id") ON DELETE CASCADE,
              "reviewedAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now')),
              "rating" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 3,
              "stateBefore" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'new',
              "elapsedDays" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "scheduledDays" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "durationMs" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        // (key, window) is logically unique but is deliberately NOT a unique
        // index — see the migration rules above. `MetricsRepository.upsert`
        // merges duplicates instead.
        try #sql(
            """
            CREATE TABLE "skillMetrics" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "key" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "window" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "value" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "sampleCount" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "updatedAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now'))
            ) STRICT
            """
        )
        .execute(db)

        // Likewise "day": two devices can both open the app on the same morning.
        try #sql(
            """
            CREATE TABLE "dailyLoops" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "day" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "gamePlayed" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "momentsReviewed" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "puzzlesDone" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "completedAt" TEXT
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "appSettings" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "claudeModel" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'claude-opus-5',
              "effort" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'medium',
              "boardTheme" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'classic',
              "pieceSet" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'staunty',
              "soundOn" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
              "hapticsOn" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
              "userRating" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 1100,
              "puzzleRating" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 1000,
              "puzzleRD" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 350,
              "currentRung" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
              "weeklyFocusHabit" TEXT
            ) STRICT
            """
        )
        .execute(db)

        // Local-only tables --------------------------------------------------
        //
        // These follow the same UUID/cascade shape so that a future decision to
        // sync them would not need a rewrite, but they are absent from
        // `syncedTableNames` and so never registered with the sync engine.

        try #sql(
            """
            CREATE TABLE "plyEvals" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "gameID" TEXT NOT NULL REFERENCES "games"("id") ON DELETE CASCADE,
              "ply" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "pv1Cp" INTEGER,
              "pv1Mate" INTEGER,
              "pv1" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "pv2Cp" INTEGER,
              "pv2Mate" INTEGER,
              "pv2" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "nodes" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "depth" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            ) STRICT
            """
        )
        .execute(db)

        try #sql(
            """
            CREATE TABLE "deviceCalibrations" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "benchNps" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "nodeBudget" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "threads" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
              "hashMB" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 16,
              "calibratedAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now'))
            ) STRICT
            """
        )
        .execute(db)

        // Indexes ------------------------------------------------------------
        //
        // All non-unique, by policy. SQLite does not index foreign keys
        // automatically, and every cascade delete scans the child table without
        // these.
        try #sql(#"CREATE INDEX "idx_games_startedAt" ON "games"("startedAt")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_gameMoves_gameID" ON "gameMoves"("gameID", "ply")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "idx_moments_gameID" ON "moments"("gameID", "ply")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_moments_status" ON "moments"("status", "score")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_srsCards_due" ON "srsCards"("due")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_srsCards_puzzleID" ON "srsCards"("puzzleID")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_srsCards_positionKey" ON "srsCards"("positionKey")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "idx_reviewLogs_cardID" ON "reviewLogs"("cardID")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_skillMetrics_key" ON "skillMetrics"("key", "window")"#)
            .execute(db)
        try #sql(#"CREATE INDEX "idx_dailyLoops_day" ON "dailyLoops"("day")"#).execute(db)
        try #sql(#"CREATE INDEX "idx_plyEvals_gameID" ON "plyEvals"("gameID", "ply")"#).execute(db)
    }

    /// Stops the analysis pass from throwing away what it computed.
    ///
    /// `moments` gains the full analysis payload plus the spaced-repetition
    /// eligibility flag, and `gameMoves` gains per-move accuracy and the guided
    /// prompt that preceded a move. See the property documentation on ``Moment``
    /// and ``GameMove`` for why each one is a column rather than a derivation.
    ///
    /// # Why this is a second migration and not an edit to v1
    ///
    /// Nothing has shipped and sync has never run, so it is tempting to rewrite
    /// `createUserSchema` and pretend v2 never existed. That is wrong for a
    /// reason that has nothing to do with CloudKit: ``DatabaseMigrator`` records
    /// which identifiers it has applied and **skips those it has already run**.
    /// Every database already created on a simulator or a development device has
    /// `v1.createUserSchema` in `grdb_migrations`, so an edited v1 would never
    /// execute there — leaving a `moments` table with no `payload` column while
    /// the Swift record type selects one, i.e. `no such column` on every read of
    /// every existing local database. The only ways out of that would be erasing
    /// the file (data loss) or a migration, which is what this is.
    ///
    /// Additive `ALTER TABLE ADD COLUMN` is also the shape the sync rules above
    /// demand: no column is renamed or dropped, every new `NOT NULL` column
    /// carries `ON CONFLICT REPLACE DEFAULT`, and the nullable ones need no
    /// default because a peer that never heard of them sends `NULL`, which is
    /// exactly what "this build did not measure that" means.
    /// Records that a finished game contained a level-2 assisted retry — the
    /// coach did not merely nudge, it showed the move and let the user take it
    /// back.
    ///
    /// The flag exists on the in-memory record already, and the live rating
    /// write consumes it there. It has to be *stored* as well because
    /// `MetricComputer` recomputes the ladder performance rating from history,
    /// and a metric derived from stored rows that disagrees with the rating
    /// actually applied is worse than no metric: the drift guard exists
    /// specifically to notice when the rating and the results have come apart,
    /// so feeding it games the rating deliberately ignored would make it fire on
    /// its own blind spot.
    ///
    /// Defaults to 0, which is the truth for every game recorded before the
    /// column existed — second-try hints were not tracked at all then, so no
    /// historical game can be known to have used one.
    private static func addLadderAssistedRetry(_ db: Database) throws {
        try #sql(
            """
            ALTER TABLE "games"
            ADD COLUMN "usedAssistedRetry" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            """
        )
        .execute(db)
    }

    private static func addAnalysisDetail(_ db: Database) throws {
        try #sql(
            """
            ALTER TABLE "moments"
            ADD COLUMN "payload" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT ''
            """
        )
        .execute(db)

        try #sql(
            """
            ALTER TABLE "moments"
            ADD COLUMN "srsEligible" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
            """
        )
        .execute(db)

        try #sql(#"ALTER TABLE "gameMoves" ADD COLUMN "accuracy" REAL"#).execute(db)
        try #sql(#"ALTER TABLE "gameMoves" ADD COLUMN "guidedPromptHabit" TEXT"#).execute(db)
        try #sql(#"ALTER TABLE "gameMoves" ADD COLUMN "guidedPromptHit" INTEGER"#).execute(db)

        // No index on "srsEligible": `idx_moments_status` already narrows to the
        // handful of moments that have not been worked through, and a table
        // holding at most three rows per game would spend more on maintaining a
        // second index than it could ever save on scanning.
    }

    /// Gives the metrics layer a memory.
    ///
    /// `skillMetrics` holds one row per `(key, window)`, so each recompute
    /// overwrites the number it replaces: the schema could say what the rating
    /// *is* and never what it *was*. That is a gap in the product, not only in
    /// the data — the app exists to move one number over about a year, and a
    /// year-long goal whose trend line cannot be drawn has lost its primary
    /// feedback signal. ``MetricSample`` is the missing half.
    ///
    /// # Why a second table rather than columns on `skillMetrics`
    ///
    /// The two have opposite lifecycles. A skill metric is a *singleton*,
    /// updated in place and merged field by field across devices; a sample is
    /// *immutable* once written and merges by not colliding in the first place.
    /// A table that tried to be both would force every curriculum gate to
    /// filter history rows out of its lookup, and the first filter anyone
    /// forgot would gate advancement on a value from March.
    ///
    /// # Write volume
    ///
    /// An append-only table with an eager writer is a disk-space bug waiting to
    /// happen: `MetricsService.refresh()` runs on app foreground and on every
    /// Profile load, so "a row per recompute" would give a user who checks their
    /// rating fifty times an afternoon a fifty-point flat line and no signal.
    /// Hence `day`, the coalescing bucket:
    /// ``MetricsRepository/recordSample(key:window:value:measuredAt:now:calendar:)``
    /// keeps at most one row per `(key, window, day, value)`, so the ceiling is
    /// one row per day a value stood still plus one per time it moved. A few
    /// hundred rows a year per plotted metric is small enough to be worth
    /// synchronising, which matters: a rating history that did not survive onto
    /// a new device would be a year of evidence lost to an upgrade.
    ///
    /// # Sync shape
    ///
    /// `(key, window, day, value)` is logically unique and deliberately carries
    /// no unique index, for the reason the rules above give: two devices offline
    /// on the same day will both record that day's rating, and a unique index
    /// turns an ordinary merge into an unresolvable failure. Duplicates converge
    /// on the next write instead.
    /// Somewhere to keep a calibration that has not finished yet.
    ///
    /// Calibration gates the whole app: the rating and starting rung it produces
    /// are what every other screen reads, so it runs before anything else and it
    /// runs exactly once. Holding its five games and twenty puzzles only in
    /// memory meant a force-quit — or a phone call during game three — threw the
    /// lot away and started the diagnostic over, which is the single worst first
    /// impression the app can make.
    ///
    /// One row, one blob. The draft is a private shape that changes whenever the
    /// calibration flow changes, and a column per field would mean a migration
    /// every time; a blob that is written and read by one type cannot drift from
    /// itself. It is deleted the moment calibration completes, so this table is
    /// empty for all but the first few minutes of the app's life.
    private static func addCalibrationDraft(_ db: Database) throws {
        try #sql(
            """
            CREATE TABLE "calibrationDrafts" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "payload" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "updatedAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now'))
            ) STRICT
            """
        )
        .execute(db)
    }

    private static func addMetricSampleHistory(_ db: Database) throws {
        try #sql(
            """
            CREATE TABLE "metricSamples" (
              "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              "key" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "window" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "day" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
              "value" REAL NOT NULL ON CONFLICT REPLACE DEFAULT 0,
              "recordedAt" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT (datetime('now'))
            ) STRICT
            """
        )
        .execute(db)

        // Ordered by time rather than by `day`, because both queries the table
        // has are "one series, newest first": the chart's read, and the newest
        // sample the de-duplicating write compares against.
        try #sql(
            """
            CREATE INDEX "idx_metricSamples_key"
            ON "metricSamples"("key", "window", "recordedAt")
            """
        )
        .execute(db)
    }
}

// MARK: - CloudKit

#if canImport(CloudKit)
    extension UserDatabase {
        /// Turns CloudKit synchronisation on or off.
        ///
        /// Sync is **off** in this milestone: this returns `nil` unless
        /// explicitly enabled. The schema is already sync-shaped though (UUID
        /// keys, cascade-only foreign keys, no unique constraints, defaults on
        /// every non-null column), so switching it on later is a configuration
        /// change rather than a migration.
        ///
        /// Enabling additionally requires iCloud entitlements, a container
        /// identifier, and the "Remote notifications" background mode — without
        /// them the initialiser throws.
        ///
        /// - Parameters:
        ///   - enabled: Pass `true` to construct and start a sync engine.
        ///   - containerIdentifier: Overrides the container from the app's
        ///     entitlements.
        /// - Returns: The live sync engine, or `nil` when disabled. The caller
        ///   must retain it; releasing it stops synchronisation.
        @discardableResult
        public func sync(
            enabled: Bool = false,
            containerIdentifier: String? = nil
        ) throws -> SyncEngine? {
            guard enabled else { return nil }
            // Listed parent-first. `privateTables:` is left empty — nothing here
            // is shareable with other iCloud users; it is all one person's
            // training history.
            return try SyncEngine(
                for: writer,
                tables: Game.self,
                GameMove.self,
                Moment.self,
                SRSCard.self,
                ReviewLog.self,
                SkillMetric.self,
                MetricSample.self,
                DailyLoop.self,
                AppSettings.self,
                containerIdentifier: containerIdentifier
            )
        }
    }
#endif
