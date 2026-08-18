import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` is a macro (`(sqlite3_destructor_type)-1`) and so is not
/// imported into Swift. Telling SQLite to copy the bound text is the safe
/// choice here: the alternative (STATIC) would require every bound String to
/// outlive `sqlite3_step`, which Swift's String bridging does not guarantee.
nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

/// Writes the curated puzzle database.
///
/// The schema is fixed by contract with `Packages/Database`, which reads this
/// file — column names, order, and types must not drift.
final class SQLiteWriter {
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var pendingInBatch = 0

    /// Rows per transaction. One transaction for all 120k rows would hold a
    /// large rollback journal; one per row would fsync 120k times. 50k is the
    /// usual sweet spot.
    private let batchSize = 50_000

    init(path: String) throws {
        // Always build from scratch: an existing file could carry an older
        // schema or stale rows that would survive an INSERT-only run.
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = path + suffix
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        guard sqlite3_open(path, &db) == SQLITE_OK, db != nil else {
            throw PrepError.sqlite("could not open \(path)")
        }
        // This is a rebuildable build artifact, not user data: durability
        // pragmas buy nothing and cost minutes. If the machine dies mid-build
        // the answer is to run the tool again.
        try exec("PRAGMA journal_mode = MEMORY;")
        try exec("PRAGMA synchronous = OFF;")
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA cache_size = -200000;") // ~200 MB page cache
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw PrepError.sqlite("\(msg) — while running: \(sql)")
        }
    }

    func createSchema() throws {
        try exec("""
        CREATE TABLE puzzle (
          id TEXT PRIMARY KEY, fen TEXT NOT NULL, moves TEXT NOT NULL,
          rating INTEGER NOT NULL, rating_dev INTEGER NOT NULL,
          popularity INTEGER NOT NULL, nb_plays INTEGER NOT NULL,
          themes_lo INTEGER NOT NULL, themes_hi INTEGER NOT NULL, game_url TEXT
        );
        """)
        try exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")

        let sql = """
        INSERT INTO puzzle
          (id, fen, moves, rating, rating_dev, popularity, nb_plays, themes_lo, themes_hi, game_url)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK else {
            throw PrepError.sqlite(lastMessage())
        }
        try exec("BEGIN TRANSACTION;")
    }

    /// The index is created only after the bulk load. Building it up front
    /// would mean re-balancing a B-tree on every insert.
    func createIndexes() throws {
        try exec("CREATE INDEX puzzle_rating ON puzzle(rating);")
    }

    func insert(
        id: String, fen: String, moves: String,
        rating: Int, ratingDev: Int, popularity: Int, nbPlays: Int,
        mask: ThemeMask, gameURL: String
    ) throws {
        guard let stmt = insertStmt else { throw PrepError.sqlite("insert statement not prepared") }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, fen, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, moves, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(rating))
        sqlite3_bind_int64(stmt, 5, Int64(ratingDev))
        sqlite3_bind_int64(stmt, 6, Int64(popularity))
        sqlite3_bind_int64(stmt, 7, Int64(nbPlays))
        sqlite3_bind_int64(stmt, 8, mask.loColumnValue)
        sqlite3_bind_int64(stmt, 9, mask.hiColumnValue)
        if gameURL.isEmpty {
            sqlite3_bind_null(stmt, 10)
        } else {
            sqlite3_bind_text(stmt, 10, gameURL, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PrepError.sqlite(lastMessage())
        }
        pendingInBatch += 1
        if pendingInBatch >= batchSize {
            try exec("COMMIT;")
            try exec("BEGIN TRANSACTION;")
            pendingInBatch = 0
        }
    }

    func writeMeta(_ pairs: [(String, String)]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?,?);", -1, &stmt, nil) == SQLITE_OK else {
            throw PrepError.sqlite(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }
        for (k, v) in pairs {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, k, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, v, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw PrepError.sqlite(lastMessage())
            }
        }
    }

    /// Commits, indexes, VACUUMs and closes. VACUUM must run outside a
    /// transaction, which is why the final COMMIT happens here first.
    func finish() throws {
        try exec("COMMIT;")
        pendingInBatch = 0
        if let insertStmt { sqlite3_finalize(insertStmt) }
        insertStmt = nil
        try createIndexes()
        try exec("VACUUM;")
        // Deliberately NOT running `PRAGMA optimize` / ANALYZE: it would add a
        // `sqlite_stat1` table, and the schema is a contract with the reading
        // package. Keep the file to exactly the agreed tables.
        sqlite3_close(db)
        db = nil
    }

    private func lastMessage() -> String {
        guard let db, let cstr = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: cstr)
    }

    deinit {
        if let insertStmt { sqlite3_finalize(insertStmt) }
        if let db { sqlite3_close(db) }
    }
}
