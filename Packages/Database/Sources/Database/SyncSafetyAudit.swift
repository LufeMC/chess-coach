import Foundation
import SQLiteData

/// A mechanical check that the live schema still obeys the rules CloudKit
/// replication depends on.
///
/// This exists because the rules in ``UserDatabase/migrator`` are easy to state
/// and easy to forget. A `UNIQUE` index added a year from now to fix a local bug
/// would work perfectly on one device and quietly make the schema unsyncable;
/// the failure would only appear once two devices raced. Running this audit in
/// tests turns that latent, remote, hard-to-reproduce failure into a red build.
///
/// It inspects the *database*, not the Swift types, so it catches drift
/// introduced by hand-written migration SQL — which is the only way schema
/// changes happen here.
public enum SyncSafetyAudit {
    public struct Finding: Sendable, Hashable, CustomStringConvertible {
        public var table: String
        public var kind: Kind

        public enum Kind: Sendable, Hashable {
            /// A `UNIQUE` index that is not the primary key. Two devices
            /// creating equivalent rows offline would collide with no correct
            /// resolution.
            case nonPrimaryKeyUniqueIndex(index: String)
            /// A foreign key whose `ON DELETE` action is not `CASCADE`.
            case foreignKeyWithoutCascade(column: String, references: String, onDelete: String)
            /// A synced table pointing at a table that is not itself synced: the
            /// child would arrive on another device with a dangling parent.
            case foreignKeyToUnsyncedTable(column: String, references: String)
            /// No primary key at all; the sync engine has nothing to build a
            /// `CKRecord.ID` from.
            case missingPrimaryKey
            /// A compound primary key, which cannot be encoded as a record name.
            case compoundPrimaryKey(columns: [String])
            /// A `NOT NULL` column with no default. A record synced from a build
            /// that predates the column arrives with `NULL` and is rejected.
            case notNullColumnWithoutDefault(column: String)
            /// A table named in the inventory but absent from the database.
            case missingTable
        }

        public var description: String {
            switch kind {
            case .nonPrimaryKeyUniqueIndex(let index):
                return """
                    \(table): index "\(index)" is UNIQUE but is not the primary key. \
                    Uniqueness constraints cannot be synchronized.
                    """
            case .foreignKeyWithoutCascade(let column, let references, let onDelete):
                return """
                    \(table)."\(column)" references "\(references)" with ON DELETE \(onDelete). \
                    Only CASCADE is permitted.
                    """
            case .foreignKeyToUnsyncedTable(let column, let references):
                return """
                    \(table)."\(column)" references "\(references)", which is not a synced table.
                    """
            case .missingPrimaryKey:
                return "\(table): no primary key. Every synced table needs one."
            case .compoundPrimaryKey(let columns):
                return """
                    \(table): compound primary key (\(columns.joined(separator: ", "))). \
                    Synced tables need a single-column primary key.
                    """
            case .notNullColumnWithoutDefault(let column):
                return """
                    \(table)."\(column)" is NOT NULL with no default. Add \
                    'ON CONFLICT REPLACE DEFAULT <value>' so records from older builds still insert.
                    """
            case .missingTable:
                return "\(table): declared as synced but not present in the schema."
            }
        }
    }

    /// Audits the tables that are (or will be) replicated to CloudKit.
    ///
    /// - Parameters:
    ///   - db: An open connection.
    ///   - syncedTables: The tables to check. Defaults to
    ///     ``UserDatabase/syncedTableNames``.
    /// - Returns: Every violation found. Empty means the schema is sync-safe.
    public static func audit(
        _ db: Database,
        syncedTables: [String] = UserDatabase.syncedTableNames
    ) throws -> [Finding] {
        let syncedSet = Set(syncedTables)
        var findings: [Finding] = []

        for table in syncedTables {
            guard try tableExists(db, table) else {
                findings.append(Finding(table: table, kind: .missingTable))
                continue
            }
            findings.append(contentsOf: try auditUniqueIndexes(db, table))
            findings.append(
                contentsOf: try auditForeignKeys(db, table, syncedTables: syncedSet)
            )
            findings.append(contentsOf: try auditColumns(db, table))
        }
        return findings
    }

    /// Checks `ON DELETE CASCADE` on any table, synced or not.
    ///
    /// Local-only tables are exempt from the *sync* rules but still rely on
    /// cascades to avoid orphaned analysis rows when a game is deleted.
    public static func auditCascades(
        _ db: Database,
        tables: [String]
    ) throws -> [Finding] {
        var findings: [Finding] = []
        for table in tables where try tableExists(db, table) {
            for key in try foreignKeys(db, table) where key.onDelete.uppercased() != "CASCADE" {
                findings.append(
                    Finding(
                        table: table,
                        kind: .foreignKeyWithoutCascade(
                            column: key.from,
                            references: key.table,
                            onDelete: key.onDelete
                        )
                    )
                )
            }
        }
        return findings
    }

    // MARK: - Individual checks

    private static func auditUniqueIndexes(_ db: Database, _ table: String) throws -> [Finding] {
        // `origin` is 'pk' for the implicit primary-key index, 'u' for a UNIQUE
        // constraint and 'c' for CREATE INDEX. Only 'pk' may be unique.
        let indexes = try #sql(
            """
            SELECT "name" FROM pragma_index_list(\(bind: table))
            WHERE "unique" = 1 AND "origin" <> 'pk'
            """,
            as: String.self
        )
        .fetchAll(db)
        return indexes.map {
            Finding(table: table, kind: .nonPrimaryKeyUniqueIndex(index: $0))
        }
    }

    private static func auditForeignKeys(
        _ db: Database,
        _ table: String,
        syncedTables: Set<String>
    ) throws -> [Finding] {
        var findings: [Finding] = []
        for key in try foreignKeys(db, table) {
            if key.onDelete.uppercased() != "CASCADE" {
                findings.append(
                    Finding(
                        table: table,
                        kind: .foreignKeyWithoutCascade(
                            column: key.from,
                            references: key.table,
                            onDelete: key.onDelete
                        )
                    )
                )
            }
            if !syncedTables.contains(key.table) {
                findings.append(
                    Finding(
                        table: table,
                        kind: .foreignKeyToUnsyncedTable(column: key.from, references: key.table)
                    )
                )
            }
        }
        return findings
    }

    private static func auditColumns(_ db: Database, _ table: String) throws -> [Finding] {
        var findings: [Finding] = []

        // `pk` is 0 for non-key columns, otherwise the 1-based position within
        // the key, so a compound key shows values > 1.
        let primaryKeyColumns = try #sql(
            """
            SELECT "name" FROM pragma_table_info(\(bind: table)) WHERE "pk" > 0 ORDER BY "pk"
            """,
            as: String.self
        )
        .fetchAll(db)

        if primaryKeyColumns.isEmpty {
            findings.append(Finding(table: table, kind: .missingPrimaryKey))
        } else if primaryKeyColumns.count > 1 {
            findings.append(
                Finding(table: table, kind: .compoundPrimaryKey(columns: primaryKeyColumns))
            )
        }

        let undefaulted = try #sql(
            """
            SELECT "name" FROM pragma_table_info(\(bind: table))
            WHERE "notnull" = 1 AND "dflt_value" IS NULL AND "pk" = 0
            """,
            as: String.self
        )
        .fetchAll(db)
        findings.append(
            contentsOf: undefaulted.map {
                Finding(table: table, kind: .notNullColumnWithoutDefault(column: $0))
            }
        )

        return findings
    }

    // MARK: - Pragma helpers

    private struct ForeignKeyInfo {
        var table: String
        var from: String
        var onDelete: String
    }

    private static func foreignKeys(_ db: Database, _ table: String) throws -> [ForeignKeyInfo] {
        // Selected explicitly and in this order because decoding is positional.
        let rows = try #sql(
            """
            SELECT "table", "from", "on_delete" FROM pragma_foreign_key_list(\(bind: table))
            """,
            as: (String, String, String).self
        )
        .fetchAll(db)
        return rows.map { ForeignKeyInfo(table: $0.0, from: $0.1, onDelete: $0.2) }
    }

    private static func tableExists(_ db: Database, _ table: String) throws -> Bool {
        let count = try #sql(
            """
            SELECT count(*) FROM "sqlite_master" WHERE "type" = 'table' AND "name" = \(bind: table)
            """,
            as: Int.self
        )
        .fetchOne(db)
        return (count ?? 0) > 0
    }
}
