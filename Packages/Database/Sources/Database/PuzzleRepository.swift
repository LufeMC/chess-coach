import Foundation
import SQLiteData

/// Read-only queries over the bundled puzzle corpus.
///
/// A value type rather than an actor: GRDB's `DatabaseReader` already serialises
/// access and is `Sendable`, so an actor would add scheduling hops without
/// adding safety.
public struct PuzzleRepository: Sendable {
    private let reader: any DatabaseReader

    public init(reader: any DatabaseReader) {
        self.reader = reader
    }

    /// Selects puzzles for a training set.
    ///
    /// - Parameters:
    ///   - ratingRange: Inclusive rating band. Backed by the `puzzle_rating`
    ///     index, so this is what keeps the scan small.
    ///   - themes: Match puzzles carrying **any** of these themes. Empty means
    ///     "no theme filter".
    ///   - limit: Maximum number of puzzles to return.
    ///   - excluding: Puzzle IDs the user has already seen. Intended for a
    ///     recent-history window; this becomes an `IN` list, so passing tens of
    ///     thousands of IDs will hurt.
    /// - Returns: Up to `limit` puzzles in random order.
    public func puzzles(
        ratingRange: ClosedRange<Int>,
        themes: ThemeMask = .empty,
        limit: Int = 1,
        excluding excludedIDs: Set<Puzzle.ID> = []
    ) throws -> [Puzzle] {
        guard limit > 0 else { return [] }
        // Predicates are chained rather than built inside one result-builder
        // closure: `QueryFragmentBuilder.buildBlock` takes a single component,
        // so a multi-statement closure will not compile. Each `.where` appends
        // one ANDed term, which makes the optional filters easy to skip.
        var query = Puzzle.where {
            $0.rating.between(ratingRange.lowerBound, and: ratingRange.upperBound)
        }
        if !themes.isEmpty {
            // "Any of these themes": a non-zero intersection in either half of
            // the split 73-bit mask.
            query = query.where {
                ($0.themesLo & themes.storedLow).neq(Int64(0))
                    || ($0.themesHi & themes.storedHigh).neq(Int64(0))
            }
        }
        if !excludedIDs.isEmpty {
            query = query.where { $0.id.notIn(excludedIDs) }
        }
        return try reader.read { db in
            try query
                // `ORDER BY random()` sorts the whole candidate set, which is
                // acceptable precisely because the rating band has already cut
                // the corpus down via the `puzzle_rating` index. Widen the band
                // far enough and this stops being cheap.
                .order { _ in #sql("random()") }
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func puzzle(id: Puzzle.ID) throws -> Puzzle? {
        try reader.read { db in
            try Puzzle.where { $0.id.eq(id) }.fetchOne(db)
        }
    }

    /// Number of puzzles in a rating band — used to size the difficulty ladder
    /// and to warn when a band is too sparse to sample from.
    public func count(ratingRange: ClosedRange<Int>) throws -> Int {
        try reader.read { db in
            try Puzzle
                .where { $0.rating.between(ratingRange.lowerBound, and: ratingRange.upperBound) }
                .fetchCount(db)
        }
    }

    /// The full rating span present in the corpus, or `nil` when it is empty.
    public func ratingBounds() throws -> ClosedRange<Int>? {
        try reader.read { db in
            let lowest = try Puzzle.select { $0.rating.min() }.fetchOne(db)
            let highest = try Puzzle.select { $0.rating.max() }.fetchOne(db)
            // Double optional: no row at all, versus a row whose aggregate is
            // NULL because the table is empty.
            guard let low = lowest ?? nil, let high = highest ?? nil else { return nil }
            return low...high
        }
    }

    /// Provenance written by the offline tool: source dump date, tool version,
    /// puzzle count, theme-format version, and so on.
    public func metadata() throws -> [String: String] {
        try reader.read { db in
            let rows = try PuzzleMeta.all.fetchAll(db)
            return Dictionary(rows.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    public func metadata(key: String) throws -> String? {
        try reader.read { db in
            try PuzzleMeta.where { $0.key.eq(key) }.select(\.value).fetchOne(db)
        }
    }

}
