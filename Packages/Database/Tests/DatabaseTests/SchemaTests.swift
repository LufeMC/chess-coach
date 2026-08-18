import Foundation
import SQLiteData
import Testing

@testable import Database

@Suite("User database schema")
struct SchemaTests {

    // MARK: - Migrations

    @Test("Migration creates every declared table")
    func migrationCreatesTables() throws {
        let database = try UserDatabase.inMemory()
        let expected = Set(UserDatabase.syncedTableNames + UserDatabase.localOnlyTableNames)
        let actual = try database.writer.read { db in
            try #sql(
                #"SELECT "name" FROM "sqlite_master" WHERE "type" = 'table'"#,
                as: String.self
            )
            .fetchAll(db)
        }
        #expect(expected.isSubset(of: Set(actual)))
    }

    @Test("Migration is idempotent")
    func migrationIsIdempotent() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)

        try UserDatabase.migrator.migrate(queue)
        let firstSchema = try Self.schemaFingerprint(queue)
        let firstApplied = try queue.read { db in
            try UserDatabase.migrator.appliedIdentifiers(db)
        }

        // Running the same migrator again must be a no-op, not a re-create.
        try UserDatabase.migrator.migrate(queue)
        try UserDatabase.migrator.migrate(queue)

        let secondSchema = try Self.schemaFingerprint(queue)
        let secondApplied = try queue.read { db in
            try UserDatabase.migrator.appliedIdentifiers(db)
        }

        #expect(firstSchema == secondSchema)
        #expect(firstApplied == secondApplied)
        #expect(secondApplied.contains("v1.createUserSchema"))
    }

    @Test("Migration reports itself complete")
    func migrationCompletes() throws {
        let database = try UserDatabase.inMemory()
        let hasCompleted = try database.writer.read { db in
            try UserDatabase.migrator.hasCompletedMigrations(db)
        }
        #expect(hasCompleted)
    }

    @Test("Primary keys default to a generated UUID")
    func primaryKeyDefaultGeneratesUUID() throws {
        // The schema leans on SQLite's uuid() for its primary-key default, which
        // is what lets a row be inserted without the caller minting an ID.
        let database = try UserDatabase.inMemory()
        let generated = try database.writer.write { db in
            try #sql(
                #"INSERT INTO "games" ("mode") VALUES ('sparring') RETURNING "id""#,
                as: String.self
            )
            .fetchOne(db)
        }
        let id = try #require(generated)
        #expect(UUID(uuidString: id) != nil)
    }

    @Test("NOT NULL columns accept an explicit NULL and fall back to their default")
    func nullFallsBackToDefault() throws {
        // This is the ON CONFLICT REPLACE behaviour the sync engine depends on:
        // a record from an older build arrives with NULL for columns it never
        // knew about, and must land on the default rather than error.
        let database = try UserDatabase.inMemory()
        let settings = try database.writer.write { db in
            try #sql(
                """
                INSERT INTO "appSettings" ("id", "claudeModel", "currentRung")
                VALUES (\(bind: UUID().uuidString), NULL, NULL)
                RETURNING "claudeModel", "currentRung"
                """,
                as: (String, Int).self
            )
            .fetchOne(db)
        }
        let (model, rung) = try #require(settings)
        #expect(model == "claude-opus-5")
        #expect(rung == 1)
    }

    // MARK: - Sync safety lint

    @Test("Schema passes the CloudKit sync-safety audit")
    func schemaIsSyncSafe() throws {
        let database = try UserDatabase.inMemory()
        let findings = try database.writer.read { db in
            try SyncSafetyAudit.audit(db)
        }
        #expect(
            findings.isEmpty,
            "Sync-safety violations:\n\(findings.map(\.description).joined(separator: "\n"))"
        )
    }

    @Test("No synced table carries a unique index outside its primary key")
    func noUniqueIndexes() throws {
        let database = try UserDatabase.inMemory()
        let unique = try database.writer.read { db in
            try UserDatabase.syncedTableNames.flatMap { table in
                try #sql(
                    """
                    SELECT "name" FROM pragma_index_list(\(bind: table))
                    WHERE "unique" = 1 AND "origin" <> 'pk'
                    """,
                    as: String.self
                )
                .fetchAll(db)
            }
        }
        #expect(unique.isEmpty, "Unexpected unique indexes: \(unique)")
    }

    @Test("Every foreign key cascades, including on local-only tables")
    func allForeignKeysCascade() throws {
        let database = try UserDatabase.inMemory()
        let allTables = UserDatabase.syncedTableNames + UserDatabase.localOnlyTableNames
        let findings = try database.writer.read { db in
            try SyncSafetyAudit.auditCascades(db, tables: allTables)
        }
        #expect(
            findings.isEmpty,
            "Non-cascading foreign keys:\n\(findings.map(\.description).joined(separator: "\n"))"
        )
    }

    @Test("The audit actually catches a violation")
    func auditDetectsViolations() throws {
        // A lint that cannot fail is worthless — prove it fires.
        let database = try UserDatabase.inMemory()
        try database.writer.write { db in
            try #sql(#"CREATE UNIQUE INDEX "bad_unique" ON "dailyLoops"("day")"#).execute(db)
            try #sql(
                """
                CREATE TABLE "badChild" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "gameID" TEXT NOT NULL REFERENCES "games"("id") ON DELETE RESTRICT,
                  "required" TEXT NOT NULL
                ) STRICT
                """
            )
            .execute(db)
        }

        let findings = try database.writer.read { db in
            try SyncSafetyAudit.audit(db, syncedTables: UserDatabase.syncedTableNames + ["badChild"])
        }

        #expect(findings.contains { $0.table == "dailyLoops" })
        #expect(
            findings.contains {
                if case .foreignKeyWithoutCascade = $0.kind, $0.table == "badChild" { return true }
                return false
            }
        )
        #expect(
            findings.contains {
                if case .notNullColumnWithoutDefault(let column) = $0.kind, column == "required" {
                    return true
                }
                return false
            }
        )
    }

    @Test("Missing tables are reported rather than silently passing")
    func auditReportsMissingTables() throws {
        let database = try UserDatabase.inMemory()
        let findings = try database.writer.read { db in
            try SyncSafetyAudit.audit(db, syncedTables: ["nonexistent"])
        }
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .missingTable)
    }

    @Test("SQLiteData's own SyncEngine accepts the schema")
    func syncEngineAcceptsSchema() throws {
        // The definitive check. `SyncEngine.init` runs SQLiteData's
        // `validateSchema()`, which independently rejects unique constraints,
        // non-cascading foreign key actions, foreign keys into unsynced tables,
        // and reference cycles. Outside a live app it builds against mock
        // CloudKit containers and does not start syncing, so this exercises
        // validation without touching the network.
        //
        // If this ever fails, the schema would fail on a real device the first
        // time sync is switched on — which is exactly the failure this milestone
        // is meant to make impossible.
        let database = try UserDatabase.open()
        let engine = try database.sync(enabled: true)
        #expect(engine != nil)
    }

    @Test("Sync is off unless explicitly enabled")
    func syncIsOffByDefault() throws {
        let database = try UserDatabase.open()
        #expect(try database.sync() == nil)
        #expect(try database.sync(enabled: false) == nil)
    }

    @Test("Local-only tables are excluded from the synced set")
    func localTablesAreNotSynced() throws {
        let synced = Set(UserDatabase.syncedTableNames)
        for table in UserDatabase.localOnlyTableNames {
            #expect(!synced.contains(table))
        }
        #expect(synced.contains(Game.tableName))
        #expect(!synced.contains(PlyEval.tableName))
        #expect(!synced.contains(DeviceCalibration.tableName))
    }

    // MARK: - Cascades

    @Test("Deleting a game deletes its moves, moments and evals")
    func deletingGameCascades() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .sparring, userColor: .white, opponentRating: 1200)
        let other = Game(mode: .guided, userColor: .black, opponentRating: 1400)

        try database.games.insert(
            game,
            moves: [
                GameMove(gameID: game.id, ply: 1, san: "e4", uci: "e2e4"),
                GameMove(gameID: game.id, ply: 2, san: "e5", uci: "e7e5"),
            ]
        )
        try database.games.insert(
            other,
            moves: [GameMove(gameID: other.id, ply: 1, san: "d4", uci: "d2d4")]
        )
        try database.moments.insert([
            Moment(
                gameID: game.id,
                ply: 2,
                fen: "startpos",
                kind: "blunder",
                causeTag: "missedFork",
                stepTag: "calculate",
                playedSAN: "Nf6",
                playedUCI: "g8f6",
                bestSAN: "Nc6",
                bestUCI: "b8c6",
                deltaEP: -0.4,
                score: 0.9
            )
        ])
        try database.games.replaceEvals(
            [PlyEval(gameID: game.id, ply: 1, pv1Cp: 20, pv1: "e2e4", nodes: 1000, depth: 18)],
            forGame: game.id
        )

        #expect(try database.games.moves(forGame: game.id).count == 2)
        #expect(try database.moments.moments(forGame: game.id).count == 1)
        #expect(try database.games.evals(forGame: game.id).count == 1)

        try database.games.delete(id: game.id)

        #expect(try database.games.game(id: game.id) == nil)
        #expect(try database.games.moves(forGame: game.id).isEmpty)
        #expect(try database.moments.moments(forGame: game.id).isEmpty)
        #expect(try database.games.evals(forGame: game.id).isEmpty)

        // The unrelated game is untouched.
        #expect(try database.games.game(id: other.id) != nil)
        #expect(try database.games.moves(forGame: other.id).count == 1)
    }

    @Test("Deleting a card deletes its review logs")
    func deletingCardCascades() throws {
        let database = try UserDatabase.inMemory()
        let card = SRSCard(kind: SRSCardKind.puzzle.rawValue, puzzleID: "00sHx")
        try database.srs.save(card)
        try database.srs.recordReview(
            card: card,
            rating: .good,
            stateBefore: .new,
            elapsedDays: 0,
            scheduledDays: 1,
            durationMs: 4200
        )
        #expect(try database.srs.reviews(forCard: card.id).count == 1)

        try database.srs.delete(id: card.id)
        #expect(try database.srs.card(id: card.id) == nil)
        #expect(try database.srs.reviews(forCard: card.id).isEmpty)
    }

    @Test("Foreign keys are enforced")
    func foreignKeysAreEnforced() throws {
        let database = try UserDatabase.inMemory()
        // Inserting a move for a game that does not exist must fail; without
        // this, cascades would never fire either.
        #expect(throws: (any Error).self) {
            try database.writer.write { db in
                try GameMove.insert {
                    GameMove(gameID: UUID(), ply: 1, san: "e4", uci: "e2e4")
                }
                .execute(db)
            }
        }
    }

    // MARK: - Helpers

    /// Canonical form of the schema, used to prove a re-run changed nothing.
    private static func schemaFingerprint(_ writer: any DatabaseWriter) throws -> [String] {
        try writer.read { db in
            try #sql(
                """
                SELECT coalesce("type", '') || '|' || coalesce("name", '') || '|'
                  || coalesce("sql", '')
                FROM "sqlite_master"
                ORDER BY "type", "name"
                """,
                as: String.self
            )
            .fetchAll(db)
        }
    }
}
