import Database
import Foundation
import OSLog
import SQLiteData

/// The app's two SQLite connections, opened once and shared.
///
/// There are exactly two databases and they have opposite characters:
///
/// * `user.sqlite` lives in Application Support, is migrated on open, is written
///   to constantly, and is the thing worth protecting.
/// * `puzzles.sqlite` ships inside the app bundle and is opened **read-only in
///   place**. Copying 21MB out of the bundle on first launch would double the
///   disk footprint to gain nothing: the bundle copy is already the canonical
///   one and is never written to.
struct AppDatabase: Sendable {

    let user: UserDatabase
    /// `nil` when the bundle was built without the puzzle corpus. The resource is
    /// declared `optional` in `project.yml`, so a build genuinely can ship
    /// without it, and losing puzzles must not take games and analysis with it.
    let puzzles: PuzzleDatabase?

    // MARK: - Repositories
    //
    // Re-vended rather than requiring callers to reach through `user`, so that a
    // future split of the user database (or a repository that spans both) is a
    // change here instead of at every call site.

    var games: GameRepository { user.games }
    var moments: MomentRepository { user.moments }
    var srs: SRSRepository { user.srs }
    var metrics: MetricsRepository { user.metrics }
    var settings: SettingsRepository { user.settings }
    var dailyLoop: DailyLoopRepository { user.dailyLoop }
    var puzzleQueries: PuzzleRepository? { puzzles?.puzzles }

    // MARK: - Shared instance

    /// The process-wide database, opened lazily on first use.
    ///
    /// Stored as a `Result` rather than a force-unwrapped optional because
    /// "Application Support is not writable" is a real, reportable condition and
    /// the UI should say so rather than crash. Swift's lazy `static let`
    /// guarantees the body runs exactly once, which is what makes it safe to do
    /// the one-shot `prepareDependencies` call inside ``bootstrap()``.
    static let shared: Result<AppDatabase, AppDatabaseError> = {
        do {
            return .success(try AppDatabase.bootstrap())
        } catch let error as AppDatabaseError {
            AppLog.persistence.error("Database bootstrap failed: \(error.description, privacy: .public)")
            return .failure(error)
        } catch {
            let wrapped = AppDatabaseError(description: String(describing: error))
            AppLog.persistence.error("Database bootstrap failed: \(wrapped.description, privacy: .public)")
            return .failure(wrapped)
        }
    }()

    /// The shared database, or `nil` if it could not be opened.
    ///
    /// Callers that can degrade (a game that cannot be saved is still playable)
    /// use this; callers that cannot use ``shared`` and surface the error.
    static var sharedIfAvailable: AppDatabase? { try? shared.get() }

    /// Forces the shared database open. Cheap to call more than once.
    ///
    /// Worth calling at launch: `@FetchAll`/`@FetchOne` resolve their database
    /// through the dependency that ``bootstrap()`` installs, and a view that
    /// fetches before the first `shared` access would silently bind to
    /// SQLiteData's blank fallback database instead.
    @discardableResult
    static func bootstrapIfNeeded() -> Result<AppDatabase, AppDatabaseError> { shared }

    // MARK: - Opening

    static func bootstrap(
        userDatabaseURL: URL? = nil,
        puzzleDatabaseURL: URL? = Bundle.main.url(forResource: "puzzles", withExtension: "sqlite")
    ) throws -> AppDatabase {
        let userURL = try userDatabaseURL ?? defaultUserDatabaseURL()

        let user: UserDatabase
        do {
            // `excludeFromBackup: false` is deliberate and matches the Database
            // package's documented default: games, moments and review history are
            // precisely the data worth restoring onto a new device, and until
            // CloudKit sync is switched on (see `enableCloudKitSync` below) the
            // device backup is the *only* copy. The bulky, regenerable tables
            // (`plyEvals`) are already excluded from sync rather than from
            // backup, so the backed-up file stays small.
            user = try UserDatabase.open(at: userURL, excludeFromBackup: false)
        } catch {
            throw AppDatabaseError(description: "Could not open \(userURL.path): \(error)")
        }

        var puzzles: PuzzleDatabase?
        if let puzzleDatabaseURL {
            do {
                // `excludeFromBackup: false` because the file lives in the app
                // bundle, which is not backed up in the first place; asking for a
                // resource-value change there just fails silently.
                puzzles = try PuzzleDatabase.open(at: puzzleDatabaseURL, excludeFromBackup: false)
            } catch {
                AppLog.persistence.error("Puzzle database unavailable: \(String(describing: error), privacy: .public)")
            }
        } else {
            AppLog.persistence.error("No puzzles.sqlite in the bundle; puzzle features are disabled.")
        }

        // This is what makes `@FetchAll` / `@FetchOne` work in SwiftUI views:
        // they resolve their reader from this dependency, and SQLiteData warns
        // (loudly) if it is prepared twice. The lazy `static let shared` above is
        // the single-execution guarantee that keeps that promise.
        prepareDependencies { $0.defaultDatabase = user.writer }

        // CloudKit stays off in this milestone. Switching it on is one line —
        // `enabled: true` below — plus retaining the returned engine for the
        // lifetime of the app; releasing it stops synchronisation. The schema is
        // already sync-shaped (see `UserDatabase.migrator`), so no migration is
        // involved.
        #if canImport(CloudKit)
            _ = try? user.sync(enabled: false)
        #endif

        AppLog.persistence.info("Opened user database at \(userURL.path, privacy: .public)")
        return AppDatabase(user: user, puzzles: puzzles)
    }

    /// `<Application Support>/user.sqlite`, creating the directory if needed.
    static func defaultUserDatabaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "user.sqlite", directoryHint: .notDirectory)
    }
}

/// A database that could not be opened, reduced to a describable value.
///
/// `Sendable` and concrete rather than `any Error` so it can live in the
/// `static let` above without tripping Swift 6's global-state rules.
struct AppDatabaseError: Error, Sendable, CustomStringConvertible, Equatable {
    let description: String
}

// MARK: - Logging

enum AppLog {
    static let persistence = Logger(subsystem: "com.usenivel.chesscoach", category: "persistence")
    static let analysis = Logger(subsystem: "com.usenivel.chesscoach", category: "analysis")
}
