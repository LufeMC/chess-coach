import Database

// Aliases for the persisted record types.
//
// Two of them collide with types of the same name elsewhere in the app's
// dependency graph: `Game` with `ChessKit.Game`, and `Moment` with
// `AnalysisKit.Moment`. The obvious fix — writing `Database.Game` — does not
// work, because GRDB (re-exported through SQLiteData) exports a *class* named
// `Database`, so the qualifier resolves to that class and the compiler reports
// the confusing "'Game' is not a member type of class 'GRDB.Database'".
//
// Aliasing them once here, in a file that imports nothing but the package, binds
// the names unambiguously and lets the rest of the app use `GameRow`/`MomentRow`
// without repeating the workaround.

typealias GameRow = Game
typealias GameMoveRow = GameMove
typealias MomentRow = Moment
typealias PlyEvalRow = PlyEval
