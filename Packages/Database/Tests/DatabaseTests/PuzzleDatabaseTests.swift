import Foundation
import SQLiteData
import Testing

@testable import Database

/// Builds a throwaway `puzzles.sqlite` using the exact DDL the offline
/// PuzzlePrep tool emits, so these tests fail if either side drifts.
private final class PuzzleFixture {
    let url: URL

    init(puzzles: [Puzzle], meta: [String: String] = [:]) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("puzzle-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("puzzles.sqlite")

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try #sql(
                """
                CREATE TABLE puzzle (
                  id TEXT PRIMARY KEY, fen TEXT NOT NULL, moves TEXT NOT NULL,
                  rating INTEGER NOT NULL, rating_dev INTEGER NOT NULL,
                  popularity INTEGER NOT NULL, nb_plays INTEGER NOT NULL,
                  themes_lo INTEGER NOT NULL, themes_hi INTEGER NOT NULL, game_url TEXT
                )
                """
            )
            .execute(db)
            try #sql(#"CREATE INDEX puzzle_rating ON puzzle(rating)"#).execute(db)
            try #sql(
                #"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"#
            )
            .execute(db)

            if !puzzles.isEmpty {
                try Puzzle.insert { puzzles }.execute(db)
            }
            for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
                try PuzzleMeta.insert { PuzzleMeta(key: key, value: value) }.execute(db)
            }
        }
        // Close the writer before the read-only connection opens.
        try queue.close()
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@Suite("Puzzle database")
struct PuzzleDatabaseTests {

    private static func samplePuzzles() -> [Puzzle] {
        [
            Puzzle(
                id: "p1000",
                fen: "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 4 4",
                moves: "d7d5 f3f7",
                rating: 1000,
                themes: ThemeMask([.mateIn1, .short, .opening])
            ),
            Puzzle(
                id: "p1200",
                fen: "8/8/8/8/8/5k2/6q1/7K w - - 0 1",
                moves: "h1h2 g2g3",
                rating: 1200,
                themes: ThemeMask([.mateIn2, .endgame])
            ),
            Puzzle(
                id: "p1400",
                fen: "8/8/8/3k4/8/8/3P4/3K4 w - - 0 1",
                moves: "d1e2 d5d4",
                rating: 1400,
                themes: ThemeMask([.pawnEndgame, .long])
            ),
            Puzzle(
                id: "p1600",
                fen: "rnbqkb1r/pppp1ppp/5n2/4p3/4P3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 0 3",
                moves: "f6e4 c3e4",
                rating: 1600,
                themes: ThemeMask([.fork, .middlegame])
            ),
            Puzzle(
                id: "p1800",
                fen: "8/8/8/8/8/8/8/K6k w - - 0 1",
                moves: "a1a2 h1h2",
                // Deliberately spans both halves of the 73-bit mask.
                rating: 1800,
                themes: ThemeMask([.fork, .mix, .puzzleDownloadInformation])
            ),
        ]
    }

    @Test("Opens read-only and round-trips a puzzle")
    func opensAndReadsPuzzle() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        let puzzle = try #require(try database.puzzles.puzzle(id: "p1200"))
        #expect(puzzle.rating == 1200)
        #expect(puzzle.moves == "h1h2 g2g3")
        #expect(puzzle.setupMove == "h1h2")
        #expect(puzzle.solution == ["g2g3"])
        #expect(puzzle.themes.contains(.mateIn2))
        #expect(puzzle.themes.contains(.endgame))
        #expect(!puzzle.themes.contains(.fork))
    }

    @Test("Missing puzzles return nil, missing files throw")
    func missingLookups() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)
        #expect(try database.puzzles.puzzle(id: "nope") == nil)

        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).sqlite")
        #expect(throws: PuzzleDatabaseError.self) {
            _ = try PuzzleDatabase.open(at: absent)
        }
    }

    @Test("The connection really is read-only")
    func connectionIsReadOnly() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)
        // A DatabaseReader offers no write API at compile time; this proves the
        // underlying connection would reject one too.
        #expect(throws: (any Error).self) {
            try database.reader.unsafeReentrantRead { db in
                try #sql(#"DELETE FROM puzzle"#).execute(db)
            }
        }
        #expect(try database.puzzles.count(ratingRange: 0...9999) == 5)
    }

    @Test("Rating band filters and counts")
    func ratingBand() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        #expect(try database.puzzles.count(ratingRange: 1200...1600) == 3)
        #expect(try database.puzzles.count(ratingRange: 1000...1000) == 1)
        #expect(try database.puzzles.count(ratingRange: 2000...2500) == 0)

        let inBand = try database.puzzles.puzzles(ratingRange: 1200...1600, limit: 10)
        #expect(inBand.count == 3)
        #expect(inBand.allSatisfy { (1200...1600).contains($0.rating) })
        #expect(Set(inBand.map(\.id)) == ["p1200", "p1400", "p1600"])

        #expect(try database.puzzles.ratingBounds() == 1000...1800)
    }

    @Test("Theme filter matches any of the requested themes")
    func themeFilter() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        let forks = try database.puzzles.puzzles(
            ratingRange: 0...9999,
            themes: ThemeMask([.fork]),
            limit: 10
        )
        #expect(Set(forks.map(\.id)) == ["p1600", "p1800"])

        // Any-of, not all-of.
        let either = try database.puzzles.puzzles(
            ratingRange: 0...9999,
            themes: ThemeMask([.mateIn1, .pawnEndgame]),
            limit: 10
        )
        #expect(Set(either.map(\.id)) == ["p1000", "p1400"])

        let none = try database.puzzles.puzzles(
            ratingRange: 0...9999,
            themes: ThemeMask([.zugzwang]),
            limit: 10
        )
        #expect(none.isEmpty)
    }

    @Test("Theme filter works on bits stored in the high column")
    func highBitThemeFilter() throws {
        // Bits 63+ live in themes_hi; a filter that only consulted themes_lo
        // would silently return nothing here.
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        #expect(PuzzleTheme.puzzleDownloadInformation.bit >= ThemeMask.lowBitCount)
        let matches = try database.puzzles.puzzles(
            ratingRange: 0...9999,
            themes: ThemeMask([.puzzleDownloadInformation]),
            limit: 10
        )
        #expect(matches.map(\.id) == ["p1800"])
    }

    @Test("Excluded ids are never returned")
    func exclusions() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        let remaining = try database.puzzles.puzzles(
            ratingRange: 0...9999,
            limit: 10,
            excluding: ["p1000", "p1200", "p1400"]
        )
        #expect(Set(remaining.map(\.id)) == ["p1600", "p1800"])

        let all = try database.puzzles.puzzles(
            ratingRange: 0...9999,
            limit: 10,
            excluding: Set(Self.samplePuzzles().map(\.id))
        )
        #expect(all.isEmpty)
    }

    @Test("Limit is respected, and a non-positive limit returns nothing")
    func limits() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        #expect(try database.puzzles.puzzles(ratingRange: 0...9999, limit: 2).count == 2)
        #expect(try database.puzzles.puzzles(ratingRange: 0...9999, limit: 99).count == 5)
        #expect(try database.puzzles.puzzles(ratingRange: 0...9999, limit: 0).isEmpty)
    }

    @Test("Selection is randomised rather than always returning the same row")
    func selectionIsRandomised() throws {
        let fixture = try PuzzleFixture(puzzles: Self.samplePuzzles())
        let database = try PuzzleDatabase.open(at: fixture.url)

        var seen: Set<String> = []
        for _ in 0..<60 {
            let picked = try database.puzzles.puzzles(ratingRange: 0...9999, limit: 1)
            #expect(picked.count == 1)
            seen.formUnion(picked.map(\.id))
        }
        // With 5 candidates and 60 draws, drawing the same one every time has
        // probability 5 * (1/5)^60 — this cannot flake in practice.
        #expect(seen.count > 1)
    }

    @Test("Metadata is readable")
    func metadata() throws {
        let fixture = try PuzzleFixture(
            puzzles: Self.samplePuzzles(),
            meta: [
                "source": "lichess_db_puzzle.csv.zst",
                "builtAt": "2026-08-17",
                "puzzleCount": "5",
                "themeFormatVersion": "1",
            ]
        )
        let database = try PuzzleDatabase.open(at: fixture.url)

        let all = try database.puzzles.metadata()
        #expect(all["source"] == "lichess_db_puzzle.csv.zst")
        #expect(all["puzzleCount"] == "5")
        #expect(all.count == 4)
        #expect(try database.puzzles.metadata(key: "themeFormatVersion") == "1")
        #expect(try database.puzzles.metadata(key: "absent") == nil)
    }

    @Test("An empty corpus degrades gracefully")
    func emptyCorpus() throws {
        let fixture = try PuzzleFixture(puzzles: [])
        let database = try PuzzleDatabase.open(at: fixture.url)
        #expect(try database.puzzles.count(ratingRange: 0...9999) == 0)
        #expect(try database.puzzles.puzzles(ratingRange: 0...9999, limit: 5).isEmpty)
        #expect(try database.puzzles.ratingBounds() == nil)
        #expect(try database.puzzles.metadata().isEmpty)
    }
}
