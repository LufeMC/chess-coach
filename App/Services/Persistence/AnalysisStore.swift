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

    /// Writes classification and win percentages back onto the move rows.
    ///
    /// One transaction for the whole game: a review screen that showed half the
    /// moves classified and half not would look broken, and there is no partial
    /// state worth preserving if the write fails.
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
                    }
                    .execute(db)
            }
        }
    }
}
