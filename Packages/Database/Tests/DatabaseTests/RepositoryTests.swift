import Foundation
import SQLiteData
import Testing

@testable import Database

/// Dates are stored as ISO-8601 text with millisecond precision, so a
/// round-tripped `Date` is close to — but not bit-identical with — the original.
private func expectSameInstant(
    _ lhs: Date?,
    _ rhs: Date?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let lhs, let rhs else {
        #expect(lhs == nil && rhs == nil, sourceLocation: sourceLocation)
        return
    }
    #expect(abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.01,
        sourceLocation: sourceLocation)
}

@Suite("Game repository")
struct GameRepositoryTests {

    @Test("A game and its moves round-trip in one transaction")
    func insertRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        let started = Date(timeIntervalSince1970: 1_770_000_000)
        let game = Game(
            startedAt: started,
            mode: .sparring,
            userColor: .black,
            opponentParams: #"{"style":"aggressive"}"#,
            opponentRating: 1350,
            pgn: "1. e4 e5",
            isRated: true
        )
        let moves = [
            GameMove(gameID: game.id, ply: 1, san: "e4", uci: "e2e4", thinkTimeMs: 900),
            GameMove(
                gameID: game.id,
                ply: 2,
                san: "e5",
                uci: "e7e5",
                classification: "best",
                winPctBefore: 50.5,
                winPctAfter: 50.1,
                thinkTimeMs: 1500
            ),
        ]
        try database.games.insert(game, moves: moves)

        let loaded = try #require(try database.games.game(id: game.id))
        #expect(loaded.id == game.id)
        #expect(loaded.mode == "sparring")
        #expect(loaded.gameMode == .sparring)
        #expect(loaded.color == .black)
        #expect(loaded.opponentRating == 1350)
        #expect(loaded.opponentParams == #"{"style":"aggressive"}"#)
        #expect(loaded.pgn == "1. e4 e5")
        #expect(loaded.isRated)
        #expect(loaded.analysis == .pending)
        #expect(loaded.endedAt == nil)
        #expect(!loaded.isFinished)
        expectSameInstant(loaded.startedAt, started)

        let loadedMoves = try database.games.moves(forGame: game.id)
        #expect(loadedMoves.map(\.ply) == [1, 2])
        #expect(loadedMoves.map(\.san) == ["e4", "e5"])
        #expect(loadedMoves[1].classification == "best")
        #expect(loadedMoves[1].winPctBefore == 50.5)
        #expect(loadedMoves[0].winPctBefore == nil)
        #expect(loadedMoves[1].thinkTimeMs == 1500)
    }

    @Test("Insert is atomic: a bad move list rolls the game back too")
    func insertIsAtomic() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .sparring, userColor: .white, opponentRating: 1200)
        // The second move points at a game that does not exist, so the foreign
        // key fires mid-transaction.
        #expect(throws: (any Error).self) {
            try database.games.insert(
                game,
                moves: [
                    GameMove(gameID: game.id, ply: 1, san: "e4", uci: "e2e4"),
                    GameMove(gameID: UUID(), ply: 2, san: "e5", uci: "e7e5"),
                ]
            )
        }
        #expect(try database.games.game(id: game.id) == nil)
    }

    @Test("Recent games come back newest first")
    func recentOrdering() throws {
        let database = try UserDatabase.inMemory()
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for offset in 0..<5 {
            try database.games.insert(
                Game(
                    startedAt: base.addingTimeInterval(Double(offset) * 3600),
                    mode: .sparring,
                    userColor: .white,
                    opponentRating: 1200 + offset
                )
            )
        }
        let recent = try database.games.recent(limit: 3)
        #expect(recent.count == 3)
        #expect(recent.map(\.opponentRating) == [1204, 1203, 1202])
    }

    @Test("Finishing a game records result, termination and accuracy")
    func finishGame() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .calibration, userColor: .white, opponentRating: 1500)
        try database.games.insert(game)

        let ended = Date(timeIntervalSince1970: 1_770_003_600)
        try database.games.finish(
            id: game.id,
            result: GameResult.whiteWins.rawValue,
            termination: "checkmate",
            pgn: "1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#",
            endedAt: ended
        )
        try database.games.setAccuracy(87.5, forGame: game.id)
        try database.games.setAnalysisState(.complete, forGame: game.id)

        let loaded = try #require(try database.games.game(id: game.id))
        #expect(loaded.result == "1-0")
        #expect(loaded.termination == "checkmate")
        #expect(loaded.userAccuracy == 87.5)
        #expect(loaded.analysis == .complete)
        #expect(loaded.isFinished)
        expectSameInstant(loaded.endedAt, ended)
    }

    @Test("Only finished, pending games await analysis")
    func awaitingAnalysis() throws {
        let database = try UserDatabase.inMemory()
        let unfinished = Game(mode: .sparring, userColor: .white, opponentRating: 1200)
        let finished = Game(mode: .sparring, userColor: .white, opponentRating: 1300)
        let analysed = Game(mode: .sparring, userColor: .white, opponentRating: 1400)
        try database.games.insert(unfinished)
        try database.games.insert(finished)
        try database.games.insert(analysed)

        try database.games.finish(id: finished.id, result: "1-0", termination: "resign", pgn: "")
        try database.games.finish(id: analysed.id, result: "0-1", termination: "resign", pgn: "")
        try database.games.setAnalysisState(.complete, forGame: analysed.id)

        let queue = try database.games.awaitingAnalysis()
        #expect(queue.map(\.id) == [finished.id])
    }

    @Test("Evals replace wholesale on re-analysis")
    func evalsRoundTripAndReplace() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .sparring, userColor: .white, opponentRating: 1200)
        try database.games.insert(game)

        try database.games.replaceEvals(
            [
                PlyEval(gameID: game.id, ply: 1, pv1Cp: 25, pv1: "e2e4 e7e5", nodes: 900,
                    depth: 16),
                PlyEval(gameID: game.id, ply: 2, pv1Mate: 3, pv1: "d1h5", nodes: 1200, depth: 18),
            ],
            forGame: game.id
        )
        var evals = try database.games.evals(forGame: game.id)
        #expect(evals.count == 2)
        #expect(evals[0].pv1Cp == 25)
        #expect(evals[0].pv1Mate == nil)
        #expect(evals[0].pv1 == "e2e4 e7e5")
        #expect(evals[1].pv1Mate == 3)
        #expect(evals[1].depth == 18)

        try database.games.replaceEvals(
            [PlyEval(gameID: game.id, ply: 1, pv1Cp: 30, pv1: "d2d4", nodes: 5000, depth: 22)],
            forGame: game.id
        )
        evals = try database.games.evals(forGame: game.id)
        #expect(evals.count == 1)
        #expect(evals[0].pv1Cp == 30)
        #expect(evals[0].nodes == 5000)
    }

    @Test("Device calibration keeps the newest measurement")
    func calibrationRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        #expect(try database.games.latestCalibration() == nil)

        let older = DeviceCalibration(
            benchNps: 900_000,
            nodeBudget: 200_000,
            threads: 2,
            hashMB: 32,
            calibratedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let newer = DeviceCalibration(
            benchNps: 1_500_000,
            nodeBudget: 400_000,
            threads: 4,
            hashMB: 64,
            calibratedAt: Date(timeIntervalSince1970: 1_770_090_000)
        )
        try database.games.saveCalibration(older)
        try database.games.saveCalibration(newer)

        let latest = try #require(try database.games.latestCalibration())
        #expect(latest.id == newer.id)
        #expect(latest.benchNps == 1_500_000)
        #expect(latest.threads == 4)
        #expect(latest.hashMB == 64)
    }
}

@Suite("Moment repository")
struct MomentRepositoryTests {

    private func makeMoment(
        gameID: Game.ID,
        ply: Int = 12,
        score: Double = 0.8,
        modifiers: [String] = ["timeTrouble"]
    ) -> Moment {
        Moment(
            gameID: gameID,
            ply: ply,
            fen: "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR b KQkq - 5 4",
            kind: "blunder",
            causeTag: "missedFork",
            stepTag: "calculate",
            modifiers: Moment.encodeModifiers(modifiers),
            playedSAN: "Nf6",
            playedUCI: "g8f6",
            bestSAN: "Qe7",
            bestUCI: "d8e7",
            deltaEP: -0.62,
            score: score
        )
    }

    @Test("Moments round-trip with their JSON modifiers")
    func momentRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .guided, userColor: .white, opponentRating: 1250)
        try database.games.insert(game)

        let moment = makeMoment(gameID: game.id, modifiers: ["timeTrouble", "opponentThreat"])
        try database.moments.insert([moment])

        let loaded = try #require(try database.moments.moments(forGame: game.id).first)
        #expect(loaded.id == moment.id)
        #expect(loaded.kind == "blunder")
        #expect(loaded.causeTag == "missedFork")
        #expect(loaded.stepTag == "calculate")
        #expect(loaded.playedUCI == "g8f6")
        #expect(loaded.bestSAN == "Qe7")
        #expect(loaded.deltaEP == -0.62)
        #expect(loaded.modifierList == ["timeTrouble", "opponentThreat"])
        #expect(loaded.momentStatus == .new)
        #expect(loaded.coachText == nil)
    }

    @Test("Malformed modifier JSON degrades to an empty list")
    func malformedModifiers() throws {
        var moment = makeMoment(gameID: UUID())
        moment.modifiers = "{not json"
        #expect(moment.modifierList == [])
    }

    @Test("Moments for a game come back in board order")
    func momentOrdering() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .guided, userColor: .white, opponentRating: 1250)
        try database.games.insert(game)
        try database.moments.insert([
            makeMoment(gameID: game.id, ply: 30),
            makeMoment(gameID: game.id, ply: 8),
            makeMoment(gameID: game.id, ply: 19),
        ])
        #expect(try database.moments.moments(forGame: game.id).map(\.ply) == [8, 19, 30])
    }

    @Test("Pending moments are ranked by score and respond to status changes")
    func pendingAndStatus() throws {
        let database = try UserDatabase.inMemory()
        let game = Game(mode: .guided, userColor: .white, opponentRating: 1250)
        try database.games.insert(game)

        let low = makeMoment(gameID: game.id, ply: 4, score: 0.2)
        let high = makeMoment(gameID: game.id, ply: 6, score: 0.95)
        let mid = makeMoment(gameID: game.id, ply: 8, score: 0.6)
        try database.moments.insert([low, high, mid])

        #expect(try database.moments.pending().map(\.id) == [high.id, mid.id, low.id])
        #expect(try database.moments.count(status: .new) == 3)

        try database.moments.setStatus(.reviewed, forMoment: high.id)
        #expect(try database.moments.pending().map(\.id) == [mid.id, low.id])
        #expect(try database.moments.count(status: .new) == 2)
        #expect(try database.moments.count(status: .reviewed) == 1)

        try database.moments.setCoachText("You missed a knight fork on e5.", forMoment: mid.id)
        let coached = try #require(
            try database.moments.moments(forGame: game.id).first { $0.id == mid.id }
        )
        #expect(coached.coachText == "You missed a knight fork on e5.")
    }
}

@Suite("SRS repository")
struct SRSRepositoryTests {

    @Test("Cards round-trip and upsert by primary key")
    func cardRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        let due = Date(timeIntervalSince1970: 1_770_500_000)
        var card = SRSCard(
            kind: SRSCardKind.puzzle.rawValue,
            puzzleID: "00sHx",
            due: due,
            stability: 3.5,
            difficulty: 5.2,
            state: SRSState.learning.rawValue,
            reps: 2,
            lapses: 1
        )
        try database.srs.save(card)

        let loaded = try #require(try database.srs.card(id: card.id))
        #expect(loaded.cardKind == .puzzle)
        #expect(loaded.puzzleID == "00sHx")
        #expect(loaded.positionKey == nil)
        #expect(loaded.stability == 3.5)
        #expect(loaded.difficulty == 5.2)
        #expect(loaded.srsState == .learning)
        #expect(loaded.reps == 2)
        #expect(loaded.lapses == 1)
        #expect(loaded.lastReview == nil)
        expectSameInstant(loaded.due, due)

        card.reps = 3
        card.state = SRSState.review.rawValue
        try database.srs.save(card)
        let updated = try #require(try database.srs.card(id: card.id))
        #expect(updated.reps == 3)
        #expect(updated.srsState == .review)
        // Upsert, not insert: still exactly one row.
        #expect(try database.srs.dueCount(at: due.addingTimeInterval(1)) == 1)
    }

    @Test("Position-backed cards are found by their position key")
    func positionCards() throws {
        let database = try UserDatabase.inMemory()
        let card = SRSCard(
            kind: SRSCardKind.momentPosition.rawValue,
            positionKey: 0x0BAD_F00D_DEAD_BEEF,
            fen: "8/8/8/8/8/8/8/K6k w - - 0 1"
        )
        try database.srs.save(card)

        let byKey = try #require(try database.srs.card(positionKey: 0x0BAD_F00D_DEAD_BEEF))
        #expect(byKey.id == card.id)
        #expect(byKey.cardKind == .momentPosition)
        #expect(byKey.fen == "8/8/8/8/8/8/8/K6k w - - 0 1")
        #expect(try database.srs.card(positionKey: 1) == nil)

        let byPuzzle = try database.srs.card(puzzleID: "00sHx")
        #expect(byPuzzle == nil)
    }

    @Test("Due cards are filtered by date and ordered soonest first")
    func dueCards() throws {
        let database = try UserDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let overdue = SRSCard(kind: "puzzle", puzzleID: "a", due: now.addingTimeInterval(-86400))
        let dueNow = SRSCard(kind: "puzzle", puzzleID: "b", due: now.addingTimeInterval(-60))
        let future = SRSCard(kind: "puzzle", puzzleID: "c", due: now.addingTimeInterval(86400))
        for card in [future, overdue, dueNow] { try database.srs.save(card) }

        let due = try database.srs.due(at: now)
        #expect(due.map(\.id) == [overdue.id, dueNow.id])
        #expect(try database.srs.dueCount(at: now) == 2)
        #expect(try database.srs.dueCount(at: now.addingTimeInterval(2 * 86400)) == 3)
        #expect(try database.srs.due(at: now, limit: 1).map(\.id) == [overdue.id])
    }

    @Test("Recording a review writes the log and the new card state together")
    func recordReview() throws {
        let database = try UserDatabase.inMemory()
        var card = SRSCard(kind: "puzzle", puzzleID: "00sHx", state: SRSState.new.rawValue)
        try database.srs.save(card)

        let reviewedAt = Date(timeIntervalSince1970: 1_770_100_000)
        card.reps = 1
        card.stability = 2.4
        card.state = SRSState.review.rawValue
        card.lastReview = reviewedAt
        card.due = reviewedAt.addingTimeInterval(3 * 86400)

        try database.srs.recordReview(
            card: card,
            rating: .good,
            stateBefore: .new,
            elapsedDays: 0,
            scheduledDays: 3,
            durationMs: 5200,
            reviewedAt: reviewedAt
        )

        let logs = try database.srs.reviews(forCard: card.id)
        #expect(logs.count == 1)
        let log = try #require(logs.first)
        #expect(log.rating == ReviewRating.good.rawValue)
        #expect(log.stateBefore == "new")
        #expect(log.scheduledDays == 3)
        #expect(log.durationMs == 5200)
        expectSameInstant(log.reviewedAt, reviewedAt)

        let stored = try #require(try database.srs.card(id: card.id))
        #expect(stored.reps == 1)
        #expect(stored.srsState == .review)
        expectSameInstant(stored.lastReview, reviewedAt)
    }

    @Test("Out-of-range ratings clamp instead of being rejected")
    func ratingClamping() {
        #expect(ReviewRating(clamping: 0) == .again)
        #expect(ReviewRating(clamping: 1) == .again)
        #expect(ReviewRating(clamping: 4) == .easy)
        #expect(ReviewRating(clamping: 9) == .easy)
        #expect(ReviewRating.again.isLapse)
        #expect(!ReviewRating.good.isLapse)
    }
}

@Suite("Metrics repository")
struct MetricsRepositoryTests {

    @Test("Upsert inserts then updates the same (key, window) pair")
    func upsertRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        try database.metrics.upsert(
            key: "accuracy.tactics",
            window: "last20",
            value: 0.71,
            sampleCount: 20
        )
        let first = try #require(
            try database.metrics.metric(key: "accuracy.tactics", window: "last20")
        )
        #expect(first.value == 0.71)
        #expect(first.sampleCount == 20)

        try database.metrics.upsert(
            key: "accuracy.tactics",
            window: "last20",
            value: 0.78,
            sampleCount: 40
        )
        let second = try #require(
            try database.metrics.metric(key: "accuracy.tactics", window: "last20")
        )
        #expect(second.id == first.id, "Upsert must reuse the row, not create a second one")
        #expect(second.value == 0.78)
        #expect(second.sampleCount == 40)
        #expect(try database.metrics.all().count == 1)
    }

    @Test("Windows are independent within a key")
    func windowsAreIndependent() throws {
        let database = try UserDatabase.inMemory()
        try database.metrics.upsert(key: "accuracy.tactics", window: "last20", value: 0.7)
        try database.metrics.upsert(key: "accuracy.tactics", window: "allTime", value: 0.65)
        try database.metrics.upsert(key: "accuracy.endgame", window: "last20", value: 0.5)

        #expect(try database.metrics.metrics(key: "accuracy.tactics").count == 2)
        #expect(try database.metrics.metric(key: "accuracy.tactics", window: "allTime")?.value
            == 0.65)
        #expect(try database.metrics.metric(key: "accuracy.endgame", window: "last20")?.value
            == 0.5)
        #expect(try database.metrics.metric(key: "missing", window: "last20") == nil)
        #expect(try database.metrics.all().count == 3)
    }

    @Test("Duplicate rows from sync are merged on next write")
    func duplicatesConverge() throws {
        // No unique index exists on (key, window) by design, so two devices can
        // both create the pair. The repository must converge rather than fail.
        let database = try UserDatabase.inMemory()
        let older = SkillMetric(
            key: "accuracy.tactics",
            window: "last20",
            value: 0.5,
            sampleCount: 10,
            updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let newer = SkillMetric(
            key: "accuracy.tactics",
            window: "last20",
            value: 0.6,
            sampleCount: 20,
            updatedAt: Date(timeIntervalSince1970: 1_770_090_000)
        )
        try database.writer.write { db in
            try SkillMetric.insert { [older, newer] }.execute(db)
        }
        #expect(try database.metrics.all().count == 2)

        try database.metrics.upsert(
            key: "accuracy.tactics",
            window: "last20",
            value: 0.9,
            sampleCount: 30
        )

        let remaining = try database.metrics.all()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == newer.id, "The most recently updated row should survive")
        #expect(remaining.first?.value == 0.9)
    }
}

@Suite("Settings repository")
struct SettingsRepositoryTests {

    @Test("First access creates the singleton row with documented defaults")
    func defaults() throws {
        let database = try UserDatabase.inMemory()
        let settings = try database.settings.current()

        #expect(settings.id == AppSettings.singletonID)
        #expect(settings.claudeModel == "claude-opus-5")
        #expect(settings.effort == "medium")
        #expect(settings.boardTheme == "classic")
        #expect(settings.pieceSet == "cburnett")
        #expect(settings.soundOn)
        #expect(settings.hapticsOn)
        #expect(settings.userRating == 1100)
        #expect(settings.puzzleRating == 1000)
        #expect(settings.puzzleRD == 350)
        #expect(settings.currentRung == 1)
        #expect(settings.weeklyFocusHabit == nil)
    }

    @Test("Updates persist and never create a second settings row")
    func updateRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        _ = try database.settings.current()

        try database.settings.update {
            $0.boardTheme = "walnut"
            $0.userRating = 1284.5
            $0.soundOn = false
            $0.currentRung = 4
            $0.weeklyFocusHabit = "checkOpponentThreats"
        }

        let reloaded = try database.settings.current()
        #expect(reloaded.id == AppSettings.singletonID)
        #expect(reloaded.boardTheme == "walnut")
        #expect(reloaded.userRating == 1284.5)
        #expect(!reloaded.soundOn)
        #expect(reloaded.hapticsOn, "Untouched fields must be preserved")
        #expect(reloaded.currentRung == 4)
        #expect(reloaded.weeklyFocusHabit == "checkOpponentThreats")

        let rowCount = try database.writer.read { db in try AppSettings.all.fetchCount(db) }
        #expect(rowCount == 1)
    }

    @Test("Repeated access is idempotent")
    func repeatedAccess() throws {
        let database = try UserDatabase.inMemory()
        let first = try database.settings.current()
        let second = try database.settings.current()
        #expect(first.id == second.id)
        let rowCount = try database.writer.read { db in try AppSettings.all.fetchCount(db) }
        #expect(rowCount == 1)
    }
}

@Suite("Daily loop repository")
struct DailyLoopRepositoryTests {

    @Test("A day's loop is created on demand and then reused")
    func loopRoundTrip() throws {
        let database = try UserDatabase.inMemory()
        let created = try database.dailyLoop.loop(for: "2026-08-17")
        #expect(created.day == "2026-08-17")
        #expect(!created.gamePlayed)
        #expect(created.momentsReviewed == 0)
        #expect(created.puzzlesDone == 0)
        #expect(created.completedAt == nil)

        let again = try database.dailyLoop.loop(for: "2026-08-17")
        #expect(again.id == created.id)

        let rowCount = try database.writer.read { db in try DailyLoop.all.fetchCount(db) }
        #expect(rowCount == 1)
    }

    @Test("Progress updates persist")
    func updateProgress() throws {
        let database = try UserDatabase.inMemory()
        let completed = Date(timeIntervalSince1970: 1_770_200_000)
        try database.dailyLoop.update(day: "2026-08-17") {
            $0.gamePlayed = true
            $0.momentsReviewed = 3
            $0.puzzlesDone = 12
            $0.completedAt = completed
        }

        let loaded = try database.dailyLoop.loop(for: "2026-08-17")
        #expect(loaded.gamePlayed)
        #expect(loaded.momentsReviewed == 3)
        #expect(loaded.puzzlesDone == 12)
        expectSameInstant(loaded.completedAt, completed)
    }

    @Test("Duplicate days from sync merge to the best of each counter")
    func duplicateDaysMerge() throws {
        // Two devices can both open the app on the same morning; `day` is not
        // unique-indexed on purpose, so the merge happens here.
        let database = try UserDatabase.inMemory()
        let deviceA = DailyLoop(
            day: "2026-08-17",
            gamePlayed: true,
            momentsReviewed: 2,
            puzzlesDone: 5
        )
        let deviceB = DailyLoop(
            day: "2026-08-17",
            gamePlayed: false,
            momentsReviewed: 7,
            puzzlesDone: 3,
            completedAt: Date(timeIntervalSince1970: 1_770_200_000)
        )
        try database.writer.write { db in
            try DailyLoop.insert { [deviceA, deviceB] }.execute(db)
        }

        let merged = try database.dailyLoop.loop(for: "2026-08-17")
        #expect(merged.gamePlayed)
        #expect(merged.momentsReviewed == 7)
        #expect(merged.puzzlesDone == 5)
        #expect(merged.completedAt != nil)

        let rowCount = try database.writer.read { db in try DailyLoop.all.fetchCount(db) }
        #expect(rowCount == 1, "Duplicates must be collapsed")
    }

    @Test("Recent days come back newest first")
    func recentOrdering() throws {
        let database = try UserDatabase.inMemory()
        for day in ["2026-08-15", "2026-08-17", "2026-08-16"] {
            _ = try database.dailyLoop.loop(for: day)
        }
        #expect(try database.dailyLoop.recent().map(\.day)
            == ["2026-08-17", "2026-08-16", "2026-08-15"])
        #expect(try database.dailyLoop.recent(limit: 2).map(\.day)
            == ["2026-08-17", "2026-08-16"])
    }

    @Test("Day keys are zero-padded and locale-independent")
    func dayKeyFormatting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let key = DailyLoop.dayKey(for: date, calendar: calendar)
        #expect(key.count == 10)
        #expect(key.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)

        // Single-digit months and days must still be zero-padded, or string
        // ordering of `day` (which the streak view relies on) breaks.
        let components = DateComponents(year: 2026, month: 3, day: 7)
        let padded = try #require(calendar.date(from: components))
        #expect(DailyLoop.dayKey(for: padded, calendar: calendar) == "2026-03-07")
    }
}
