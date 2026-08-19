import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The guard that catches a rating set to the wrong level.
///
/// It matters more than its size suggests: the curriculum gates on rating, so a
/// rating stuck below the player does not merely climb slowly — it withholds the
/// material they are ready for. The guard only fires on two consecutive checks,
/// which is exactly why the streak counters have to survive between games.
@Suite("Drift guard")
struct DriftGuardTests {

    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    /// Ten finished sparring games, all won against opponents far above the
    /// stored rating — the shape of a player who has genuinely improved.
    private func winStreak(opponentRating: Int, count: Int = 10) -> [Game] {
        (0..<count).map { index in
            Game(
                id: UUID(),
                startedAt: start.addingTimeInterval(Double(index) * 3_600),
                endedAt: start.addingTimeInterval(Double(index) * 3_600 + 600),
                mode: .sparring,
                userColor: .white,
                opponentRating: opponentRating,
                result: "1-0",
                termination: GameTermination.checkmate.rawValue,
                isRated: false
            )
        }
    }

    private func record(opponentRating: Int) -> FinishedGameRecord {
        FinishedGameRecord(
            id: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            mode: "sparring",
            userColor: .white,
            opponentRating: opponentRating,
            result: "1-0",
            termination: GameTermination.checkmate.rawValue,
            pgn: "",
            moves: [],
            opponentParams: FinishedGameRecord.OpponentParams(
                opponentRating: opponentRating,
                baseSeconds: 600,
                incrementSeconds: 5,
                secondTryEnabled: false,
                guidedEnabled: false
            ),
            isRated: true,
            ratingWeight: .sparring
        )
    }

    @Test("The streak counters survive between games")
    func countersPersist() async throws {
        // The bug this pins: both counters were read on every game and written
        // on none, so a streak could never reach the two checks the guard needs.
        let settings = InMemoryAppSettingsStore(settings: AppSettings(userRating: 1_100))
        let metrics = InMemoryMetricStore()
        let games = InMemoryGameStore(games: winStreak(opponentRating: 1_500))
        let writer = LadderRatingWriter(settings: settings, metrics: metrics, games: games)

        _ = try await writer.apply(record(opponentRating: 1_500), at: start)

        let high = metrics.value(LadderRatingWriter.Keys.consecutiveHighDriftChecks)
        #expect(high == 1, "a first high check must be recorded, not discarded")
    }

    @Test("Two consecutive high checks raise K for the games that follow")
    func guardFiresOnSecondCheck() async throws {
        let settings = InMemoryAppSettingsStore(settings: AppSettings(userRating: 1_100))
        let metrics = InMemoryMetricStore()
        let games = InMemoryGameStore(games: winStreak(opponentRating: 1_500))
        let writer = LadderRatingWriter(settings: settings, metrics: metrics, games: games)

        _ = try await writer.apply(record(opponentRating: 1_500), at: start)
        _ = try await writer.apply(record(opponentRating: 1_500), at: start.addingTimeInterval(60))

        #expect(metrics.value(LadderRatingWriter.Keys.driftBoostGamesRemaining) > 0)
        // The guard re-earns itself rather than re-arming every game.
        #expect(metrics.value(LadderRatingWriter.Keys.consecutiveHighDriftChecks) == 0)
    }

    @Test("A rating that matches the results leaves the guard alone")
    func noDriftWhenRatingIsRight() async throws {
        // Opponents at the player's own level: the performance rating lands
        // inside the threshold and nothing should arm.
        let settings = InMemoryAppSettingsStore(settings: AppSettings(userRating: 1_500))
        let metrics = InMemoryMetricStore()
        let games = InMemoryGameStore(
            games: winStreak(opponentRating: 1_300, count: 5)
                + winStreak(opponentRating: 1_300, count: 5).map { game in
                    var loss = game
                    loss.result = "0-1"
                    return loss
                }
        )
        let writer = LadderRatingWriter(settings: settings, metrics: metrics, games: games)

        _ = try await writer.apply(record(opponentRating: 1_300), at: start)

        #expect(metrics.value(LadderRatingWriter.Keys.driftBoostGamesRemaining) == 0)
        #expect(metrics.value(LadderRatingWriter.Keys.consecutiveHighDriftChecks) == 0)
    }

    @Test("Too few games to average over leaves the state untouched")
    func windowMustBeFull() async throws {
        let settings = InMemoryAppSettingsStore(settings: AppSettings(userRating: 1_100))
        let metrics = InMemoryMetricStore()
        let games = InMemoryGameStore(games: winStreak(opponentRating: 1_500, count: 4))
        let writer = LadderRatingWriter(settings: settings, metrics: metrics, games: games)

        _ = try await writer.apply(record(opponentRating: 1_500), at: start)

        #expect(metrics.value(LadderRatingWriter.Keys.consecutiveHighDriftChecks) == 0)
        #expect(metrics.value(LadderRatingWriter.Keys.driftBoostGamesRemaining) == 0)
    }
}
