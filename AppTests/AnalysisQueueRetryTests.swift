import Database
import Foundation
import Testing

@testable import ChessCoach

// The analysis queue's memory of what it has already tried, exercised end to end
// with no Stockfish anywhere near it.
//
// The trick that makes that possible is the fixture: a finished game with no
// moves is completed by `analyze` before it ever asks for an engine lease, so
// the queue's bookkeeping — requeueing, retrying, refusing to retry twice — can
// be driven for real while the engine stays untouched.

@Suite("Analysis queue retries")
struct AnalysisQueueRetryTests {

    private struct Fixture {
        var service: AnalysisService
        var database: AppDatabase
        var gameID: UUID
    }

    private func makeFixture() throws -> Fixture {
        let user = try UserDatabase.inMemory()
        let database = AppDatabase(user: user, puzzles: nil)
        let game = GameRow(mode: .sparring, userColor: .white, opponentRating: 1_200)
        try database.games.insert(game)
        // Only finished games are ever offered to the queue.
        try database.games.finish(id: game.id, result: "1-0", termination: "checkmate", pgn: "")
        return Fixture(
            service: AnalysisService(engineService: EngineService(), store: AnalysisStore(database: database)),
            database: database,
            gameID: game.id
        )
    }

    private func analysisState(_ context: Fixture) throws -> AnalysisState? {
        try context.database.games.game(id: context.gameID)?.analysis
    }

    @Test("A pass that failed is offered to the queue again")
    func failedPassIsRetried() async throws {
        // `failed` used to be terminal: the game kept its place in the user's
        // history with no eval curve and no moments, permanently, however
        // momentary the cause had been.
        let context = try makeFixture()
        try context.database.games.setAnalysisState(.failed, forGame: context.gameID)

        await context.service.analyzePending()

        #expect(try analysisState(context) == .complete)
    }

    @Test("A pass that keeps failing is not retried a second time")
    func failedPassIsRetriedOnlyOncePerLaunch() async throws {
        // Some failures are permanent — a stored move that will not replay — and
        // `analysisState` has no room for an attempt count, so the retry budget
        // lives in memory and is spent once.
        let context = try makeFixture()
        try context.database.games.setAnalysisState(.failed, forGame: context.gameID)
        await context.service.analyzePending()

        // Stand in for a pass that failed all over again.
        try context.database.games.setAnalysisState(.failed, forGame: context.gameID)
        await context.service.analyzePending()

        #expect(try analysisState(context) == .failed)
    }

    @Test("A game left running by a previous launch is still recovered")
    func stalledPassIsRequeued() async throws {
        let context = try makeFixture()
        try context.database.games.setAnalysisState(.running, forGame: context.gameID)

        await context.service.analyzePending()

        #expect(try analysisState(context) == .complete)
    }

    @Test("A pending game is analysed without any retry bookkeeping")
    func pendingGameIsAnalysed() async throws {
        let context = try makeFixture()

        await context.service.analyzePending()

        #expect(try analysisState(context) == .complete)
    }
}
