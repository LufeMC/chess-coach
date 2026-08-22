import Database
import Foundation
import OSLog

/// Writes finished games to disk, away from the main actor.
///
/// The repositories underneath are synchronous `Sendable` structs — GRDB already
/// serialises every access — so this actor exists for exactly one reason: to give
/// `GameSession` (which is `@MainActor`) somewhere to `await` that is *not* the
/// main actor. Inserting a 90-move game is a handful of milliseconds of SQLite
/// work, which is a handful of dropped frames if it happens on the UI thread.
actor GamePersistence {

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    /// The shared writer, or `nil` when the database could not be opened.
    ///
    /// Non-throwing on purpose: a game that cannot be saved is a problem, but it
    /// is not a reason to refuse to play, so callers treat `nil` as "record the
    /// failure and carry on".
    static let shared: GamePersistence? = AppDatabase.sharedIfAvailable.map(GamePersistence.init(database:))

    /// Persists a finished game and marks today's loop as having a game in it.
    ///
    /// The game row and its moves go in together — `GameRepository.insert`
    /// wraps both in one transaction — because a half-committed game shows up in
    /// history as an empty board.
    func save(_ record: FinishedGameRecord) throws {
        try database.games.insert(record.gameRow, moves: record.moveRows)

        // Separate write, deliberately: the daily loop is a streak counter, and
        // failing to bump it must never roll back the game itself.
        //
        // Calibration is excluded because it is not the loop's game. It is the
        // measurement the app runs *before* the loop starts, five games deep,
        // against opponents chosen to bracket a rating rather than to train
        // anything. Counting the last of them ticks the day's game square
        // before the user has played a day, and the first real "Play Oscar"
        // never happens.
        if record.mode != GameMode.calibration.rawValue {
            do {
                try database.dailyLoop.update(day: DailyLoop.dayKey(for: record.endedAt)) { loop in
                    loop.gamePlayed = true
                }
            } catch {
                AppLog.persistence.error("Daily loop not updated: \(String(describing: error), privacy: .public)")
            }
        }

        AppLog.persistence.info(
            "Saved game \(record.id.uuidString, privacy: .public) (\(record.moves.count) plies, \(record.termination, privacy: .public))"
        )
    }
}
