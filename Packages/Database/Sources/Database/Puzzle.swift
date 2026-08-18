import Foundation
import SQLiteData

/// A row of the bundled, read-only `puzzles.sqlite` database.
///
/// The column names are `snake_case` because this table is authored by the
/// offline `PuzzlePrep` tool rather than by this package; the schema is a shared
/// contract and is not ours to rename.
@Table("puzzle")
public struct Puzzle: Hashable, Identifiable, Sendable {
    /// The Lichess puzzle ID, e.g. `"00sHx"`.
    public var id: String
    /// Position *before* the opponent's setup move.
    public var fen: String
    /// Space-separated UCI moves. See ``setupMove`` and ``solution``.
    public var moves: String
    public var rating: Int
    @Column("rating_dev") public var ratingDev: Int
    public var popularity: Int
    @Column("nb_plays") public var nbPlays: Int
    @Column("themes_lo") public var themesLo: Int64
    @Column("themes_hi") public var themesHi: Int64
    @Column("game_url") public var gameURL: String?

    public init(
        id: String,
        fen: String,
        moves: String,
        rating: Int,
        ratingDev: Int,
        popularity: Int,
        nbPlays: Int,
        themesLo: Int64,
        themesHi: Int64,
        gameURL: String? = nil
    ) {
        self.id = id
        self.fen = fen
        self.moves = moves
        self.rating = rating
        self.ratingDev = ratingDev
        self.popularity = popularity
        self.nbPlays = nbPlays
        self.themesLo = themesLo
        self.themesHi = themesHi
        self.gameURL = gameURL
    }
}

extension Puzzle {
    /// All UCI moves, setup move first.
    public var moveList: [String] { moves.split(separator: " ").map(String.init) }

    /// The opponent's move that creates the puzzle. It is played *from* ``fen``
    /// before the solver is asked to move.
    public var setupMove: String? { moveList.first }

    /// The moves the solver must find, i.e. everything after ``setupMove``.
    public var solution: [String] { Array(moveList.dropFirst()) }

    public var themes: ThemeMask {
        ThemeMask(storedLow: themesLo, storedHigh: themesHi)
    }

    public init(
        id: String,
        fen: String,
        moves: String,
        rating: Int,
        ratingDev: Int = 75,
        popularity: Int = 100,
        nbPlays: Int = 0,
        themes: ThemeMask,
        gameURL: String? = nil
    ) {
        self.init(
            id: id,
            fen: fen,
            moves: moves,
            rating: rating,
            ratingDev: ratingDev,
            popularity: popularity,
            nbPlays: nbPlays,
            themesLo: themes.storedLow,
            themesHi: themes.storedHigh,
            gameURL: gameURL
        )
    }
}

/// A row of the `meta` key/value table, carrying provenance for the bundled
/// database (source dump date, tool version, puzzle count, …).
@Table("meta")
public struct PuzzleMeta: Hashable, Identifiable, Sendable {
    @Column("key", primaryKey: true) public var key: String
    public var value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
