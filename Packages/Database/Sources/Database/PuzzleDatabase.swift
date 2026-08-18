import Foundation
import SQLiteData

/// A connection to the bundled, immutable `puzzles.sqlite`.
///
/// The file is produced offline by the `PuzzlePrep` tool and shipped inside the
/// app bundle, so this side is strictly a reader: there are no migrations and no
/// writes. Opening it read-only lets SQLite skip journal setup entirely, which
/// matters because the app bundle is not a writable location.
public struct PuzzleDatabase: Sendable {
    /// The underlying GRDB reader. Exposed so callers can compose their own
    /// queries, but ``puzzles`` covers everything the app needs today.
    public let reader: any DatabaseReader

    /// Queries over the puzzle corpus.
    public var puzzles: PuzzleRepository { PuzzleRepository(reader: reader) }

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    /// Opens the puzzle database read-only.
    ///
    /// - Parameters:
    ///   - url: Location of `puzzles.sqlite`.
    ///   - excludeFromBackup: Marks the file as excluded from iCloud/iTunes
    ///     backup. The database is large and fully reproducible from the app
    ///     bundle, so backing it up would waste the user's iCloud quota.
    public static func open(
        at url: URL,
        excludeFromBackup: Bool = true
    ) throws -> PuzzleDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PuzzleDatabaseError.notFound(url)
        }

        if excludeFromBackup {
            try? Self.excludeFromBackup(url)
        }

        var configuration = Configuration()
        // Read-only also guarantees we can never corrupt the shipped corpus, and
        // avoids SQLite trying to create -wal/-shm siblings next to a file that
        // may live in a non-writable bundle directory.
        configuration.readonly = true

        // A queue rather than a pool: pools need a writable directory for WAL
        // bookkeeping, and puzzle lookups are short, indexed reads where the
        // serialisation cost is irrelevant.
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return PuzzleDatabase(reader: queue)
    }

    /// Sets `isExcludedFromBackup` on the database file.
    ///
    /// Throws if the file lives somewhere whose resource values cannot be
    /// changed (an app bundle, for instance); callers generally treat that as
    /// benign since such locations are not backed up to begin with.
    public static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

public enum PuzzleDatabaseError: Error, CustomStringConvertible {
    case notFound(URL)

    public var description: String {
        switch self {
        case .notFound(let url):
            return "No puzzle database at \(url.path). Was PuzzlePrep run and the output bundled?"
        }
    }
}
