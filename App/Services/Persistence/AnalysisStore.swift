import Database
import Foundation
import OSLog
import SQLiteData

/// Every database touch the post-game pass makes, in one place.
///
/// Separate from ``GamePersistence`` because the two have different lifetimes and
/// different failure modes: losing a game is data loss, whereas losing an
/// analysis is a re-run. Keeping them apart also keeps the analysis actor from
/// holding a reference to anything the play surface uses.
struct AnalysisStore: Sendable {

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Reads

    func game(id: UUID) throws -> GameRow? {
        try database.games.game(id: id)
    }

    func moves(forGame gameID: UUID) throws -> [GameMoveRow] {
        try database.games.moves(forGame: gameID)
    }

    /// Evaluations already on disk for this game — the resume checkpoint.
    func evals(forGame gameID: UUID) throws -> [PlyEvalRow] {
        try database.games.evals(forGame: gameID)
    }

    func pending(limit: Int) throws -> [GameRow] {
        try database.games.awaitingAnalysis(limit: limit)
    }

    /// Games left in `running` by a pass that never got to finish — a crash, a
    /// force-quit, a jetsam kill.
    ///
    /// There is no repository query for "running", and adding one to the package
    /// is out of scope here, so this scans the recent games instead. That is
    /// sound because a stuck game is by definition one of the newest: nothing
    /// older can be running.
    func stalled(limit: Int = 50) throws -> [GameRow] {
        try database.games.recent(limit: limit).filter { $0.analysis == .running }
    }

    /// Games whose pass ended in `failed`.
    ///
    /// Same scan as ``stalled(limit:)`` and for the same reason. Bounded to the
    /// recent games on purpose as well as for convenience: a failure from
    /// hundreds of games ago has already been overtaken by everything the user
    /// has played since, and re-running it would spend the engine on a review
    /// nobody is waiting for.
    func failed(limit: Int = 50) throws -> [GameRow] {
        // `isFinished` because the queue only ever offers finished games: a
        // requeued game that has not ended would sit in `pending` for good,
        // which is a worse state than the one it came from.
        try database.games.recent(limit: limit).filter { $0.analysis == .failed && $0.isFinished }
    }

    /// The two settings that shape moment selection.
    func policyInputs() throws -> (weeklyFocusHabit: String?, currentRung: Int) {
        let settings = try database.settings.current()
        return (settings.weeklyFocusHabit, settings.currentRung)
    }

    // MARK: - Writes

    func setState(_ state: AnalysisState, forGame gameID: UUID) throws {
        try database.games.setAnalysisState(state, forGame: gameID)
    }

    /// Replaces this game's stored evaluations.
    ///
    /// Whole-file replacement rather than a merge, which is what the repository
    /// offers and what re-analysis wants. The pass therefore always writes the
    /// *complete accumulated prefix* it has, never a partial delta — see
    /// `AnalysisService.evaluateAllPlies`.
    func storeEvals(_ evals: [PlyEvalRow], forGame gameID: UUID) throws {
        try database.games.replaceEvals(evals, forGame: gameID)
    }

    func setAccuracy(_ accuracy: Double?, forGame gameID: UUID) throws {
        try database.games.setAccuracy(accuracy, forGame: gameID)
    }

    /// Replaces this game's moments with a freshly selected set.
    ///
    /// Re-analysis has to be idempotent, and `MomentRepository` only inserts, so
    /// the delete happens here. Anything the user already worked through is left
    /// alone: a reviewed moment has earned its place in the history even if a
    /// deeper re-analysis would no longer pick it.
    ///
    /// The coaching note rides inside the row rather than being patched onto it
    /// afterwards, which is what keeps a second pass honest: the note is replaced
    /// together with the moment it describes, so there is no window in which a
    /// deeper search has changed the verdict while the previous pass's
    /// explanation is still on screen underneath it.
    func replaceMoments(_ moments: [MomentRow], forGame gameID: UUID) throws {
        try database.user.writer.write { db in
            try MomentRow
                .where { $0.gameID.eq(gameID) }
                .where { $0.status.eq(MomentStatus.new.rawValue) }
                .delete()
                .execute(db)

            guard !moments.isEmpty else { return }
            try MomentRow.insert { moments }.execute(db)
        }
    }

    /// Writes classification, win percentages and accuracy back onto the move
    /// rows.
    ///
    /// One transaction for the whole game: a review screen that showed half the
    /// moves classified and half not would look broken, and there is no partial
    /// state worth preserving if the write fails.
    ///
    /// Accuracy is written rather than left to be recomputed from the two win
    /// percentages. It is derivable, but only under a contract that lives in the
    /// analysis layer — both percentages have to be mover-relative — and a reader
    /// that re-derived it would have to restate that contract correctly or
    /// produce plausible-looking garbage. Writing it once, next to the numbers it
    /// came from, is the version that cannot drift.
    ///
    /// The opponent's rows are written too, with `nil`: accuracy is a user-move
    /// measure, and re-analysis has to be able to clear a value it no longer
    /// stands behind.
    func applyMoveOutcomes(_ outcomes: [AnalyzedMove]) throws {
        guard !outcomes.isEmpty else { return }
        try database.user.writer.write { db in
            for outcome in outcomes {
                try GameMoveRow
                    .find(outcome.id)
                    .update {
                        $0.classification = #bind(outcome.classification)
                        $0.winPctBefore = #bind(outcome.winPctBefore)
                        $0.winPctAfter = #bind(outcome.winPctAfter)
                        $0.accuracy = #bind(outcome.accuracy)
                    }
                    .execute(db)
            }
        }
    }
}
