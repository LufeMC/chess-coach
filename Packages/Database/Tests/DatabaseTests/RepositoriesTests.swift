import Foundation
import SQLiteData
import Testing

@testable import Database

/// Erasing the device.
///
/// The app has no account, so uninstalling was the only way to clear it. The
/// tests here pin the two things the Settings row promises: that the counts it
/// prices the loss with are the counts actually in the database, and that a
/// wipe takes the measurements while leaving the presentation choices alone.
@Suite("Deleting all user data")
struct UserDataErasureTests {

    private func populated() throws -> UserDatabase {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .sparring, userColor: .white, opponentRating: 1200, pgn: "1. e4")
        try database.games.insert(
            game,
            moves: [GameMove(gameID: game.id, ply: 1, san: "e4", uci: "e2e4")]
        )
        try database.moments.insert([
            Moment(
                gameID: game.id,
                ply: 5,
                fen: "8/8/8/8/8/8/8/8 w - - 0 1",
                kind: "blunder",
                causeTag: "hungMovedPiece",
                stepTag: "play",
                playedSAN: "Nf3",
                playedUCI: "g1f3",
                bestSAN: "Qe2",
                bestUCI: "d1e2",
                deltaEP: 0.4,
                score: 1
            )
        ])
        try database.srs.save(SRSCard(kind: "puzzle", puzzleID: "p1"))
        try database.metrics.upsert(key: "retry.attempts", window: "allTime", value: 4)
        try database.dailyLoop.update(day: "2026-08-21") { $0.puzzlesDone = 10 }
        try database.concepts.markIntroduced(id: "backRank")
        try database.calibrationDrafts.save(payload: "{}")
        try database.settings.update {
            $0.userRating = 1466
            $0.puzzleRating = 1310
            $0.currentRung = 3
            $0.boardTheme = "slate"
            $0.soundOn = false
        }
        return database
    }

    @Test("The summary counts what is actually there, so the sheet can price the loss")
    func summaryCountsRows() throws {
        let database = try populated()
        let summary = try database.userDataSummary()
        #expect(summary.games == 1)
        #expect(summary.moments == 1)
        #expect(summary.cards == 1)
        #expect(summary.metrics == 1)
        #expect(summary.rating == 1466)
        #expect(!summary.isEmpty)
    }

    @Test("A calibrated player with no games yet still has something to delete")
    func calibratedButUnplayed() throws {
        // Calibration writes its outcome before the first sparring game is ever
        // played. A row disabled on "no games" would be refusing to delete data
        // the user can see on their own Profile.
        let database = try UserDatabase.inMemory()
        try database.metrics.upsert(key: "ladder.rating", window: "allTime", value: 1_066)
        let summary = try database.userDataSummary()
        #expect(summary.games == 0)
        #expect(!summary.isEmpty)
    }

    @Test("An untouched database reports nothing to lose")
    func emptySummary() throws {
        let database = try UserDatabase.inMemory()
        let summary = try database.userDataSummary()
        #expect(summary.isEmpty)
    }

    @Test("Every record of play goes, in one pass")
    func wipeRemovesEverything() throws {
        let database = try populated()
        try database.deleteAllUserData()

        let summary = try database.userDataSummary()
        #expect(summary.games == 0)
        #expect(summary.moments == 0)
        #expect(summary.cards == 0)
        #expect(summary.metrics == 0)
        #expect(try database.metrics.all().isEmpty)
        #expect(try database.concepts.all().isEmpty)
        #expect(try database.calibrationDrafts.current() == nil)
        #expect(try database.dailyLoop.recent(limit: 10).isEmpty)
    }

    @Test("Measurements reset; the board and sound choices do not")
    func wipeKeepsPresentationChoices() throws {
        let database = try populated()
        try database.deleteAllUserData()

        let settings = try database.settings.current()
        // A user clearing their games has not asked to have the sound turned
        // back on, and silently undoing a choice they made weeks ago is the app
        // taking more than the confirmation said it would.
        #expect(settings.boardTheme == "slate")
        #expect(settings.soundOn == false)
        // Everything that is a measurement goes back to its default, so the
        // next launch re-measures rather than showing a rating nobody earned.
        #expect(settings.userRating == AppSettings().userRating)
        #expect(settings.puzzleRating == AppSettings().puzzleRating)
        #expect(settings.currentRung == 1)
        #expect(settings.id == AppSettings.singletonID)
    }

    @Test("The calibration marker goes with it, so the gate reopens")
    func wipeClearsTheCalibrationMarker() throws {
        let database = try populated()
        try database.metrics.upsert(
            key: "calibration.completedAt",
            window: "allTime",
            value: 1_770_000_000
        )
        try database.deleteAllUserData()
        #expect(try database.metrics.metric(key: "calibration.completedAt", window: "allTime") == nil)
    }

    @Test("Wiping twice is not an error")
    func wipeIsIdempotent() throws {
        let database = try populated()
        try database.deleteAllUserData()
        try database.deleteAllUserData()
        #expect(try database.userDataSummary().isEmpty)
    }
}
