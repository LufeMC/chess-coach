import ChessKit
import Database
import EngineKit
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// The state machine behind a live game. Everything here runs against a scripted
// engine rather than Stockfish, because the real one is a process-global
// singleton with a private initialiser: there is no second engine to hand a
// second game, and a test that drove the shared one would be racing whichever
// suite happens to be running beside it.

// MARK: - Scripted engine

/// A stand-in for Stockfish that answers from a script.
///
/// `@MainActor` so a test can mutate the script between moves and so
/// ``duringSearch`` runs on the actor the session lives on — which is what makes
/// "the clock ran out while the opponent was thinking" a deterministic test
/// rather than a race with a timer.
@MainActor
private final class ScriptedEngine {

    var onSearch: (EnginePosition, SearchLimit) throws -> SearchResult = { _, _ in
        throw EngineError.notStarted
    }

    /// Run on every search, while the session is suspended waiting for it.
    var duringSearch: (() -> Void)?

    private(set) var leases: [EngineService.Client] = []

    private func search(_ position: EnginePosition, _ limit: SearchLimit) throws -> SearchResult {
        duringSearch?()
        return try onSearch(position, limit)
    }

    private func record(lease: EngineService.Client) {
        leases.append(lease)
    }

    var sessionEngine: SessionEngine {
        SessionEngine(
            deviceProfile: { .unknown },
            acquire: { client, _ in
                await self.record(lease: client)
                // A stand-in arbitrates nothing, so there is no lease to mint;
                // the session must stay drivable without one.
                return nil
            },
            release: { _, _ in },
            search: { position, limit, _ in try await self.search(position, limit) }
        )
    }
}

private func line(_ uci: String, cp: Int, rank: Int = 1) -> UCIInfo {
    UCIInfo(multipv: rank, depth: 12, score: .centipawns(cp), pv: [uci])
}

private func result(_ lines: [UCIInfo]) -> SearchResult {
    SearchResult(bestMove: lines.first?.bestMove, lines: lines)
}

/// The moves played so far, for a script that keys on them.
private func history(_ position: EnginePosition) -> [String] {
    switch position {
    case .startPosition(let moves): moves
    case .fen(_, let moves): moves
    }
}

@MainActor
private func makeSession(
    _ configuration: GameSession.Configuration,
    engine: ScriptedEngine
) -> GameSession {
    GameSession(
        configuration: configuration,
        engineService: EngineService(),
        persistence: nil,
        ladder: nil,
        engine: engine.sessionEngine,
        pause: { _ in }
    )
}

/// A game with no interruptions and no coach, for the tests that are about the
/// board and the clock.
private func plainConfiguration(
    userColor: Piece.Color = .white,
    baseSeconds: Int = 600
) -> GameSession.Configuration {
    GameSession.Configuration(
        userColor: userColor,
        opponentRating: 1200,
        baseSeconds: baseSeconds,
        incrementSeconds: 5,
        mode: "sparring",
        secondTryEnabled: false,
        guidedEnabled: false
    )
}

// MARK: - Second try

@Suite("Second-try retraction")
@MainActor
struct SecondTryRetractionTests {

    /// Scores a probe so `d2d4` looks fine and `e2e4` looks like a blunder.
    private func blunderScript(blunder: String) -> (EnginePosition, SearchLimit) throws -> SearchResult {
        { position, limit in
            if case .depthWithin = limit {
                // The opponent's reply. Legal after either candidate.
                return result([line("d7d5", cp: 10)])
            }
            let played = history(position).last
            // The refutation is parsed against the live board, so it has to be a
            // legal black move in the position the blunder produced.
            return result([line("e7e5", cp: played == blunder ? 600 : 40)])
        }
    }

    @Test("A retracted move leaves no trace, and the replacement is the only move")
    func retractionLeavesNoTrace() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        let played = await session.attemptUserMove(from: .e2, to: .e4)
        #expect(played)

        // The whole point: the move is off the board, off the list, and off the
        // clock. Left in `moves` it would reach the engine as history, the PGN,
        // the persisted plies and the ply numbering.
        guard case .secondTry(let state) = session.phase else {
            Issue.record("expected the blunder to be retracted")
            return
        }
        #expect(state.retractedMove == "e2e4")
        #expect(session.moves.isEmpty)
        #expect(session.board.position.sideToMove == .white)
        #expect(session.lastMove == nil)
        // The attempt cost its thinking time and earned no increment.
        #expect(session.userClockMs <= 600_000)
        #expect(session.userClockMs > 599_000)

        session.resumeAfterSecondTry()
        let replacement = await session.attemptUserMove(from: .d2, to: .d4)
        #expect(replacement)

        #expect(session.moves.map(\.san) == ["d4", "d5"])
        #expect(session.moves.map(\.ply) == [1, 2])
        #expect(session.moves.filter(\.byUser).count == 1)
        // One increment, not two. Two — 610_000 — is the retraction being paid
        // for as though it had been a move.
        #expect(session.userClockMs > 604_000)
        #expect(session.userClockMs <= 605_000)
    }

    @Test("Keeping the original move records it exactly once")
    func keepingTheOriginalRecordsItOnce() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)
        await session.keepOriginalMove()

        #expect(session.moves.map(\.san) == ["e4", "d5"])
        #expect(session.moves.filter(\.byUser).count == 1)
        #expect(session.moves.first?.ply == 1)
        // The kept move earns the increment it was denied when it was taken
        // back, and pays nothing for the deliberation in between.
        #expect(session.userClockMs > 604_000)
        #expect(session.userClockMs <= 605_000)
    }

    @Test("Resigning from a retraction saves a game the move never entered")
    func resigningAfterRetraction() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)
        session.resign()

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected the game to be over")
            return
        }
        #expect(outcome.result == "0-1")
        #expect(outcome.termination == GameTermination.resignation.rawValue)
        #expect(session.moves.isEmpty)
        #expect(!session.pgn(result: outcome.result).contains("e4"))
    }

    @Test("Retracting keeps the repetition history it was standing on")
    func retractionPreservesRepetitionCounts() async throws {
        // Knights out and back twice returns the starting position a third time,
        // which is a draw. Rebuilding the board from a position instead of
        // restoring it wipes the counts and the draw never arrives.
        let engine = ScriptedEngine()
        engine.onSearch = { position, limit in
            let moves = history(position)
            if case .depthWithin = limit {
                return result([line(moves.count % 4 == 1 ? "g8f6" : "f6g8", cp: 10)])
            }
            return result([line("g8f6", cp: moves.last == "b1c3" ? 600 : 40)])
        }
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .g1, to: .f3)
        _ = await session.attemptUserMove(from: .f3, to: .g1)

        // A blunder in the middle of the shuffle, taken back.
        _ = await session.attemptUserMove(from: .b1, to: .c3)
        guard case .secondTry = session.phase else {
            Issue.record("expected the blunder to be retracted")
            return
        }
        session.resumeAfterSecondTry()

        _ = await session.attemptUserMove(from: .g1, to: .f3)
        _ = await session.attemptUserMove(from: .f3, to: .g1)

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected a draw by repetition")
            return
        }
        #expect(outcome.result == "1/2-1/2")
        #expect(outcome.termination == GameTermination.repetition.rawValue)
        #expect(outcome.userWon == nil)
    }

    @Test("The hint ladder never skips and never resets")
    func hintLadder() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)

        session.requestHint()
        guard case .secondTry(let first) = session.phase else {
            Issue.record("expected the blunder to be retracted")
            return
        }
        #expect(first.hintLevel == 1)

        session.requestHint()
        session.requestHint()
        guard case .secondTry(let last) = session.phase else {
            Issue.record("expected to still be on the retry")
            return
        }
        #expect(last.hintLevel == GameSession.SecondTryState.assistedHintLevel)
    }

    @Test("A game where the refutation was shown cannot move the rating")
    func assistedRetryIsUnrated() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)
        session.requestHint()
        session.requestHint()
        session.resumeAfterSecondTry()
        session.resign()

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected the game to be over")
            return
        }
        let record = session.finishedGameRecord(outcome: outcome)
        #expect(record.usedAssistedRetry)
        // `EloLadder` refuses such a game outright: the result is partly the
        // engine's, and a rating that counts it measures the coach.
        #expect(record.ladderGame?.containedLevel2AssistedRetry == true)
    }
}

// MARK: - Clock

@Suite("Clock")
@MainActor
struct GameSessionClockTests {

    @Test("The user flags when their own clock runs out")
    func userFlags() async throws {
        let engine = ScriptedEngine()
        let session = makeSession(plainConfiguration(baseSeconds: 0), engine: engine)

        await session.start()
        #expect(session.checkClock())

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected a timeout")
            return
        }
        #expect(outcome.result == "0-1")
        #expect(outcome.termination == GameTermination.timeout.rawValue)
        #expect(outcome.userWon == false)

        // A move made after the flag never reaches the board.
        let played = await session.attemptUserMove(from: .e2, to: .e4)
        #expect(!played)
        #expect(session.moves.isEmpty)
    }

    @Test("The opponent flags while it is still thinking")
    func opponentFlags() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { _, _ in result([line("e2e4", cp: 10)]) }

        let session = makeSession(plainConfiguration(userColor: .black, baseSeconds: 0), engine: engine)
        // The clock is checked from a display timer in the real app; here it is
        // checked from inside the search, which is the same moment.
        engine.duringSearch = { [weak session] in
            _ = session?.checkClock()
        }

        await session.start()

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected a timeout")
            return
        }
        #expect(outcome.result == "0-1")
        #expect(outcome.termination == GameTermination.timeout.rawValue)
        #expect(outcome.userWon == true)
        // The opponent's move was abandoned rather than played out.
        #expect(session.moves.isEmpty)
    }
}

// MARK: - Terminal outcomes

@Suite("Terminal outcomes")
@MainActor
struct GameSessionOutcomeTests {

    @Test("Being mated ends the game against the user")
    func userIsMated() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { position, _ in
            // Fool's mate, from the mating side.
            result([line(history(position).count == 1 ? "e7e5" : "d8h4", cp: 10)])
        }
        let session = makeSession(plainConfiguration(), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .f2, to: .f3)
        _ = await session.attemptUserMove(from: .g2, to: .g4)

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected checkmate")
            return
        }
        #expect(outcome.result == "0-1")
        #expect(outcome.termination == GameTermination.checkmate.rawValue)
        #expect(outcome.userWon == false)
    }

    @Test("Delivering mate ends the game for the user")
    func userMates() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { position, _ in
            result([line(history(position).isEmpty ? "f2f3" : "g2g4", cp: 10)])
        }
        let session = makeSession(plainConfiguration(userColor: .black), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e7, to: .e5)
        _ = await session.attemptUserMove(from: .d8, to: .h4)

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected checkmate")
            return
        }
        #expect(outcome.result == "0-1")
        #expect(outcome.termination == GameTermination.checkmate.rawValue)
        #expect(outcome.userWon == true)
        // The mating move is on the record, and the game ended on it.
        #expect(session.moves.last?.san.hasPrefix("Qh4") == true)
    }

    @Test("A repeated position is a draw")
    func repetitionDraw() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { position, _ in
            result([line(history(position).count % 4 == 1 ? "g8f6" : "f6g8", cp: 10)])
        }
        let session = makeSession(plainConfiguration(), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .g1, to: .f3)
        _ = await session.attemptUserMove(from: .f3, to: .g1)
        _ = await session.attemptUserMove(from: .g1, to: .f3)
        _ = await session.attemptUserMove(from: .f3, to: .g1)

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected a draw by repetition")
            return
        }
        #expect(outcome.result == "1/2-1/2")
        #expect(outcome.userWon == nil)
    }
}

// MARK: - Guided mode

@Suite("Guided prompts in a game")
@MainActor
struct GameSessionGuidedTests {

    /// Five quiet moves each, so the sixth is the first move guided mode is
    /// allowed to interrupt.
    private static let userOpening: [(Square, Square)] = [
        (.a2, .a3), (.b2, .b3), (.c2, .c3), (.d2, .d3), (.e2, .e3)
    ]
    private static let opponentOpening = ["a7a6", "b7b6", "c7c6", "d7d6", "e7e6", "g8f6"]

    private func scriptedEngine() -> ScriptedEngine {
        let engine = ScriptedEngine()
        engine.onSearch = { position, limit in
            switch limit {
            case .depthWithin:
                let index = history(position).count / 2
                return result([line(Self.opponentOpening[min(index, Self.opponentOpening.count - 1)], cp: 10)])
            case .nodes(let nodes) where nodes < 60_000:
                // The null-move probe: what the opponent gets by moving twice.
                return result([line("d8d7", cp: 100)])
            default:
                // The criticality probe: two lines, a clear gap between them.
                return result([line("g1f3", cp: 200), line("b1c3", cp: -50, rank: 2)])
            }
        }
        return engine
    }

    private func playToPrompt(_ engine: ScriptedEngine) async -> GameSession {
        let session = makeSession(
            .guided(userColor: .white, opponentRating: 1200, focusHabit: .scanThreats),
            engine: engine
        )
        await session.start()
        for move in Self.userOpening {
            _ = await session.attemptUserMove(from: move.0, to: move.1)
        }
        return session
    }

    @Test("The pause arrives at the first position it is allowed to")
    func pausesOnceTheBudgetAllows() async throws {
        let engine = scriptedEngine()
        let session = await playToPrompt(engine)

        guard case .guidedPrompt(let state) = session.phase else {
            Issue.record("expected a guided pause")
            return
        }
        #expect(state.habitID == Habit.scanThreats.rawValue)
        #expect(state.ply == 11)
        #expect(!state.question.isEmpty)
        // Never in the opening: five moves each went by uninterrupted.
        #expect(session.moves.count == 10)
        // The probe runs under its own lease, never the play one.
        #expect(engine.leases.contains(.probe))
    }

    @Test("Answering with the move the position asked for is a hit")
    func answeringUnaidedIsGraded() async throws {
        let engine = scriptedEngine()
        let session = await playToPrompt(engine)

        session.resolveGuidedPrompt(revealed: false)
        guard case .userToMove = session.phase else {
            Issue.record("expected the board back")
            return
        }

        _ = await session.attemptUserMove(from: .g1, to: .f3)

        let answered = try #require(session.moves.first { $0.guidedPromptHabit != nil })
        #expect(answered.uci == "g1f3")
        #expect(answered.guidedPromptHabit == Habit.scanThreats.rawValue)
        #expect(answered.guidedPromptHit == true)

        session.resign()
        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected the game to be over")
            return
        }
        // The verdict has to survive all the way onto the row, because that is
        // the only place `guided.scanThreats.hitRate` is read back from.
        let record = session.finishedGameRecord(outcome: outcome)
        let rows = record.moveRows.filter { $0.guidedPromptHabit != nil }
        #expect(rows.count == 1)
        #expect(rows.first?.guidedPromptHabit == Habit.scanThreats.rawValue)
        #expect(rows.first?.guidedPromptHit == true)
    }

    @Test("Playing something else after answering is a miss")
    func answeringWithAnotherMoveIsAMiss() async throws {
        let engine = scriptedEngine()
        let session = await playToPrompt(engine)

        session.resolveGuidedPrompt(revealed: false)
        _ = await session.attemptUserMove(from: .h2, to: .h3)

        let answered = try #require(session.moves.first { $0.guidedPromptHabit != nil })
        #expect(answered.guidedPromptHit == false)
    }

    @Test("Being shown the method records the pause but no verdict")
    func revealedPromptHasNoVerdict() async throws {
        let engine = scriptedEngine()
        let session = await playToPrompt(engine)

        session.resolveGuidedPrompt(revealed: true)
        _ = await session.attemptUserMove(from: .g1, to: .f3)

        let answered = try #require(session.moves.first { $0.guidedPromptHabit != nil })
        // Counting this as a miss would make the escape hatch a punishment, and
        // counting it as a hit would measure the coach. `GameMovePromptLog`
        // drops a habit with no verdict from the hit rate entirely.
        #expect(answered.guidedPromptHabit == Habit.scanThreats.rawValue)
        #expect(answered.guidedPromptHit == nil)
    }

    @Test("Sparring never pauses, whatever the position looks like")
    func sparringNeverPauses() async throws {
        let engine = scriptedEngine()
        let session = makeSession(plainConfiguration(), engine: engine)
        await session.start()
        for move in Self.userOpening {
            _ = await session.attemptUserMove(from: move.0, to: move.1)
        }

        guard case .userToMove = session.phase else {
            Issue.record("expected an uninterrupted game")
            return
        }
        #expect(session.moves.allSatisfy { $0.guidedPromptHabit == nil })
    }
}

// MARK: - Ladder rating

@Suite("Ladder rating")
struct LadderRatingTests {

    private func record(
        weight: LadderGameMode?,
        result: String = GameResult.whiteWins.rawValue,
        assisted: Bool = false
    ) -> FinishedGameRecord {
        FinishedGameRecord(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            mode: "sparring",
            userColor: .white,
            opponentRating: 1_200,
            result: result,
            termination: GameTermination.checkmate.rawValue,
            pgn: "",
            moves: [],
            opponentParams: .init(
                opponentRating: 1_200,
                baseSeconds: 600,
                incrementSeconds: 5,
                secondTryEnabled: true,
                guidedEnabled: false
            ),
            isRated: false,
            ratingWeight: weight,
            usedAssistedRetry: assisted
        )
    }

    private func makeWriter(rating: Double = 1_100) -> (LadderRatingWriter, InMemoryAppSettingsStore) {
        let settings = InMemoryAppSettingsStore(settings: AppSettings(userRating: rating))
        return (LadderRatingWriter(settings: settings, metrics: InMemoryMetricStore()), settings)
    }

    @Test("A won sparring game moves the rating up")
    func winMovesTheRating() async throws {
        let (writer, settings) = makeWriter()
        let updated = try await writer.apply(record(weight: .sparring))

        let stored = try settings.current().userRating
        #expect(updated == stored)
        #expect(stored > 1_100)
    }

    @Test("A game with the coach in it counts half")
    func guidedCountsHalf() async throws {
        let (plain, _) = makeWriter()
        let (coached, _) = makeWriter()

        let full = try #require(try await plain.apply(record(weight: .sparring)))
        let half = try #require(try await coached.apply(record(weight: .guided)))

        #expect((full - 1_100) > 0)
        #expect(abs((full - 1_100) / 2 - (half - 1_100)) < 0.000_1)
    }

    @Test("Calibration games do not count twice")
    func calibrationIsExcluded() async throws {
        let (writer, settings) = makeWriter()
        // `CalibrationModel` has already written the rating these games produced.
        let applied = try await writer.apply(record(weight: nil))
        let stored = try settings.current().userRating

        #expect(applied == nil)
        #expect(stored == 1_100)
    }

    @Test("A game the coach played part of is unrated, counter included")
    func assistedRetryIsUnrated() async throws {
        let (writer, settings) = makeWriter()
        let applied = try await writer.apply(record(weight: .sparring, assisted: true))
        let stored = try settings.current().userRating

        #expect(applied == nil)
        #expect(stored == 1_100)
    }

    @Test("A loss moves the rating down and a draw sits between them")
    func resultsAreOrdered() async throws {
        let (winner, _) = makeWriter()
        let (drawer, _) = makeWriter()
        let (loser, _) = makeWriter()

        let win = try #require(try await winner.apply(record(weight: .sparring)))
        let draw = try #require(try await drawer.apply(record(weight: .sparring, result: GameResult.draw.rawValue)))
        let loss = try #require(try await loser.apply(record(weight: .sparring, result: GameResult.blackWins.rawValue)))

        #expect(loss < draw)
        #expect(draw < win)
    }

    @Test("Sparring feeds the ladder at half weight; calibration not at all")
    @MainActor
    func weightComesFromTheConfiguration() async throws {
        let engine = ScriptedEngine()
        let sparring = makeSession(.sparring(userColor: .white, opponentRating: 1_200), engine: engine)
        let calibration = makeSession(.calibration(userColor: .white, opponentRating: 1_200), engine: engine)
        let outcome = GameSession.Outcome(
            result: "1-0",
            termination: GameTermination.resignation.rawValue,
            userWon: true
        )

        // Take-backs overstate strength, so sparring comes in at the guided
        // tier — but it does come in, which is the difference between a rating
        // that moves and one frozen at the calibration estimate.
        #expect(sparring.finishedGameRecord(outcome: outcome).ratingWeight == .guided)
        #expect(!sparring.finishedGameRecord(outcome: outcome).isRated)
        #expect(calibration.finishedGameRecord(outcome: outcome).ratingWeight == nil)
        #expect(calibration.finishedGameRecord(outcome: outcome).isRated)
    }
}

// MARK: - Null-move FEN

@Suite("Null-move probe position")
struct NullMoveFENTests {

    @Test("Passing hands the move over and drops the en-passant square")
    func passing() throws {
        let fen = "rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3"
        let flipped = try #require(GameSession.nullMoveFEN(fen))
        // Leaving `f6` in describes a capture only the player who just passed
        // could make, and the engine would search a position that cannot occur.
        #expect(flipped == "rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3")
    }

    @Test("Black to move flips the other way")
    func blackToMove() throws {
        let flipped = try #require(GameSession.nullMoveFEN(Position.standard.fen))
        #expect(flipped.split(separator: " ")[1] == "b")
    }

    @Test("Nonsense is rejected rather than guessed at")
    func rejectsNonsense() {
        #expect(GameSession.nullMoveFEN("not a fen") == nil)
        #expect(GameSession.nullMoveFEN("8/8/8/8/8/8/8/8 x - - 0 1") == nil)
    }
}

// MARK: - The opponent's search is bounded by its own clock

/// Without a bound the opponent can lose on time from search cost alone, which
/// is not a game the user won and must not be fed to the rating ladder as one.
@Suite("Opponent move budget")
struct OpponentMoveBudgetTests {

    @Test("A full clock is capped, not spent proportionally")
    func fullClockIsCapped() {
        // 10 minutes. A twentieth would be 30s, which is absurd for one move.
        #expect(GameSession.opponentMoveBudgetMs(clockRemainingMs: 600_000) == 8_000)
    }

    @Test("The budget shrinks with the clock")
    func budgetTracksTheClock() {
        let full = GameSession.opponentMoveBudgetMs(clockRemainingMs: 600_000)
        let low = GameSession.opponentMoveBudgetMs(clockRemainingMs: 60_000)
        let critical = GameSession.opponentMoveBudgetMs(clockRemainingMs: 12_000)
        #expect(low < full)
        #expect(critical < low)
    }

    @Test("The budget never exceeds a twentieth of what is left, once under the cap")
    func budgetIsAShareOfTheClock() {
        for clock in [20_000, 60_000, 100_000, 159_000] {
            let budget = GameSession.opponentMoveBudgetMs(clockRemainingMs: clock)
            #expect(budget <= max(500, clock / 20))
            // And never so large that one move can flag the opponent outright.
            #expect(budget < clock)
        }
    }

    @Test("A nearly-dead clock still yields a usable floor")
    func floorHoldsAtTheEnd() {
        // Below the floor the opponent is simply out of time; the search does
        // not get shortened to something that cannot return a move.
        #expect(GameSession.opponentMoveBudgetMs(clockRemainingMs: 300) == 500)
        #expect(GameSession.opponentMoveBudgetMs(clockRemainingMs: 0) == 500)
    }

    @Test("The limit carries both the depth and the ceiling")
    func limitCarriesBoth() {
        let limit = SearchLimit.depthWithin(depth: 18, milliseconds: 8_000)
        guard case .depthWithin(let depth, let ms) = limit else {
            Issue.record("wrong case")
            return
        }
        #expect(depth == 18)
        #expect(ms == 8_000)
    }
}

// MARK: - Pawn promotion

/// A pawn reaching the last rank is not a corner case in a training app whose
/// own curriculum teaches K+P endgames. `Board.move(pieceAt:to:)` does not
/// promote — it parks the board in `.promotion` and returns *before* checking
/// for checkmate or draw — so every move path has to finish the job itself.
@Suite("Promotion in a played game")
@MainActor
struct PromotionTests {

    /// Five White pawn moves from the start position ending in a promotion,
    /// with legal Black replies in between.
    ///
    /// 1. h4 g5 2. hxg5 h6 3. gxh6 a6 4. h7 a5 5. hxg8=Q
    ///
    /// The capture on g8 rather than a push to h8 is deliberate: Black's rook
    /// never leaves h8, so the only way through is to take the knight — which
    /// also makes the promotion a capture, the case where a move carries both a
    /// captured piece and a promoted one.
    static let blackReplies = ["g7g5", "h7h6", "a7a6", "a6a5"]
    static let whiteMoves = [("h2", "h4"), ("h4", "g5"), ("g5", "h6"), ("h6", "h7"), ("h7", "g8")]

    private func promotingSession() -> (GameSession, ScriptedEngine) {
        let engine = ScriptedEngine()
        var reply = 0
        engine.onSearch = { _, _ in
            defer { reply += 1 }
            let move = reply < Self.blackReplies.count ? Self.blackReplies[reply] : "h5f6"
            return result([line(move, cp: 0)])
        }
        return (makeSession(plainConfiguration(userColor: .white), engine: engine), engine)
    }

    private func playToPromotion(_ session: GameSession) async {
        await session.start()
        for (from, to) in Self.whiteMoves {
            _ = await session.attemptUserMove(from: Square(from), to: Square(to))
        }
    }

    @Test("The pawn actually becomes a piece")
    func pawnIsPromoted() async throws {
        let (session, _) = promotingSession()
        await playToPromotion(session)

        let piece = try #require(session.board.position.piece(at: Square("g8")))
        #expect(piece.kind != .pawn, "the pawn was never promoted — the board is stuck mid-promotion")
        #expect(piece.color == .white)
        // Default when the caller names no piece, matching `LineReplay`.
        #expect(piece.kind == .queen)
    }

    @Test("The board is not left in the incomplete promotion state")
    func boardIsNotFrozen() async throws {
        let (session, _) = promotingSession()
        await playToPromotion(session)

        // `.promotion` blocks checkmate and draw detection entirely, so a game
        // left here can never end.
        if case .promotion = session.board.state {
            Issue.record("board is parked in .promotion; checkmate and draw detection are dead")
        }
    }

    @Test("Underpromotion is reachable, not silently queened")
    func underpromotionIsHonoured() async throws {
        let engine = ScriptedEngine()
        var reply = 0
        engine.onSearch = { _, _ in
            defer { reply += 1 }
            let move = reply < Self.blackReplies.count ? Self.blackReplies[reply] : "a5a4"
            return result([line(move, cp: 0)])
        }
        let session = makeSession(plainConfiguration(userColor: .white), engine: engine)

        await session.start()
        for (index, step) in Self.whiteMoves.enumerated() {
            let last = index == Self.whiteMoves.count - 1
            _ = await session.attemptUserMove(
                from: Square(step.0),
                to: Square(step.1),
                promoting: last ? .knight : .queen
            )
        }

        let piece = try #require(session.board.position.piece(at: Square("g8")))
        #expect(piece.kind == .knight, "the chosen piece was discarded")
        let promotion = try #require(session.moves.last(where: { $0.byUser }))
        #expect(promotion.uci == "h7g8n")
    }

    @Test("A promoting move is recognised before it is played")
    func promotionIsDetectedUpFront() async {
        let (session, _) = promotingSession()
        await session.start()
        // The board has to know to ask *before* applying the move, or the user
        // never gets the choice.
        for (index, step) in Self.whiteMoves.enumerated() {
            let expected = index == Self.whiteMoves.count - 1
            #expect(
                session.isPromotion(from: Square(step.0), to: Square(step.1)) == expected,
                "step \(index) misjudged"
            )
            _ = await session.attemptUserMove(from: Square(step.0), to: Square(step.1))
        }
    }

    @Test("The stored UCI carries the promotion suffix")
    func uciCarriesTheSuffix() async throws {
        let (session, _) = promotingSession()
        await playToPromotion(session)

        let promotion = try #require(session.moves.last(where: { $0.byUser }))
        // Without the suffix this is not a legal UCI move. It is replayed into
        // `position startpos moves …` for every later engine search, and it is
        // what the analysis pass reads back.
        #expect(
            promotion.uci == "h7g8q",
            "stored \(promotion.uci) — a pawn move to the last rank without a promotion piece is illegal UCI"
        )
        // SAN is written from the same move. `SANParser` only emits the `=Q`
        // when `promotedPiece` is set, and the archival PGN is built from this
        // string — so a promotion recorded before it is completed produces a
        // PGN that will not replay.
        #expect(promotion.san.contains("=Q"), "stored SAN \(promotion.san) has no promotion")
    }

    @Test("The move list the engine is sent stays legal")
    func engineHistoryStaysLegal() async throws {
        let (session, _) = promotingSession()
        await playToPromotion(session)

        // The exact string list handed to Stockfish. Replaying it must land on
        // the same position the session is showing, or the two have diverged
        // and every later search is answering about a different game.
        let replay = AnalysisPipeline.replay(uci: session.moves.map(\.uci))
        #expect(replay.moves.count == session.moves.count, "the recorded game does not replay")
        #expect(
            replay.positions.last?.fen == session.board.position.fen,
            "replayed position diverges from the live board"
        )
    }
}
