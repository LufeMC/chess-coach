import ChessKit
import Database
import EngineKit
import Foundation
import Observation

/// Drives one live game: user move → opponent reply → clock → termination.
///
/// The board is the source of truth for legality; this owns everything around
/// it — whose turn it is, the clocks, the opponent's thinking, and the training
/// interruptions (guided prompts, second-try retractions) that make this a
/// training tool rather than a chess app.
@Observable
@MainActor
final class GameSession {

    enum Phase: Equatable {
        case notStarted
        case userToMove
        case opponentThinking
        /// A blunder was just played and retracted; the user must try again.
        case secondTry(SecondTryState)
        /// Guided mode paused before the user's move to ask a question.
        case guidedPrompt(GuidedPromptState)
        case finished(Outcome)
    }

    struct Outcome: Equatable {
        var result: String  // "1-0" | "0-1" | "1/2-1/2"
        var termination: String
        var userWon: Bool?
    }

    struct SecondTryState: Equatable {
        var retractedMove: String
        var hintLevel: Int
        var attemptsUsed: Int
        var deltaEP: Double
        /// Square to pulse at hint level 1.
        var hintSquare: Square?
        /// Opponent refutation to draw at hint level 2.
        var refutationArrow: (from: Square, to: Square)?

        static func == (lhs: SecondTryState, rhs: SecondTryState) -> Bool {
            lhs.retractedMove == rhs.retractedMove && lhs.hintLevel == rhs.hintLevel
                && lhs.attemptsUsed == rhs.attemptsUsed
        }
    }

    struct GuidedPromptState: Equatable {
        var habitID: String
        var question: String
        var ply: Int
    }

    struct Configuration: Sendable {
        var userColor: Piece.Color
        var opponentRating: Int
        var baseSeconds: Int
        var incrementSeconds: Int
        var mode: String  // "sparring" | "guided" | "calibration"
        var secondTryEnabled: Bool
        var guidedEnabled: Bool

        static func sparring(userColor: Piece.Color, opponentRating: Int) -> Configuration {
            Configuration(
                userColor: userColor,
                opponentRating: opponentRating,
                baseSeconds: 600,
                incrementSeconds: 5,
                mode: "sparring",
                secondTryEnabled: true,
                guidedEnabled: false
            )
        }

        /// Calibration games are plain: interruptions would contaminate the
        /// rating estimate they exist to produce.
        static func calibration(userColor: Piece.Color, opponentRating: Int) -> Configuration {
            Configuration(
                userColor: userColor,
                opponentRating: opponentRating,
                baseSeconds: 600,
                incrementSeconds: 5,
                mode: "calibration",
                secondTryEnabled: false,
                guidedEnabled: false
            )
        }
    }

    // MARK: - Observable state

    private(set) var board = Board(position: .standard)
    private(set) var phase: Phase = .notStarted
    private(set) var moves: [PlayedMove] = []
    private(set) var lastMove: (from: Square, to: Square)?
    private(set) var userClockMs: Int
    private(set) var opponentClockMs: Int
    /// Opponent's live evaluation, shown only after the game unless in guided mode.
    private(set) var currentEvaluation: Double = 50

    let configuration: Configuration
    let gameID = UUID()

    /// Set when the finished game could not be written to disk. The play surface
    /// can surface it; nothing else depends on it, because a game that failed to
    /// save was still played.
    private(set) var persistenceFailure: String?

    struct PlayedMove: Sendable {
        var ply: Int
        var san: String
        var uci: String
        var byUser: Bool
        var thinkTimeMs: Int
        var clockAfterMs: Int
    }

    // MARK: - Dependencies

    private let engineService: EngineService
    private let humanizer: Humanizer
    private let persistence: GamePersistence?
    private let startedAt = Date()
    private var moveStartedAt = Date()
    private var opponentTask: Task<Void, Never>?
    /// Retained so the save is not cancelled by the view going away when the
    /// user leaves the finished-game screen.
    private var saveTask: Task<Void, Never>?

    init(
        configuration: Configuration,
        engineService: EngineService,
        persistence: GamePersistence? = .shared
    ) {
        self.configuration = configuration
        self.engineService = engineService
        self.persistence = persistence
        self.humanizer = Humanizer(profile: .interpolated(rating: configuration.opponentRating))
        self.userClockMs = configuration.baseSeconds * 1000
        self.opponentClockMs = configuration.baseSeconds * 1000
    }

    var userToMove: Bool {
        board.position.sideToMove == configuration.userColor
    }

    // MARK: - Lifecycle

    func start() async {
        phase = userToMove ? .userToMove : .opponentThinking
        moveStartedAt = Date()
        if !userToMove {
            await playOpponentMove()
        }
    }

    func resign() {
        opponentTask?.cancel()
        let result = configuration.userColor == .white ? "0-1" : "1-0"
        finish(Outcome(result: result, termination: GameTermination.resignation.rawValue, userWon: false))
    }

    /// Charges elapsed time to whoever is on move and ends the game if their
    /// clock has run out.
    ///
    /// Called before every user move, but the play surface should also call it
    /// from a display timer: a player who simply stops moving still flags, and
    /// nothing else in this class is driven by the passage of time.
    @discardableResult
    func checkClock() -> Bool {
        guard !isFinished else { return true }
        let elapsedMs = Int(Date().timeIntervalSince(moveStartedAt) * 1000)

        switch phase {
        case .userToMove, .secondTry, .guidedPrompt:
            guard elapsedMs >= userClockMs else { return false }
            userClockMs = 0
            opponentTask?.cancel()
            finish(
                Outcome(
                    result: configuration.userColor == .white ? "0-1" : "1-0",
                    termination: GameTermination.timeout.rawValue,
                    userWon: false
                )
            )
            return true
        case .opponentThinking:
            guard elapsedMs >= opponentClockMs else { return false }
            opponentClockMs = 0
            opponentTask?.cancel()
            finish(
                Outcome(
                    result: configuration.userColor == .white ? "1-0" : "0-1",
                    termination: GameTermination.timeout.rawValue,
                    userWon: true
                )
            )
            return true
        case .notStarted, .finished:
            return false
        }
    }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    // MARK: - User moves

    /// Attempts a user move. Returns false if it was rejected (illegal, or
    /// retracted by second-try), which tells the board view to snap back.
    @discardableResult
    func attemptUserMove(from: Square, to: Square) async -> Bool {
        guard case .userToMove = phase, userToMove else { return false }
        // Flagging is checked before legality: a move made after the clock hit
        // zero never reaches the board.
        guard !checkClock() else { return false }
        guard board.canMove(pieceAt: from, to: to) else { return false }

        let thinkTimeMs = Int(Date().timeIntervalSince(moveStartedAt) * 1000)

        // Snapshot before mutating so second-try can restore it.
        let positionBefore = board.position

        guard let move = board.move(pieceAt: from, to: to) else { return false }

        userClockMs = max(0, userClockMs - thinkTimeMs) + configuration.incrementSeconds * 1000
        record(move: move, byUser: true, thinkTimeMs: thinkTimeMs, clockAfterMs: userClockMs)
        lastMove = (from, to)

        if let outcome = terminalOutcome() {
            finish(outcome)
            return true
        }

        // Second-try check happens after the move is on the board so the user
        // sees the consequence, then it is taken back.
        if configuration.secondTryEnabled, userClockMs > 60_000,
            let blunder = await detectBlunder(positionBefore: positionBefore, playedMove: move)
        {
            board = Board(position: positionBefore)
            lastMove = nil
            phase = .secondTry(blunder)
            moveStartedAt = Date()
            return true
        }

        phase = .opponentThinking
        await playOpponentMove()
        return true
    }

    /// Advances the second-try hint ladder one rung. Never skips and never resets.
    func requestHint() {
        guard case .secondTry(var state) = phase else { return }
        state.hintLevel = min(state.hintLevel + 1, 2)
        phase = .secondTry(state)
    }

    /// Abandons the retry and plays the original move as-is.
    func keepOriginalMove() async {
        guard case .secondTry(let state) = phase else { return }
        guard
            let move = EngineLANParser.parse(move: state.retractedMove, for: board.position.sideToMove, in: board.position),
            board.move(pieceAt: move.start, to: move.end) != nil
        else {
            phase = .userToMove
            return
        }
        lastMove = (move.start, move.end)
        phase = .opponentThinking
        await playOpponentMove()
    }

    // MARK: - Opponent

    private func playOpponentMove() async {
        opponentTask?.cancel()
        opponentTask = Task { [weak self] in
            guard let self else { return }
            await self.runOpponentMove()
        }
        await opponentTask?.value
    }

    private func runOpponentMove() async {
        let profile = humanizer.profile
        let device = await engineService.deviceProfile

        await engineService.acquire(
            .play,
            configuration: EngineService.Configuration(
                multiPV: profile.multiPV,
                threads: device.threads,
                hashMB: device.hashMB
            )
        )
        defer { Task { await engineService.release(.play) } }

        let history = moves.map(\.uci)
        let started = Date()

        do {
            let result = try await engineService.search(
                .startPosition(moves: history),
                limit: .depth(profile.depth)
            )

            guard !Task.isCancelled else { return }

            var rng = SystemRandomNumberGenerator()
            guard
                let selection = humanizer.choose(from: result.lines, ply: moves.count, using: &rng)
            else {
                // No legal move: the position is terminal.
                finish(
                    terminalOutcome()
                        ?? Outcome(
                            result: "1/2-1/2",
                            termination: GameTermination.unknown.rawValue,
                            userWon: nil
                        )
                )
                return
            }

            // A visible pause: an instant reply on every move breaks the
            // illusion far more than a suboptimal move does.
            let think = humanizer.thinkTime(candidates: result.lines, using: &rng)
            let elapsed = Date().timeIntervalSince(started)
            let remaining = think - .seconds(elapsed)
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            guard !Task.isCancelled else { return }

            guard
                let move = EngineLANParser.parse(move: selection.move, for: board.position.sideToMove, in: board.position),
                let played = board.move(pieceAt: move.start, to: move.end)
            else { return }

            let thinkMs = Int(Date().timeIntervalSince(started) * 1000)
            if thinkMs >= opponentClockMs {
                opponentClockMs = 0
                finish(
                    Outcome(
                        result: configuration.userColor == .white ? "1-0" : "0-1",
                        termination: GameTermination.timeout.rawValue,
                        userWon: true
                    )
                )
                return
            }
            opponentClockMs = max(0, opponentClockMs - thinkMs) + configuration.incrementSeconds * 1000
            record(move: played, byUser: false, thinkTimeMs: thinkMs, clockAfterMs: opponentClockMs)
            lastMove = (move.start, move.end)

            if let principal = result.principal {
                // Engine scores are side-to-move relative; store from the
                // user's perspective so the eval bar doesn't flip each ply.
                let winPct = winPercent(principal.score)
                currentEvaluation = board.position.sideToMove == configuration.userColor ? winPct : 100 - winPct
            }

            if let outcome = terminalOutcome() {
                finish(outcome)
            } else {
                phase = .userToMove
                moveStartedAt = Date()
            }
        } catch {
            phase = .userToMove
            moveStartedAt = Date()
        }
    }

    // MARK: - Helpers

    private func record(move: Move, byUser: Bool, thinkTimeMs: Int, clockAfterMs: Int) {
        moves.append(
            PlayedMove(
                ply: moves.count + 1,
                san: move.san,
                uci: "\(move.start)\(move.end)",
                byUser: byUser,
                thinkTimeMs: thinkTimeMs,
                clockAfterMs: clockAfterMs
            )
        )
    }

    private func terminalOutcome() -> Outcome? {
        switch board.state {
        case .checkmate(let color):
            // `color` is the side that *was* mated, so the winner is the other one.
            let userWon = color != configuration.userColor
            return Outcome(
                result: color == .white ? "0-1" : "1-0",
                termination: GameTermination.checkmate.rawValue,
                userWon: userWon
            )
        case .draw(let reason):
            return Outcome(result: "1/2-1/2", termination: reason.rawValue, userWon: nil)
        default:
            return nil
        }
    }

    // MARK: - Persistence

    /// Ends the game and writes it to disk.
    ///
    /// Every termination — mate, resignation, draw, flag — funnels through here
    /// so there is exactly one place a finished game can be created and exactly
    /// one place it gets saved.
    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        phase = .finished(outcome)
        opponentTask?.cancel()

        guard let persistence else {
            persistenceFailure = "The database is unavailable; this game was not saved."
            AppLog.persistence.error("No database: game \(self.gameID.uuidString, privacy: .public) discarded.")
            return
        }

        // Snapshot everything the writer needs *now*, on the main actor, so the
        // save works from immutable values and cannot observe the session
        // mutating underneath it.
        let record = finishedGameRecord(outcome: outcome)
        let engineService = self.engineService

        saveTask = Task { [weak self] in
            do {
                try await persistence.save(record)
            } catch {
                self?.recordPersistenceFailure(String(describing: error))
                return
            }

            // Analysis is queued rather than started directly: the queue is what
            // makes a preempted or crashed pass resumable, and draining it here
            // also picks up anything an earlier session left behind.
            guard let service = AnalysisService.shared(engineService: engineService) else { return }
            await service.analyzePending()
        }
    }

    private func recordPersistenceFailure(_ reason: String) {
        persistenceFailure = reason
        AppLog.persistence.error("Game \(self.gameID.uuidString, privacy: .public) not saved: \(reason, privacy: .public)")
    }

    private func finishedGameRecord(outcome: Outcome) -> FinishedGameRecord {
        FinishedGameRecord(
            id: gameID,
            startedAt: startedAt,
            endedAt: Date(),
            mode: configuration.mode,
            userColor: configuration.userColor == .white ? .white : .black,
            opponentRating: configuration.opponentRating,
            result: outcome.result,
            termination: outcome.termination,
            pgn: pgn(result: outcome.result),
            moves: moves.map {
                FinishedGameRecord.Move(
                    ply: $0.ply,
                    san: $0.san,
                    uci: $0.uci,
                    byUser: $0.byUser,
                    thinkTimeMs: $0.thinkTimeMs,
                    clockAfterMs: $0.clockAfterMs
                )
            },
            opponentParams: FinishedGameRecord.OpponentParams(
                opponentRating: configuration.opponentRating,
                baseSeconds: configuration.baseSeconds,
                incrementSeconds: configuration.incrementSeconds,
                secondTryEnabled: configuration.secondTryEnabled,
                guidedEnabled: configuration.guidedEnabled
            ),
            // A game where blunders could be taken back, or where the coach
            // answered questions mid-game, says nothing about playing strength —
            // so it must not feed the rating. Calibration games have both off.
            isRated: !configuration.secondTryEnabled && !configuration.guidedEnabled
        )
    }

    /// Quick evaluation of whether the just-played move was a blunder worth
    /// interrupting for. Uses a short search — this runs between the user's move
    /// and the opponent's reply, so it has a latency budget of a few hundred ms.
    private func detectBlunder(positionBefore: Position, playedMove: Move) async -> SecondTryState? {
        let device = await engineService.deviceProfile
        await engineService.acquire(.probe, configuration: .probe(device: device))
        defer { Task { await engineService.release(.probe) } }

        let historyBefore = moves.dropLast().map(\.uci)
        let playedUCI = "\(playedMove.start)\(playedMove.end)"

        do {
            let before = try await engineService.search(
                .startPosition(moves: Array(historyBefore)),
                limit: .nodes(60_000)
            )
            let after = try await engineService.search(
                .startPosition(moves: Array(historyBefore) + [playedUCI]),
                limit: .nodes(60_000)
            )

            guard let bestBefore = before.principal, let bestAfter = after.principal else { return nil }

            // `after` is from the opponent's perspective — negate to compare.
            let epBefore = winPercent(bestBefore.score) / 100
            let epAfter = (100 - winPercent(bestAfter.score)) / 100
            let deltaEP = epBefore - epAfter

            // Rung 1 trains blunder-avoidance only; higher rungs also catch
            // mistakes. Threshold comes from the curriculum, defaulting to the
            // blunder bar.
            guard deltaEP >= 0.30 else { return nil }

            let refutation = bestAfter.pv.first.flatMap {
                EngineLANParser.parse(move: $0, for: board.position.sideToMove, in: board.position)
            }

            return SecondTryState(
                retractedMove: playedUCI,
                hintLevel: 0,
                attemptsUsed: 0,
                deltaEP: deltaEP,
                hintSquare: refutation?.end,
                refutationArrow: refutation.map { ($0.start, $0.end) }
            )
        } catch {
            return nil
        }
    }

    private func winPercent(_ score: UCIScore) -> Double {
        switch score {
        case .mate(let moves): return moves > 0 ? 100 : 0
        case .centipawns(let cp):
            let clamped = Double(min(max(cp, -1000), 1000))
            return 50 + 50 * (2 / (1 + exp(-0.00368208 * clamped)) - 1)
        }
    }

    /// PGN for persistence. The move list is the canonical record; the app can
    /// always re-derive positions from it.
    func pgn(result: String) -> String {
        var text = ""
        text += "[Event \"ChessCoach \(configuration.mode)\"]\n"
        text += "[Date \"\(ISO8601DateFormatter().string(from: Date()).prefix(10))\"]\n"
        text += "[White \"\(configuration.userColor == .white ? "Luis" : "Engine \(configuration.opponentRating)")\"]\n"
        text += "[Black \"\(configuration.userColor == .black ? "Luis" : "Engine \(configuration.opponentRating)")\"]\n"
        text += "[Result \"\(result)\"]\n"
        text += "[TimeControl \"\(configuration.baseSeconds)+\(configuration.incrementSeconds)\"]\n\n"

        for (index, move) in moves.enumerated() {
            if index % 2 == 0 { text += "\(index / 2 + 1). " }
            text += "\(move.san) "
        }
        text += result
        return text
    }
}
