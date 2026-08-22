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
    /// The same window, told which search it is looking at.
    ///
    /// Separate from ``duringSearch`` rather than a parameter on it, because
    /// the limit is what names the caller: the opponent's own move is the only
    /// `.depthWithin` search a session makes, and both coaching probes are
    /// `.nodes`.
    var duringSearchOfLimit: ((SearchLimit) -> Void)?
    /// Run as each lease is handed out, before the search that follows it.
    ///
    /// The window between the two is where the opponent's clock starts, and
    /// nothing else can observe it.
    var duringAcquire: ((EngineService.Client) -> Void)?

    private(set) var leases: [EngineService.Client] = []

    private func search(_ position: EnginePosition, _ limit: SearchLimit) throws -> SearchResult {
        duringSearch?()
        duringSearchOfLimit?(limit)
        return try onSearch(position, limit)
    }

    private func record(lease: EngineService.Client) {
        leases.append(lease)
        duringAcquire?(lease)
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
        // Expressed against the configured control rather than literals: this
        // is a test about how many increments a retraction pays, and changing
        // the time control should not be able to falsify it.
        let control = GameSession.Configuration.sparring(userColor: .white, opponentRating: 1200)
        let base = control.baseSeconds * 1000
        let increment = control.incrementSeconds * 1000

        // The attempt cost its thinking time and earned no increment.
        #expect(session.userClockMs <= base)
        #expect(session.userClockMs > base - 1_000)

        session.resumeAfterSecondTry()
        let replacement = await session.attemptUserMove(from: .d2, to: .d4)
        #expect(replacement)

        #expect(session.moves.map(\.san) == ["d4", "d5"])
        #expect(session.moves.map(\.ply) == [1, 2])
        #expect(session.moves.filter(\.byUser).count == 1)
        // One increment, not two. Two would be the retraction being paid for as
        // though it had been a move.
        #expect(session.userClockMs > base + increment - 1_000)
        #expect(session.userClockMs <= base + increment)
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
        // Expressed against the configured control rather than literals: this
        // is a test about how many increments a retraction pays, and changing
        // the time control should not be able to falsify it.
        let control = GameSession.Configuration.sparring(userColor: .white, opponentRating: 1200)
        let base = control.baseSeconds * 1000
        let increment = control.incrementSeconds * 1000

        // The kept move earns the increment it was denied when it was taken
        // back, and pays nothing for the deliberation in between.
        #expect(session.userClockMs > base + increment - 1_000)
        #expect(session.userClockMs <= base + increment)
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

    /// The probe is two engine searches long, and the user's clock kept running
    /// against the move's own start date for the whole of it — so the pill
    /// dipped by the think time and sprang back when the probe returned, and a
    /// long think followed by a perfectly legal move could flag the user in the
    /// gap.
    @Test("The blunder probe does not charge the move a second time")
    func probeDoesNotDoubleChargeTheClock() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        let moveStart = session.moveStartedAt

        var duringProbe: Date?
        engine.duringSearch = { [weak session] in
            guard let session, session.moves.count == 1 else { return }
            duringProbe = session.moveStartedAt
        }

        _ = await session.attemptUserMove(from: .e2, to: .e4)

        // The move has been paid for by the time the probe runs, so the instant
        // the clock is measured against has to have moved on with it.
        let observed = try #require(duringProbe)
        #expect(observed > moveStart)
    }

    @Test("A game that ends during the probe stays ended")
    func finishingDuringTheProbeStands() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)
        await session.start()

        // Resigning from the options sheet while the coach is deciding whether
        // to interrupt. `finish` has by then saved the record and moved the
        // ladder, and the retraction below used to overwrite `.finished` and
        // carry on — so the game ended a second time, under the same id.
        engine.duringSearch = { [weak session] in session?.resign() }

        _ = await session.attemptUserMove(from: .e2, to: .e4)

        #expect(session.phase.isFinishedPhase)
    }

    @Test("In the last minute the blunder stands, and the start prompt said so")
    func secondTryStandsDownInTimeTrouble() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        // A minute on the clock is the floor exactly, so the take-back is off
        // from the first move of this game.
        let configuration = GameSession.Configuration(
            userColor: .white,
            opponentRating: 1200,
            baseSeconds: GameSession.secondTryMinClockMs / 1000,
            incrementSeconds: 0,
            mode: "sparring",
            secondTryEnabled: true,
            guidedEnabled: false
        )
        let session = makeSession(configuration, engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)

        if case .secondTry = session.phase {
            Issue.record("the take-back fired below its clock floor")
        }
        #expect(session.moves.first?.uci == "e2e4")

        // The rule is defensible; discovering it mid-blunder is not. The start
        // prompt's promise carries the boundary, so this is the sentence that
        // has to keep naming it.
        #expect(GameSession.secondTryPromise.contains("last minute"))
        #expect(GameSession.secondTryMinClockMs == 60_000)
    }

    @Test("Reading the coaching card is not on anybody's clock")
    func secondTryIsNotCharged() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = blunderScript(blunder: "e2e4")
        let session = makeSession(.sparring(userColor: .white, opponentRating: 1200), engine: engine)

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)

        guard case .secondTry = session.phase else {
            Issue.record("expected the blunder to be retracted")
            return
        }
        // Nothing charges this deliberation — `keepOriginalMove` pays only what
        // the first attempt cost and `resumeAfterSecondTry` restarts the clock —
        // so ending the game on it was the worst of both readings: a pause that
        // cannot cost you a second but could cost you the game.
        #expect(!session.checkClock())
        guard case .secondTry = session.phase else {
            Issue.record("the coaching pause flagged the user")
            return
        }
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

    /// The other opponent flag: the one the search itself notices, when the turn
    /// cost more than was left rather than the display timer catching it first.
    @Test("A move made after the opponent's flag never reaches the board")
    func opponentFlagsInsideItsOwnTurn() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { _, _ in result([line("e2e4", cp: 10)]) }

        let session = makeSession(plainConfiguration(userColor: .black, baseSeconds: 0), engine: engine)
        await session.start()

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected a timeout")
            return
        }
        #expect(outcome.termination == GameTermination.timeout.rawValue)
        // The flag is now read before the move is applied, exactly as it is on
        // the user's side. It used to be read after, which left the abandoned
        // move sitting on the board — and handed that board to the mating-
        // material test that decides whether the flag is a loss or a draw.
        #expect(session.moves.isEmpty)
        #expect(session.board.position.piece(at: .e2) != nil)
        #expect(session.lastMove == nil)
    }
}

// MARK: - Draw offers

/// Recognising a dead ending and agreeing it is endgame technique, and the only
/// alternatives were shuffling to a repetition or resigning a drawn game.
///
/// The guards are what these pin, because the failure that costs something is
/// one-sided: a decline costs a few more moves, an acceptance in a position the
/// user was winning costs half a point and a rating move they had earned.
@Suite("Draw offers")
@MainActor
struct GameSessionDrawOfferTests {

    @Test("A draw can only be offered on your own move")
    func onlyOnYourOwnMove() async throws {
        let engine = ScriptedEngine()
        let session = makeSession(plainConfiguration(), engine: engine)

        // Before the game starts, and after it has ended, there is nothing to
        // offer and nobody to answer.
        #expect(!session.canOfferDraw)
        #expect(!session.offerDraw())

        await session.start()
        #expect(session.canOfferDraw)

        session.resign()
        #expect(!session.canOfferDraw)
        #expect(!session.offerDraw())
    }

    @Test("The opponent does not agree a draw in the opening")
    func notInTheOpening() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { _, _ in result([line("e7e5", cp: 0)]) }
        let session = makeSession(plainConfiguration(), engine: engine)
        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)

        // Dead level by the opponent's own reading — `cp: 0` — and still no. A
        // level opening is a game, not a drawn ending, and the offer is only
        // ever entertained in an endgame.
        #expect(session.canOfferDraw)
        #expect(!session.offerDraw())
        if case .finished = session.phase {
            Issue.record("the opening was agreed drawn")
        }
    }

    @Test("An opponent that has not looked at the position cannot agree to it")
    func notBeforeTheOpponentHasEvaluated() async throws {
        let engine = ScriptedEngine()
        let session = makeSession(plainConfiguration(), engine: engine)
        await session.start()

        // Belt and braces with the endgame guard above, and the one worth
        // stating: `currentEvaluation` starts at 50, which reads as "dead level"
        // and means "nobody has looked yet". Confusing the two is exactly how a
        // won position would get given away.
        #expect(!session.offerDraw())
        if case .finished = session.phase {
            Issue.record("a game nobody has evaluated was agreed drawn")
        }
    }
}

// MARK: - Backgrounding

/// Time spent off screen belongs to nobody.
///
/// The bug these pin was invisible and non-deterministic: iOS suspends the
/// process but not `Date()`, so a game left open in the background was charging
/// its clock the whole time — unless iOS happened to reclaim the process, in
/// which case nothing happened at all. It mattered most during calibration,
/// where a phantom flag corrupts the rating the whole curriculum is seeded from.
@Suite("Backgrounding")
@MainActor
struct GameSessionBackgroundingTests {

    /// The arithmetic on its own, where the dates can be stated exactly.
    @Test("The away interval is exactly what gets forgiven")
    func awayIntervalIsForgiven() {
        let start = Date(timeIntervalSince1970: 1_000)
        // Thought for 30s, went away for an hour, came back.
        let left = start.addingTimeInterval(30)
        let returned = left.addingTimeInterval(3600)

        let moved = GameSession.moveStart(
            forgivingAwayTime: start,
            leftAt: left,
            returnedAt: returned
        )

        // The 30s of real thinking survives; the hour does not.
        #expect(returned.timeIntervalSince(moved) == 30)
    }

    @Test("A move that started inside the gap is never dated in the future")
    func clampedToTheReturnInstant() {
        let left = Date(timeIntervalSince1970: 1_000)
        let returned = left.addingTimeInterval(3600)
        // The opponent's reply landed just after the app went away.
        let start = left.addingTimeInterval(1)

        let moved = GameSession.moveStart(
            forgivingAwayTime: start,
            leftAt: left,
            returnedAt: returned
        )

        #expect(moved == returned, "a clock that counts up is worse than one that counts wrong")
        #expect(moved <= returned)
    }

    @Test("An hour in the background does not flag the player")
    func awayTimeIsNotCharged() async throws {
        let engine = ScriptedEngine()
        // A ten-minute game, exactly like a calibration game.
        let session = makeSession(plainConfiguration(baseSeconds: 600), engine: engine)
        await session.start()

        // Away for an hour — far longer than the whole clock — and back now.
        // Both instants are in the past, which is the only shape the real
        // notifications can deliver.
        session.suspendClock(at: Date().addingTimeInterval(-3600))
        #expect(session.resumeClock(at: Date()))

        #expect(!session.checkClock(), "an hour away must not spend a ten-minute clock")
        if case .finished = session.phase {
            Issue.record("the game was ended by time the app spent suspended")
        }
        // And the game is still playable, which is the whole point.
        #expect(await session.attemptUserMove(from: .e2, to: .e4))
    }

    @Test("A flag already earned survives the round trip")
    func foregroundTimeIsStillCharged() async throws {
        let engine = ScriptedEngine()
        let session = makeSession(plainConfiguration(baseSeconds: 0), engine: engine)
        await session.start()

        // Backgrounding must not become a way to escape a clock that had
        // already run out while the app was on screen.
        session.suspendClock(at: Date().addingTimeInterval(-60))
        session.resumeClock(at: Date())

        #expect(session.checkClock())
        #expect(session.phase.isFinishedPhase)
    }

    @Test("The clock never flags while the app is away")
    func suspendedClockDoesNotFlag() async throws {
        let engine = ScriptedEngine()
        let session = makeSession(plainConfiguration(baseSeconds: 0), engine: engine)
        await session.start()

        session.suspendClock()
        // A zero clock would flag instantly on any other tick.
        #expect(!session.checkClock())
        if case .finished = session.phase {
            Issue.record("a suspended session flagged itself")
        }
    }

    /// A foreground notification can arrive without a matching background one —
    /// the app launching straight into the foreground is the ordinary case.
    @Test("Resuming without a suspend forgives nothing")
    func resumeWithoutSuspendIsInert() async throws {
        let engine = ScriptedEngine()
        let session = makeSession(plainConfiguration(baseSeconds: 600), engine: engine)
        await session.start()

        #expect(!session.resumeClock())
        #expect(!session.resumeClock(at: Date()))
    }

    /// The opponent's side of the same rule.
    ///
    /// Their turn used to be billed against a local `Date()` that `resumeClock`
    /// could not reach, so every second the app spent suspended during their
    /// move was charged to them — and the humanized thinking pause sits inside
    /// that window, which is why the bug needed no engine to reproduce. Once the
    /// away time passed their remaining clock they were flagged and the user was
    /// handed a win the Elo ladder then paid out.
    @Test("The opponent's turn starts from the clock the background forgives")
    func opponentIsBilledFromMoveStart() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { _, _ in result([line("e2e4", cp: 10)]) }

        let session = makeSession(plainConfiguration(userColor: .black, baseSeconds: 600), engine: engine)

        var atAcquire: Date?
        var atSearch: Date?
        engine.duringAcquire = { [weak session] _ in atAcquire = session?.moveStartedAt }
        engine.duringSearch = { [weak session] in atSearch = session?.moveStartedAt }

        await session.start()

        // The opponent's clock now starts in the window between taking the
        // engine lease and searching with it, which is what makes it the same
        // instant `resumeClock` pushes forward — a local `Date()` inside
        // `runOpponentMove` was unreachable from there, so every second the app
        // spent suspended during their move was billed to them.
        //
        // Taken after the lease and not before it, for the reason it always
        // was: waiting for the engine is the app's delay, not the opponent's.
        let acquired = try #require(atAcquire)
        let searched = try #require(atSearch)
        #expect(searched > acquired)
        #expect(session.moves.count == 1)
    }

    /// Suspending tears the engine lease down, so a search in flight comes back
    /// refused. Retrying that is two bugs at once.
    @Test("A search abandoned to the background costs no retries and no game")
    func backgroundFailureDoesNotAbandonTheGame() async throws {
        let engine = ScriptedEngine()
        var searches = 0
        engine.onSearch = { _, _ in
            searches += 1
            throw EngineError.notStarted
        }

        let session = makeSession(plainConfiguration(userColor: .black, baseSeconds: 600), engine: engine)
        engine.duringSearch = { [weak session] in
            // The app goes off screen while the opponent is thinking.
            session?.suspendClock(at: Date().addingTimeInterval(-1))
        }

        await session.start()

        // One failure, not four: the strikes exist for an engine that will not
        // answer, and this one was never asked. Burning them here abandoned a
        // live game as a draw for the crime of being backgrounded.
        #expect(searches == 1)
        if case .finished = session.phase {
            Issue.record("backgrounding ended the game")
        }
    }

    @Test("Nothing is asked of the engine while the app is off screen")
    func opponentDoesNotSearchInTheBackground() async throws {
        let engine = ScriptedEngine()
        var searches = 0
        engine.onSearch = { _, _ in
            searches += 1
            return result([line("e2e4", cp: 10)])
        }

        let session = makeSession(plainConfiguration(userColor: .black, baseSeconds: 600), engine: engine)
        session.suspendClock(at: Date().addingTimeInterval(-1))
        await session.start()

        // Starting Stockfish here is exactly what suspending the engine exists
        // to prevent, and the turn is owed rather than lost.
        #expect(searches == 0)
        #expect(session.moves.isEmpty)

        session.resumeClock(at: Date())
        // The replay is spawned rather than awaited, so let the runtime drain
        // it. Bounded, and it exits the moment the move lands.
        for _ in 0..<200 where session.moves.isEmpty {
            await Task.yield()
        }
        #expect(session.moves.count == 1)
    }
}

private extension GameSession.Phase {
    var isFinishedPhase: Bool {
        if case .finished = self { return true }
        return false
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

    /// Five moves each, so the sixth is the first move guided mode is allowed to
    /// interrupt — and a fifth pair that leaves a real threat on the board.
    ///
    /// The last two moves are not decoration. The gate now asks whether the
    /// opponent's free move would be *forcing*, because the null-move number on
    /// its own cannot tell a threat from zugzwang or from the user's own tactic.
    /// So `Bf4` walks the bishop out, `e5` attacks it, and the null-move probe
    /// below answers with the capture that is genuinely available in that
    /// position rather than with a quiet move the fixture merely asserts is
    /// dangerous.
    private static let userOpening: [(Square, Square)] = [
        (.a2, .a3), (.b2, .b3), (.c2, .c3), (.d2, .d4), (.c1, .f4)
    ]
    private static let opponentOpening = ["a7a6", "b7b6", "c7c6", "d7d6", "e7e5", "g8f6"]

    private func scriptedEngine() -> ScriptedEngine {
        let engine = ScriptedEngine()
        engine.onSearch = { position, limit in
            switch limit {
            case .depthWithin:
                let index = history(position).count / 2
                return result([line(Self.opponentOpening[min(index, Self.opponentOpening.count - 1)], cp: 10)])
            case .nodes(let nodes) where nodes < 60_000:
                // The null-move probe: what the opponent gets by moving twice.
                // A capture, and a legal one — the pawn on e5 takes the bishop.
                return result([line("e5f4", cp: 100)])
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

    @Test("The opponent stops thinking the instant their move lands")
    func theProbeRunsUnderItsOwnPhase() async throws {
        let engine = scriptedEngine()
        var target: GameSession?
        var probePhases: [GameSession.Phase] = []
        engine.duringSearchOfLimit = { limit in
            // Only the coach's probes. The opponent's own search is the one
            // that legitimately reads `.opponentThinking`.
            if case .nodes = limit, let target { probePhases.append(target.phase) }
        }

        let session = makeSession(
            .guided(userColor: .white, opponentRating: 1200, focusHabit: .scanThreats),
            engine: engine
        )
        target = session
        await session.start()
        for move in Self.userOpening {
            _ = await session.attemptUserMove(from: move.0, to: move.1)
        }

        // The two probes used to run with the phase still `.opponentThinking`,
        // so for a few hundred milliseconds after the opponent's piece had
        // visibly moved their clock kept ticking and their spoken line still
        // said they were thinking — which reads as lag, or as a second move.
        #expect(!probePhases.isEmpty)
        #expect(probePhases.allSatisfy { $0 == .preparing })
    }

    @Test("Nobody's clock runs while the coach is deciding")
    func preparingIsOffBothClocks() async throws {
        let engine = scriptedEngine()
        var target: GameSession?
        var flagged: [Bool] = []
        engine.duringSearchOfLimit = { limit in
            if case .nodes = limit, let target { flagged.append(target.checkClock()) }
        }

        let session = makeSession(
            .guided(userColor: .white, opponentRating: 1200, focusHabit: .scanThreats),
            engine: engine
        )
        target = session
        await session.start()
        for move in Self.userOpening {
            _ = await session.attemptUserMove(from: move.0, to: move.1)
        }

        // The probes were the app's idea, and the opponent has already moved.
        #expect(!flagged.isEmpty)
        #expect(flagged.allSatisfy { $0 == false })
    }

    @Test("Resigning while the coach is deciding does not hand the board back")
    func endingTheGameDuringTheProbeSticks() async throws {
        let engine = scriptedEngine()
        var target: GameSession?
        var probes = 0
        engine.duringSearchOfLimit = { limit in
            guard case .nodes = limit else { return }
            probes += 1
            target?.resign()
        }

        let session = makeSession(
            .guided(userColor: .white, opponentRating: 1200, focusHabit: .scanThreats),
            engine: engine
        )
        target = session
        await session.start()
        for move in Self.userOpening {
            _ = await session.attemptUserMove(from: move.0, to: move.1)
        }

        // The options sheet is reachable throughout the probe. Handing the board
        // back afterwards left the user playing on inside a game already written
        // to disk and already rated.
        #expect(probes > 0)
        #expect(session.phase.isFinishedPhase)
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
        assisted: Bool = false,
        retractions: Int = 0
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
            usedAssistedRetry: assisted,
            retractionCount: retractions
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

    @Test("Every take-back halves what the game is worth, down to a quarter")
    func retractionsDiscountTheGame() async throws {
        let (clean, _) = makeWriter()
        let (once, _) = makeWriter()
        let (twice, _) = makeWriter()
        let (thrice, _) = makeWriter()

        let full = try #require(try await clean.apply(record(weight: .sparring)))
        let half = try #require(try await once.apply(record(weight: .sparring, retractions: 1)))
        let quarter = try #require(try await twice.apply(record(weight: .sparring, retractions: 2)))
        let floor = try #require(try await thrice.apply(record(weight: .sparring, retractions: 5)))

        // The failure this pins: a win after two retracted blunders used to move
        // the rating exactly as far as a clean win, so the number climbed faster
        // than the player and the ladder then served opponents they could not
        // beat unaided.
        #expect(abs((full - 1_100) / 2 - (half - 1_100)) < 0.000_1)
        #expect(abs((full - 1_100) / 4 - (quarter - 1_100)) < 0.000_1)
        // Past two the result has stopped meaning much; cutting further would
        // only be noise.
        #expect(abs(floor - quarter) < 0.000_1)
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

// MARK: - Take-backs before the reply

/// The board plays a tap and a drag through one gesture, so a release one
/// square short is a legal move made by accident. Until the undo window existed
/// a touch error cost a whole game unless it happened to be bad enough for the
/// blunder probe to catch it.
@Suite("Undo before the opponent answers")
@MainActor
struct GameSessionUndoTests {

    /// A sparring session whose opponent search takes the undo, if the session
    /// is offering one.
    ///
    /// The window only exists while the reply is being searched for, and
    /// `attemptUserMove` does not return until that search is done — so the
    /// only place a test can stand inside the window is the engine's own hook.
    private func session(
        _ configuration: GameSession.Configuration,
        take: Bool
    ) -> (GameSession, () -> Int) {
        let engine = ScriptedEngine()
        engine.onSearch = { _, _ in result([line("e7e5", cp: 10)]) }

        var target: GameSession?
        var offered = 0
        engine.duringSearch = {
            guard let target, target.canUndoLastMove else { return }
            offered += 1
            if take { target.undoLastUserMove() }
        }

        let made = makeSession(configuration, engine: engine)
        target = made
        return (made, { offered })
    }

    @Test("A move taken back leaves the board, the list and the clock as they were")
    func undoRewindsEverything() async throws {
        let (session, offered) = self.session(
            .sparring(userColor: .white, opponentRating: 1_200),
            take: true
        )
        let base = GameSession.Configuration.sparring(userColor: .white, opponentRating: 1_200)
            .baseSeconds * 1_000

        await session.start()
        let played = await session.attemptUserMove(from: .e2, to: .e4)

        #expect(played)
        #expect(offered() == 1)
        #expect(session.moves.isEmpty)
        #expect(session.board.position.piece(at: .e2) != nil)
        #expect(session.lastMove == nil)
        // The increment is un-earned: a take-back that paid one would make it
        // the cheapest way to buy time on the clock.
        #expect(session.userClockMs == base)
        guard case .userToMove = session.phase else {
            Issue.record("expected the board back")
            return
        }
        // And the window is shut: there is nothing left to take back.
        #expect(!session.canUndoLastMove)
    }

    @Test("The reply that was already searching never lands")
    func theCancelledReplyIsDiscarded() async throws {
        let (session, _) = self.session(
            .sparring(userColor: .white, opponentRating: 1_200),
            take: true
        )

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)

        // The search was running against a move list that has since lost its
        // last entry. A reply that landed anyway would be the answer to a move
        // nobody made.
        #expect(session.moves.isEmpty)
        #expect(session.board.position.sideToMove == .white)
    }

    @Test("A take-back counts against what the game is worth")
    func undoIsRecordedAsARetraction() async throws {
        let (session, _) = self.session(
            .sparring(userColor: .white, opponentRating: 1_200),
            take: true
        )

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)
        session.resign()

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected the game to be over")
            return
        }
        // No engine reading is revealed inside the window, so this is not the
        // coached take-back second-try is — but it is still a move the player
        // did not have to stand behind, and `EloLadder` halves K for it.
        #expect(session.finishedGameRecord(outcome: outcome).retractionCount == 1)
    }

    @Test("A calibration game is never offered one")
    func measurementGamesHaveNoUndo() async throws {
        let (session, offered) = self.session(
            .calibration(userColor: .white, opponentRating: 1_200),
            take: false
        )

        await session.start()
        _ = await session.attemptUserMove(from: .e2, to: .e4)

        // Those five games seed the rating every other screen is built on. A
        // take-back there is not a convenience, it is a corrupted measurement
        // nobody can see afterwards.
        #expect(offered() == 0)
        #expect(session.moves.map(\.san) == ["e4", "e5"])
    }

    @Test("Keeping a blundered move does not reopen the previous move's window")
    func keepingTheOriginalClosesTheWindow() async throws {
        let engine = ScriptedEngine()
        engine.onSearch = { position, limit in
            if case .depthWithin = limit {
                return result([line(history(position).count <= 1 ? "d7d5" : "g8f6", cp: 10)])
            }
            // Scores `e2e4` as a blunder and `d2d4` as fine, so the second move
            // is retracted by the coach and the first is not.
            return result([line("e7e5", cp: history(position).last == "e2e4" ? 600 : 40)])
        }

        var target: GameSession?
        var offered: [Bool] = []
        engine.duringSearchOfLimit = { limit in
            if case .depthWithin = limit, let target { offered.append(target.canUndoLastMove) }
        }

        let session = makeSession(.sparring(userColor: .white, opponentRating: 1_200), engine: engine)
        target = session

        await session.start()
        _ = await session.attemptUserMove(from: .d2, to: .d4)
        _ = await session.attemptUserMove(from: .e2, to: .e4)
        await session.keepOriginalMove()

        // The first move's window opens normally. The second must not: a
        // snapshot left over from move one would rewind the board two moves
        // while taking one entry off the list.
        #expect(offered == [true, false])
        #expect(session.moves.map(\.san) == ["d4", "d5", "e4", "Nf6"])
    }
}

// MARK: - Opponent resignation

/// Without this a dead-won game had to be played to mate — session time spent
/// on nothing the app is trying to teach, against the "~10 min" the Today card
/// promises.
@Suite("The opponent resigns")
@MainActor
struct GameSessionResignationTests {

    /// Seventeen quiet White moves, none of them a capture, a check or a double
    /// push, so the game reaches ply 34 with no repetition and no en passant to
    /// muddy what is being measured.
    static let userMoves: [(Square, Square)] = [
        (.a2, .a3), (.b2, .b3), (.c2, .c3), (.d2, .d3), (.e2, .e3), (.f2, .f3), (.g2, .g3), (.h2, .h3),
        (.a3, .a4), (.b3, .b4), (.c3, .c4), (.d3, .d4), (.e3, .e4), (.f3, .f4), (.g3, .g4), (.h3, .h4),
        (.g1, .f3)
    ]
    static let opponentMoves = [
        "a7a6", "b7b6", "c7c6", "d7d6", "e7e6", "f7f6", "g7g6", "h7h6",
        "a6a5", "b6b5", "c6c5", "d6d5", "e6e5", "f6f5", "g6g5", "h6h5",
        "g8f6"
    ]

    private func session(opponentRating: Int, opponentScoreCp: Int) -> GameSession {
        let engine = ScriptedEngine()
        engine.onSearch = { position, _ in
            let index = history(position).count / 2
            return result([
                line(Self.opponentMoves[min(index, Self.opponentMoves.count - 1)], cp: opponentScoreCp)
            ])
        }
        return makeSession(
            GameSession.Configuration(
                userColor: .white,
                opponentRating: opponentRating,
                baseSeconds: 600,
                incrementSeconds: 5,
                mode: "sparring",
                secondTryEnabled: false,
                guidedEnabled: false
            ),
            engine: engine
        )
    }

    private func play(_ session: GameSession) async {
        await session.start()
        for move in Self.userMoves {
            guard !session.isFinished else { return }
            _ = await session.attemptUserMove(from: move.0, to: move.1)
        }
    }

    @Test("A strong opponent gives up a position it reads as gone")
    func hopelessOpponentResigns() async throws {
        let session = self.session(opponentRating: 2_000, opponentScoreCp: -1_000)
        await play(session)

        guard case .finished(let outcome) = session.phase else {
            Issue.record("expected a resignation")
            return
        }
        #expect(outcome.result == "1-0")
        #expect(outcome.termination == GameTermination.resignation.rawValue)
        #expect(outcome.userWon == true)
        // Ply 30 is the earliest it is allowed to, and it is held across three
        // of its own moves — so 30, 32, and then 34, where it gives up.
        #expect(session.moves.count == 34)
    }

    @Test("A level position is played on")
    func levelOpponentPlaysOn() async throws {
        let session = self.session(opponentRating: 2_000, opponentScoreCp: 0)
        await play(session)

        if case .finished = session.phase {
            Issue.record("a level game was resigned")
        }
        #expect(session.moves.count == 34)
    }

    @Test("A beginner plays it out")
    func weakOpponentNeverResigns() async throws {
        let session = self.session(opponentRating: 900, opponentScoreCp: -1_000)
        await play(session)

        // At 900 the position is not actually lost — the user still has to
        // convert it, and being handed the point they had not yet earned is
        // both a lie about the game and a lost conversion rehearsal.
        if case .finished = session.phase {
            Issue.record("a 900 resigned")
        }
    }

    @Test("The bar moves with the opponent's rating")
    func ruleIsRatingBanded() throws {
        #expect(GameSession.resignationRule(opponentRating: 800) == nil)
        #expect(GameSession.resignationRule(opponentRating: 1_199) == nil)

        let club = try #require(GameSession.resignationRule(opponentRating: 1_500))
        let strong = try #require(GameSession.resignationRule(opponentRating: 2_000))

        // A stronger player resigns earlier and on a smaller margin, because a
        // stronger player is right about it more often.
        #expect(strong.minimumPly < club.minimumPly)
        #expect(strong.userWinPercent < club.userWinPercent)
    }
}
