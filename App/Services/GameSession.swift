import AnalysisKit
import ChessKit
import Database
import EngineKit
import Foundation
import Observation
import TrainingCore

#if canImport(UIKit)
    import UIKit
#endif

/// Holds notification tokens so they are removed when their owner is released.
///
/// It exists because `deinit` on a `@MainActor` type cannot touch the actor's
/// isolated storage, so the tokens cannot simply live on ``GameSession`` and be
/// unregistered there. Handing them to a plain object means the tokens die with
/// the box, and the box dies with the session.
final class ObserverBox: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

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
        /// What the retracted attempt cost the user's clock.
        ///
        /// Carried because the move is not on the board any more: a retraction
        /// leaves no trace at all, so the time it took has to travel with the
        /// state that survives it or the kept move is recorded as instant.
        var thinkTimeMs: Int = 0

        /// The rung at which the coach stops nudging and draws the refutation.
        static let assistedHintLevel = 2

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
        /// The habit guided mode asks about when the position does not name a
        /// better one. Nil outside guided mode, where nothing consults it.
        var guidedFocusHabit: Habit?

        static func sparring(userColor: Piece.Color, opponentRating: Int) -> Configuration {
            Configuration(
                userColor: userColor,
                opponentRating: opponentRating,
                baseSeconds: 900,
                incrementSeconds: 10,
                mode: "sparring",
                secondTryEnabled: true,
                guidedEnabled: false
            )
        }

        /// A game the coach interrupts with questions, built around the week's
        /// focus habit.
        ///
        /// Second-try is off: guided mode already spends the user's flow on
        /// pauses, and stacking a take-back on top of a question would leave a
        /// game with no stretch the user played unaided. It also keeps the two
        /// signals separable — a guided prompt's verdict is only evidence about
        /// the habit if the move that answered it was the user's own.
        static func guided(userColor: Piece.Color, opponentRating: Int, focusHabit: Habit) -> Configuration {
            Configuration(
                userColor: userColor,
                opponentRating: opponentRating,
                baseSeconds: 900,
                incrementSeconds: 10,
                mode: "guided",
                secondTryEnabled: false,
                guidedEnabled: true,
                guidedFocusHabit: focusHabit
            )
        }

        /// Calibration games are plain: interruptions would contaminate the
        /// rating estimate they exist to produce.
        static func calibration(userColor: Piece.Color, opponentRating: Int) -> Configuration {
            Configuration(
                userColor: userColor,
                opponentRating: opponentRating,
                baseSeconds: 900,
                incrementSeconds: 10,
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
        /// Raw value of the `Habit` a guided prompt asked about immediately
        /// before this move.
        var guidedPromptHabit: String?
        /// Whether the move counted as answering that prompt.
        var guidedPromptHit: Bool?
    }

    // MARK: - Dependencies

    private let engineService: EngineService
    private let engine: SessionEngine
    private let humanizer: Humanizer
    private let persistence: GamePersistence?
    private let ladder: LadderRatingWriter?
    private let pause: @Sendable (Duration) async -> Void
    private let startedAt = Date()
    /// When the side to move started thinking.
    ///
    /// Readable so the play surface can tick the clocks down between moves:
    /// `userClockMs` and `opponentClockMs` only change when a move *completes*,
    /// so a view that reads them directly draws a frozen clock — and the running
    /// clock is what this app shows instead of a "thinking" spinner.
    private(set) var moveStartedAt = Date()
    /// Consecutive failed opponent searches. Reset by any move that lands, so
    /// the budget is per-stall rather than per-game.
    private var opponentRetriesUsed = 0
    private static let maxOpponentRetries = 3

    /// Set while a guided prompt has been answered but the move it was asked
    /// about has not been played yet.
    private var pendingGuidedPrompt: PendingGuidedPrompt?
    /// What the engine saw at the position the live guided prompt paused on.
    private var guidedProbe: GuidedProbe?
    private var guidedPausesUsed = 0
    private var lastGuidedPausePly: Int?
    /// Set once the coach has drawn a refutation and the user has taken the move
    /// back. See ``FinishedGameRecord/usedAssistedRetry``.
    private var usedAssistedRetry = false
    private var opponentTask: Task<Void, Never>?
    /// Retained so the save is not cancelled by the view going away when the
    /// user leaves the finished-game screen.
    private var saveTask: Task<Void, Never>?

    /// When the app left the foreground, while it is away.
    ///
    /// Nil whenever the app is on screen, which is also what makes
    /// ``resumeClock(at:)`` idempotent: a foreground notification with no
    /// matching background one has nothing to forgive.
    private var leftForegroundAt: Date?
    /// Removes the lifecycle observers when this session is released.
    private let foregroundObservers = ObserverBox()

    /// - Parameters:
    ///   - engine: How this session talks to Stockfish. A `nil` default rather
    ///     than a literal because the live value is built from another
    ///     parameter, which a default expression cannot see.
    ///   - pause: How the opponent's visible thinking pause is spent. Injected
    ///     because it is measured in seconds of wall clock: anything driving a
    ///     whole game through this class other than a person would otherwise
    ///     spend minutes asleep.
    init(
        configuration: Configuration,
        engineService: EngineService,
        persistence: GamePersistence? = .shared,
        ladder: LadderRatingWriter? = .shared,
        engine: SessionEngine? = nil,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.engineService = engineService
        self.engine = engine ?? .live(engineService)
        self.persistence = persistence
        self.ladder = ladder
        self.pause = pause
        self.humanizer = Humanizer(profile: .interpolated(rating: configuration.opponentRating))
        self.userClockMs = configuration.baseSeconds * 1000
        self.opponentClockMs = configuration.baseSeconds * 1000
        observeForegroundTransitions()
    }

    var userToMove: Bool {
        board.position.sideToMove == configuration.userColor
    }

    // MARK: - Lifecycle

    func start() async {
        moveStartedAt = Date()
        if userToMove {
            await handOverToUser()
        } else {
            phase = .opponentThinking
            await playOpponentMove()
        }
    }

    func resign() {
        opponentTask?.cancel()
        let result = configuration.userColor == .white ? "0-1" : "1-0"
        finish(Outcome(result: result, termination: GameTermination.resignation.rawValue, userWon: false))
    }

    // MARK: - Foreground

    /// Stops the clock because the app is leaving the foreground.
    ///
    /// ## Why the clock cannot just keep running
    ///
    /// Everything about timing in this class is wall-clock arithmetic against
    /// ``moveStartedAt``, which is correct while the app is on screen and a lie
    /// the moment it is not. iOS suspends the process; it does not suspend
    /// `Date()`. So a player who backgrounded the app on their move and came
    /// back an hour later used to have the whole hour charged at once by the
    /// first ``checkClock()`` after they returned — an instant loss on time, in
    /// a game they had not lost.
    ///
    /// It is worse than a wrong clock, because it is *non-deterministic*: if iOS
    /// reclaimed the process while it was away, the session died with it and the
    /// user simply replayed the game. If iOS did not, they were flagged. The same
    /// user action produced two different games depending on memory pressure they
    /// could neither see nor control.
    ///
    /// And the flag lands hardest exactly where it can do the most damage.
    /// Calibration is the app's onboarding: five games seed the rating, the
    /// starting rung, and the opponent ladder every other screen reads. A phantom
    /// timeout there is not one bad game, it is a bad measurement the whole
    /// curriculum is then built on — and the user has no way to know it happened.
    ///
    /// The precedent is already in this file: a guided pause is not on anybody's
    /// clock, because the pause was the app's idea. Neither is a phone call.
    func suspendClock(at date: Date = Date()) {
        guard leftForegroundAt == nil else { return }
        leftForegroundAt = date
    }

    /// Resumes, forgiving every second the app spent away.
    ///
    /// The gap is repaid by pushing ``moveStartedAt`` *forward*, rather than by
    /// crediting the clocks: the side on move keeps the time they had actually
    /// burned before the app went away, and the away time simply never happened.
    /// That also keeps the think-time recorded on the next move honest, since it
    /// is measured from the same instant.
    ///
    /// - Returns: whether any time was forgiven, so tests and callers can tell a
    ///   real resume from a redundant notification.
    @discardableResult
    func resumeClock(at date: Date = Date()) -> Bool {
        guard let leftForegroundAt else { return false }
        self.leftForegroundAt = nil
        guard date > leftForegroundAt, !isFinished else { return false }
        moveStartedAt = Self.moveStart(
            forgivingAwayTime: moveStartedAt,
            leftAt: leftForegroundAt,
            returnedAt: date
        )
        return true
    }

    /// Where ``moveStartedAt`` lands once the away time is forgiven.
    ///
    /// Pure, and separate from ``resumeClock(at:)``, because it is two lines of
    /// date arithmetic that decide whether a game is lost — the kind of thing
    /// that is impossible to eyeball and easy to get subtly wrong, exactly like
    /// the countdown formatting in ``PlayClock``.
    ///
    /// The clamp is the half worth stating plainly: the result is never later
    /// than the moment the user came back. Without it, an opponent reply that
    /// landed as the app went away — restarting the move inside the gap — would
    /// be shifted by the gap's full width and date the current move in the
    /// future, which reads as a clock counting *up*.
    nonisolated static func moveStart(
        forgivingAwayTime moveStartedAt: Date,
        leftAt: Date,
        returnedAt: Date
    ) -> Date {
        let away = returnedAt.timeIntervalSince(leftAt)
        guard away > 0 else { return moveStartedAt }
        return min(returnedAt, moveStartedAt.addingTimeInterval(away))
    }

    /// Subscribes the session to its own lifecycle.
    ///
    /// The session listens rather than being told by a screen. Every surface that
    /// runs a game would otherwise have to remember to forward `scenePhase`, and
    /// the one that forgets does not fail visibly — it fails as a wrong result in
    /// a game weeks later.
    private func observeForegroundTransitions() {
        #if canImport(UIKit)
            let center = NotificationCenter.default
            // `queue: .main` so the handler runs synchronously inside the
            // notification dispatch. Hopping to a `Task` instead would risk the
            // process suspending before the closure was ever scheduled, which is
            // the one moment this has to be recorded.
            foregroundObservers.tokens = [
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let at = Date()
                    MainActor.assumeIsolated { self?.suspendClock(at: at) }
                },
                center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    let at = Date()
                    MainActor.assumeIsolated { self?.resumeClock(at: at) }
                }
            ]
        #endif
    }

    /// Charges elapsed time to whoever is on move and ends the game if their
    /// clock has run out.
    ///
    /// Called before every user move, but the play surface should also call it
    /// from a display timer: a player who simply stops moving still flags, and
    /// nothing else in this class is driven by the passage of time.
    ///
    /// A guided pause is not on anybody's clock. The pause was the app's idea,
    /// and flagging someone for reading a question they did not ask for is the
    /// fastest way to make guided mode feel like a tax.
    @discardableResult
    func checkClock() -> Bool {
        guard !isFinished else { return true }
        // Time spent off screen is nobody's move. See ``suspendClock(at:)``.
        guard leftForegroundAt == nil else { return false }
        let elapsedMs = Int(Date().timeIntervalSince(moveStartedAt) * 1000)

        switch phase {
        case .userToMove, .secondTry:
            guard elapsedMs >= userClockMs else { return false }
            userClockMs = 0
            opponentTask?.cancel()
            finish(timeoutOutcome(flagged: configuration.userColor))
            return true
        case .opponentThinking:
            guard elapsedMs >= opponentClockMs else { return false }
            opponentClockMs = 0
            opponentTask?.cancel()
            finish(timeoutOutcome(flagged: opponentColor))
            return true
        case .notStarted, .guidedPrompt, .finished:
            return false
        }
    }

    /// The colour the opponent plays.
    private var opponentColor: Piece.Color {
        configuration.userColor == .white ? .black : .white
    }

    /// What running out of time actually costs, which is not always the game.
    ///
    /// FIDE 6.9: a flag is only a loss if the *other* side could still mate. A
    /// player who flags against a bare king draws, and until now this app handed
    /// that opponent the win — a bare king could win on time. Rare, but it is a
    /// wrong result written to the games table and, in calibration, into the
    /// rating the whole curriculum is seeded from.
    private func timeoutOutcome(flagged color: Piece.Color) -> Outcome {
        guard !MatingMaterial.timeoutIsDraw(flagged: color, position: board.position) else {
            return Outcome(
                result: "1/2-1/2",
                termination: GameTermination.timeout.rawValue,
                userWon: nil
            )
        }
        let whiteLost = color == .white
        return Outcome(
            result: whiteLost ? "0-1" : "1-0",
            termination: GameTermination.timeout.rawValue,
            userWon: color != configuration.userColor
        )
    }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    // MARK: - User moves

    /// Attempts a user move. Returns false if it was rejected (illegal, or
    /// retracted by second-try), which tells the board view to snap back.
    @discardableResult
    /// Whether playing `from`–`to` would land a pawn on the last rank.
    ///
    /// Asked *before* the move is applied, because the promotion piece has to
    /// be chosen by the user and the board can only present that choice while
    /// the move is still pending.
    func isPromotion(from: Square, to: Square) -> Bool {
        guard let piece = board.position.piece(at: from), piece.kind == .pawn else { return false }
        return (piece.color == .white && to.rank == 8) || (piece.color == .black && to.rank == 1)
    }

    /// - Parameter promoting: the piece a promoting pawn becomes. Queen is the
    ///   fallback, but it is only a fallback: the app's own theme vocabulary
    ///   includes `underPromotion`, so a session that could not represent a
    ///   knight promotion could not represent one of the ideas it teaches.
    func attemptUserMove(from: Square, to: Square, promoting: Piece.Kind = .queen) async -> Bool {
        guard case .userToMove = phase, userToMove else { return false }
        // Flagging is checked before legality: a move made after the clock hit
        // zero never reaches the board.
        guard !checkClock() else { return false }
        guard board.canMove(pieceAt: from, to: to) else { return false }

        let thinkTimeMs = Int(Date().timeIntervalSince(moveStartedAt) * 1000)

        // Snapshots so a retraction can put the game back exactly as it was. The
        // whole board is kept rather than its position, because `Board` also
        // carries the repetition counts: rebuilding one from a position resets
        // them, which silently disables threefold detection for the rest of the
        // game.
        let boardBefore = board
        let lastMoveBefore = lastMove
        let clockBeforeMove = userClockMs

        guard var move = board.move(pieceAt: from, to: to) else { return false }
        move = completePromotionIfNeeded(move, to: promoting)

        // A guided prompt is graded against the first move played after it,
        // retracted or not: erring immediately after being asked about an idea
        // is the evidence the curriculum gates on, and letting a take-back
        // rewrite the verdict would turn the hit rate into a measure of the
        // coach.
        let guided = takeGuidedVerdict(playedUCI: Self.uciText(for: move))

        userClockMs = max(0, userClockMs - thinkTimeMs) + configuration.incrementSeconds * 1000
        record(move: move, byUser: true, thinkTimeMs: thinkTimeMs, clockAfterMs: userClockMs, guided: guided)
        lastMove = (from, to)

        if let outcome = terminalOutcome() {
            finish(outcome)
            return true
        }

        // Second-try check happens after the move is on the board so the user
        // sees the consequence, then it is taken back.
        if configuration.secondTryEnabled, userClockMs > 60_000,
            let blunder = await detectBlunder(playedMove: move, thinkTimeMs: thinkTimeMs)
        {
            retract(
                to: boardBefore,
                lastMove: lastMoveBefore,
                clockBeforeMove: clockBeforeMove,
                thinkTimeMs: thinkTimeMs,
                guided: guided
            )
            phase = .secondTry(blunder)
            moveStartedAt = Date()
            return true
        }

        // The opponent's think time starts now, not when the user picked the
        // piece up: `checkClock` measures the side on move against
        // `moveStartedAt`, so leaving it at the user's start would charge the
        // opponent for the user's thinking and flag them early.
        moveStartedAt = Date()
        phase = .opponentThinking
        await playOpponentMove()
        return true
    }

    /// Undoes everything a retracted move touched.
    ///
    /// The move leaves `moves` rather than staying in it. That list is the UCI
    /// history the opponent's search is given, the PGN, the persisted plies and
    /// the ply numbering — a retracted move left in place puts a move the user
    /// never made into every one of them, and the replacement then appends a
    /// second record for the same turn.
    ///
    /// The clock keeps what the attempt actually cost and gives back only the
    /// increment. The increment is earned by completing a move and this one was
    /// not completed; the thinking, on the other hand, genuinely happened, and
    /// refunding it would make blundering the cheapest way to buy time — which
    /// now costs rating, because sparring feeds the ladder.
    private func retract(
        to boardBefore: Board,
        lastMove lastMoveBefore: (from: Square, to: Square)?,
        clockBeforeMove: Int,
        thinkTimeMs: Int,
        guided: GuidedPromptOutcome?
    ) {
        board = boardBefore
        moves.removeLast()
        lastMove = lastMoveBefore
        userClockMs = max(0, clockBeforeMove - thinkTimeMs)
        // The verdict survives the move it was about, to be written onto
        // whichever move ends up standing in its place.
        pendingGuidedPrompt = guided.map(PendingGuidedPrompt.graded)
    }

    /// Returns to the position the blunder was retracted from so the user can
    /// try again.
    ///
    /// Without this, `.secondTry` has no exit but playing the bad move: the
    /// board only accepts moves in `.userToMove`, so a retracted blunder would
    /// leave the game unplayable.
    func resumeAfterSecondTry() {
        guard case .secondTry(let state) = phase else { return }
        // Resuming once the refutation has been drawn means the replacement was
        // chosen with the answer on screen. `EloLadder` treats such a game as
        // unrated and has to: the result is partly the coach's.
        if state.hintLevel >= SecondTryState.assistedHintLevel { usedAssistedRetry = true }
        phase = .userToMove
        moveStartedAt = Date()
    }

    /// Ends a guided pause and hands the board back.
    ///
    /// `revealed` records whether the user asked to be shown the method instead
    /// of answering. It is not a failure — asking is a legitimate move and the
    /// escape hatch exists precisely so the pause never becomes a wall — but it
    /// is weaker evidence than answering unaided, so the two are kept apart
    /// rather than collapsed into one "answered" bit.
    ///
    /// The clock restarts here rather than at the prompt, because the pause was
    /// the app's idea: charging the user for time it took from them is the
    /// fastest way to make guided mode feel like a tax.
    func resolveGuidedPrompt(revealed: Bool) {
        guard case .guidedPrompt(let state) = phase else { return }
        pendingGuidedPrompt = .awaitingMove(
            ResolvedGuidedPrompt(
                habitID: state.habitID,
                unaided: !revealed,
                best: guidedProbe?.best,
                secondBest: guidedProbe?.secondBest
            )
        )
        guidedProbe = nil
        phase = .userToMove
        moveStartedAt = Date()
    }

    /// A resolved prompt waiting for the move that answers it.
    ///
    /// Held rather than written immediately because the verdict is a property
    /// of the *next* move — erring right after being asked about an idea is the
    /// evidence the curriculum gates on, and that move has not been played yet.
    struct ResolvedGuidedPrompt: Sendable, Equatable {
        var habitID: String
        var unaided: Bool
        /// The lines the pause was decided on, so the answering move can be
        /// graded against what the position actually offered.
        var best: UCIInfo?
        var secondBest: UCIInfo?
    }

    /// Advances the second-try hint ladder one rung. Never skips and never resets.
    func requestHint() {
        guard case .secondTry(var state) = phase else { return }
        state.hintLevel = min(state.hintLevel + 1, SecondTryState.assistedHintLevel)
        phase = .secondTry(state)
    }

    /// Abandons the retry and plays the original move as-is.
    ///
    /// The move is recorded here rather than kept from the first attempt: a
    /// retracted move leaves no trace, so this is the first time it joins the
    /// game. It pays the increment it was denied when it was taken back and
    /// nothing more — the deliberation between the two was the app's
    /// interruption, not the user's move time.
    func keepOriginalMove() async {
        guard case .secondTry(let state) = phase else { return }
        guard
            let move = EngineLANParser.parse(move: state.retractedMove, for: board.position.sideToMove, in: board.position),
            var played = board.move(pieceAt: move.start, to: move.end)
        else {
            phase = .userToMove
            moveStartedAt = Date()
            return
        }

        // The retracted move is replayed from its own UCI text, so its
        // promotion piece comes back with it rather than defaulting to a queen.
        played = completePromotionIfNeeded(played, to: move.promotedPiece?.kind ?? .queen)

        userClockMs += configuration.incrementSeconds * 1000
        record(
            move: played,
            byUser: true,
            thinkTimeMs: state.thinkTimeMs,
            clockAfterMs: userClockMs,
            guided: takeGuidedVerdict(playedUCI: state.retractedMove)
        )
        lastMove = (move.start, move.end)
        moveStartedAt = Date()
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

        // The handover happens after the opponent's lease is gone rather than
        // inside it. The guided probe wants the engine too, and asking for it
        // while the play lease is still held makes one move wait on the lease
        // held by the code waiting for it.
        guard case .opponentThinking = phase, userToMove else { return }
        await handOverToUser()
    }

    /// The wall-clock ceiling on one opponent search.
    ///
    /// The depth cap is the opponent's *model* — it is what makes a 1200 miss
    /// what a 2000 sees — so this is a backstop and not a second budget: on any
    /// ordinary position the search finishes on depth and the profile plays at
    /// exactly the strength `HumanizerSelfPlay` measured it at.
    ///
    /// It exists because the opponent runs on a real clock. `runOpponentMove`
    /// bills the whole turn against `opponentClockMs` and flags the opponent
    /// when it runs out, so an unbounded depth-18 search does not merely make
    /// the app feel slow — it can hand the user a win on time that they did not
    /// play for, and then feed that win to the Elo ladder as if they had.
    ///
    /// A share of what is left rather than a flat number, because a flat number
    /// is wrong at both ends: generous enough for the opening and it flags the
    /// opponent in time trouble, tight enough for time trouble and it throttles
    /// the whole game. Taking a twentieth of the remaining clock means the
    /// opponent speeds up as it runs low, which is also what a person does.
    nonisolated static func opponentMoveBudgetMs(clockRemainingMs: Int) -> Int {
        let share = clockRemainingMs / 20
        // The floor can exceed what is left, and deliberately: an opponent with
        // 300ms on the clock is out of time, and pretending otherwise by
        // searching for 15ms would keep a dead game alive.
        return max(500, min(8_000, share))
    }

    private func runOpponentMove() async {
        let profile = humanizer.profile
        let device = await engine.deviceProfile()

        let lease = await engine.acquire(
            .play,
            EngineService.Configuration(
                multiPV: profile.multiPV,
                threads: device.threads,
                hashMB: device.hashMB
            )
        )
        defer { Task { await engine.release(.play, lease) } }

        let history = moves.map(\.uci)
        let started = Date()
        let limit = SearchLimit.depthWithin(
            depth: profile.depth,
            milliseconds: Self.opponentMoveBudgetMs(clockRemainingMs: opponentClockMs)
        )

        do {
            var result = try await engine.search(
                .startPosition(moves: history),
                limit,
                lease
            )

            // A truncated search is a preempted one: it returns fewer and
            // shallower MultiPV lines than the profile asked for. Sampling from
            // those would quietly hand the opponent a different, weaker
            // personality than its rating claims — the humanizer cannot tell a
            // short candidate list from a genuinely forced position. One retry,
            // because whatever preempted it has by now taken the lease and let
            // it go.
            if result.wasTruncated, !Task.isCancelled {
                result = try await engine.search(
                    .startPosition(moves: history),
                    limit,
                    lease
                )
            }

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
                await pause(remaining)
            }
            guard !Task.isCancelled else { return }

            guard
                let move = EngineLANParser.parse(move: selection.move, for: board.position.sideToMove, in: board.position),
                var played = board.move(pieceAt: move.start, to: move.end)
            else { return }

            // The engine names the piece in the fifth character of its UCI
            // string, which `EngineLANParser` has already decoded onto
            // `promotedPiece`.
            played = completePromotionIfNeeded(played, to: move.promotedPiece?.kind ?? .queen)

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
            opponentRetriesUsed = 0

            if let principal = result.principal {
                // Engine scores are side-to-move relative; store from the
                // user's perspective so the eval bar doesn't flip each ply.
                let winPct = winPercent(principal.score)
                currentEvaluation = board.position.sideToMove == configuration.userColor ? winPct : 100 - winPct
            }

            // The opponent's move is complete, so nothing that happens between
            // here and the user's turn is on their clock.
            moveStartedAt = Date()

            if let outcome = terminalOutcome() {
                finish(outcome)
            }
        } catch {
            // A search that fails after the game has ended must not reopen it:
            // every termination cancels this task, and that cancellation is one
            // of the ways the search surfaces as an error.
            guard !isFinished else { return }
            await recoverFromOpponentFailure(error)
        }
    }

    /// Handles an opponent search that threw.
    ///
    /// Setting `.userToMove` here — which is what this used to do — produces a
    /// silently unplayable game: `attemptUserMove` guards on
    /// `phase == .userToMove && userToMove`, and after a failed opponent search
    /// it is still the opponent's turn on the board, so the guard can never
    /// pass. The user is told it is their move and the board refuses every one
    /// of them, with no error and no way forward.
    ///
    /// Engine failures here are overwhelmingly transient — a preempting acquire,
    /// a search timeout — so the first answer is to try again. Only when
    /// retrying keeps failing is the game genuinely unable to continue, and then
    /// it is ended and recorded rather than left hanging.
    private func recoverFromOpponentFailure(_ error: Error) async {
        opponentRetriesUsed += 1

        guard opponentRetriesUsed <= Self.maxOpponentRetries else {
            AppLog.engine.error(
                "Opponent search failed \(Self.maxOpponentRetries, privacy: .public)x; abandoning game \(self.gameID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            // Recorded as a draw with an honest termination. A result invented
            // for either side would enter the rating ladder as evidence about a
            // player who never got to finish.
            finish(
                Outcome(
                    result: "1/2-1/2",
                    termination: GameTermination.unknown.rawValue,
                    userWon: nil
                )
            )
            return
        }

        // Short backoff, off the opponent's clock — the delay is the app's
        // fault, and charging it would flag a player who did nothing wrong.
        await pause(.milliseconds(250))
        guard !Task.isCancelled, !isFinished else { return }
        moveStartedAt = Date()
        await runOpponentMove()
    }

    // MARK: - Guided mode

    /// What the engine saw at the position a guided prompt paused on.
    private struct GuidedProbe {
        var best: UCIInfo
        var secondBest: UCIInfo?
    }

    /// A guided prompt between being answered and being written onto a move.
    private enum PendingGuidedPrompt {
        /// Answered on the sheet; the move it asked about has not been played.
        case awaitingMove(ResolvedGuidedPrompt)
        /// Already graded against the move that answered it, which was then
        /// retracted. The verdict belongs to whatever move replaces it.
        case graded(GuidedPromptOutcome)
    }

    /// One prompt's outcome, in the shape the move row stores it.
    struct GuidedPromptOutcome: Sendable, Equatable {
        var habitID: String
        /// `nil` when the user asked to be shown the method: the move that
        /// followed is then evidence about the coach rather than about them, and
        /// the hit rate drops it instead of counting it as a miss.
        var hit: Bool?
    }

    /// Node budget for the mid-game probes.
    ///
    /// Both of them run between the user's move and the opponent's reply, which
    /// is a latency budget of a few hundred milliseconds for the pair.
    private static let probeNodes = 60_000
    private static let nullMoveProbeNodes = 30_000
    /// Consecutive user moves inspected for the clock-discipline trigger.
    private static let movingFastSampleSize = 3

    private var guidedMode: GuidedMode? {
        configuration.guidedFocusHabit.map { GuidedMode(focusHabit: $0) }
    }

    /// Hands the board back to the user, pausing first if guided mode has a
    /// question worth asking here.
    ///
    /// One funnel for every path that reaches the user's turn, because the probe
    /// has to happen before their clock starts: the pause is the app's idea, and
    /// the search that decides whether to pause is even more so.
    private func handOverToUser() async {
        moveStartedAt = Date()

        guard let pending = await guidedPrompt() else {
            phase = .userToMove
            moveStartedAt = Date()
            return
        }

        guidedPausesUsed += 1
        lastGuidedPausePly = pending.state.ply
        guidedProbe = pending.probe
        phase = .guidedPrompt(pending.state)
        moveStartedAt = Date()
    }

    /// The question to interrupt with, if this position is worth one.
    private func guidedPrompt() async -> (state: GuidedPromptState, probe: GuidedProbe)? {
        guard configuration.guidedEnabled, let mode = guidedMode else { return nil }

        let ply = moves.count + 1

        // The cheap half of the gate, applied before the engine is touched.
        // `GuidedMode.prompt(for:)` re-checks all of it and remains the policy;
        // this is what keeps a two-search probe off every ply of a game that can
        // only be interrupted three times.
        let budget = mode.budget
        guard fullMoveNumber(ply: ply) >= budget.minFullMoveNumber else { return nil }
        guard guidedPausesUsed < budget.maxPausesPerGame else { return nil }
        guard pliesSinceLastGuidedPause(ply: ply) >= budget.minPliesBetweenPauses else { return nil }
        guard userClockMs > budget.minClockMs else { return nil }

        let device = await engine.deviceProfile()
        // The gate compares the best move against the alternative, so a
        // single-line probe cannot produce a criticality gap at all.
        var probeConfiguration = EngineService.Configuration.probe(device: device)
        probeConfiguration.multiPV = 2
        let lease = await engine.acquire(.probe, probeConfiguration)
        defer { Task { await engine.release(.probe, lease) } }

        guard
            let result = try? await engine.search(
                .startPosition(moves: moves.map(\.uci)),
                .nodes(Self.probeNodes),
                lease
            ),
            let best = result.principal
        else { return nil }

        let secondBest = result.line(rank: 2)
        let expectedPoints = EvalMath.expectedPoints(score: best.score)
        let threat = await nullMoveThreat(userExpectedPoints: expectedPoints, lease: lease)

        let context = GuidedMode.Context(
            ply: ply,
            fullMoveNumber: fullMoveNumber(ply: ply),
            userClockMs: userClockMs,
            pausesUsedThisGame: guidedPausesUsed,
            pliesSinceLastPause: pliesSinceLastGuidedPause(ply: ply),
            best: best,
            secondBest: secondBest,
            nullMoveThreatEP: threat?.expectedPoints,
            bestMoveIsQuiet: isQuiet(uci: best.bestMove),
            bestMoveIsProphylactic: parries(uci: best.bestMove, threat: threat?.move),
            phase: AnalysisKit.Phase.classify(position: board.position, ply: ply),
            userExpectedPoints: expectedPoints,
            userIsMovingFast: userIsMovingFast
        )

        guard let prompt = mode.prompt(for: context) else { return nil }

        return (
            GuidedPromptState(habitID: prompt.habit.rawValue, question: prompt.question, ply: prompt.ply),
            GuidedProbe(best: best, secondBest: secondBest)
        )
    }

    /// What the opponent threatens if the user does nothing, in expected points.
    ///
    /// A null-move probe rather than a heuristic, because the question the habit
    /// asks — "what are their threats?" — has no honest answer that does not
    /// involve letting them move twice. Skipped when the user is in check, where
    /// passing produces a position the engine cannot be handed.
    private func nullMoveThreat(
        userExpectedPoints: Double,
        lease: EngineService.Lease?
    ) async -> (expectedPoints: Double, move: String?)? {
        if case .check = board.state { return nil }
        guard
            let fen = Self.nullMoveFEN(board.position.fen),
            let result = try? await engine.search(.fen(fen, moves: []), .nodes(Self.nullMoveProbeNodes), lease),
            let principal = result.principal
        else { return nil }

        // The probe's score belongs to the opponent, who is to move in it.
        let afterPassing = 1 - EvalMath.expectedPoints(score: principal.score)
        return (max(0, userExpectedPoints - afterPassing), principal.bestMove)
    }

    /// The same position with the other side to move.
    ///
    /// The en-passant square goes with the side that could have used it: leaving
    /// it in describes a capture that is not available to the player now on
    /// move, and the engine would search a position that cannot occur.
    nonisolated static func nullMoveFEN(_ fen: String) -> String? {
        var fields = fen.split(separator: " ").map(String.init)
        guard fields.count >= 4 else { return nil }
        switch fields[1] {
        case "w": fields[1] = "b"
        case "b": fields[1] = "w"
        default: return nil
        }
        fields[3] = "-"
        return fields.joined(separator: " ")
    }

    /// Whether a move neither checks, captures nor promotes.
    private func isQuiet(uci: String?) -> Bool {
        guard let uci, let applied = LineReplay.apply(uci: uci, to: board.position) else { return false }
        if case .capture = applied.move.result { return false }
        if applied.move.promotedPiece != nil { return false }
        return applied.move.checkState != .check && applied.move.checkState != .checkmate
    }

    /// Whether the best move answers the threat the null-move probe found, by
    /// taking the piece that makes it or stepping the target out of its way.
    ///
    /// A square comparison rather than a second probe from the position after
    /// the best move: this bit only breaks a tie between two questions, and
    /// doubling the pause's engine cost to break it would be paid on every ply
    /// that reaches the probe at all.
    private func parries(uci: String?, threat: String?) -> Bool {
        guard let uci, let threat, uci.count >= 4, threat.count >= 4 else { return false }
        let from = uci.prefix(2)
        let to = uci.dropFirst(2).prefix(2)
        let threatFrom = threat.prefix(2)
        let threatTo = threat.dropFirst(2).prefix(2)
        return to == threatFrom || from == threatTo
    }

    /// Whether the user's last few moves were all snap judgements.
    private var userIsMovingFast: Bool {
        let control = TimeControl(
            baseSeconds: Double(configuration.baseSeconds),
            incrementSeconds: Double(configuration.incrementSeconds)
        )
        let recent = moves.filter(\.byUser).suffix(Self.movingFastSampleSize)
        guard recent.count == Self.movingFastSampleSize else { return false }
        return recent.allSatisfy { ThinkBucket.classify(thinkTimeMs: $0.thinkTimeMs, control: control) == .fast }
    }

    /// Grades the outstanding prompt, if any, against the move now being played.
    ///
    /// A hit is the move the position asked for: the engine's choice, or a
    /// second-best that is within a hair of it. `GuidedMode.grade` is the
    /// arbiter rather than a bespoke rule here, because the same standard is
    /// what the curriculum's hit rate is defined against — and a move that
    /// throws the game away while technically matching some looser bar would
    /// certify a habit the user does not have.
    private func takeGuidedVerdict(playedUCI: String) -> GuidedPromptOutcome? {
        guard let pending = pendingGuidedPrompt else { return nil }
        pendingGuidedPrompt = nil

        switch pending {
        case .graded(let outcome):
            return outcome
        case .awaitingMove(let resolved):
            // Being shown the method records the interruption and no verdict.
            guard resolved.unaided, let best = resolved.best else {
                return GuidedPromptOutcome(habitID: resolved.habitID, hit: nil)
            }
            let grade = GuidedMode.grade(playedMove: playedUCI, best: best, secondBest: resolved.secondBest)
            return GuidedPromptOutcome(habitID: resolved.habitID, hit: grade > 0)
        }
    }

    /// The move number the side to move is about to play, from a 1-based ply.
    private func fullMoveNumber(ply: Int) -> Int { (ply + 1) / 2 }

    private func pliesSinceLastGuidedPause(ply: Int) -> Int {
        guard let lastGuidedPausePly else { return .max }
        return ply - lastGuidedPausePly
    }

    // MARK: - Helpers

    /// A move's UCI text, including the promotion piece when there is one.
    ///
    /// The suffix is not decoration. `e7e8` is not a legal UCI move — a pawn
    /// arriving on the last rank must name what it became — and this string is
    /// replayed into `position startpos moves …` on every later engine search
    /// and read back by the analysis pass. Written in one place because it was
    /// previously built inline at three call sites, and all three were wrong.
    static func uciText(for move: Move) -> String {
        var text = "\(move.start)\(move.end)"
        if let promoted = move.promotedPiece {
            text += promoted.kind.rawValue.lowercased()
        }
        return text
    }

    /// Finishes a promotion the board is parked on, if it is parked on one.
    ///
    /// `Board.move(pieceAt:to:)` does not promote: a pawn reaching the last rank
    /// leaves `state == .promotion` with the pawn still a pawn, and
    /// `updateState` returns *before* looking for checkmate or draw. Left alone
    /// the board is frozen — no game that reaches a promotion can ever end, the
    /// recorded move list stops being legal UCI, and the engine is handed a
    /// position it will refuse.
    ///
    /// - Returns: the completed move, or the original when nothing was pending.
    private func completePromotionIfNeeded(_ move: Move, to kind: Piece.Kind) -> Move {
        guard case .promotion(let pending) = board.state else { return move }
        return board.completePromotion(of: pending, to: kind)
    }

    private func record(
        move: Move,
        byUser: Bool,
        thinkTimeMs: Int,
        clockAfterMs: Int,
        guided: GuidedPromptOutcome? = nil
    ) {
        moves.append(
            PlayedMove(
                ply: moves.count + 1,
                san: move.san,
                uci: Self.uciText(for: move),
                byUser: byUser,
                thinkTimeMs: thinkTimeMs,
                clockAfterMs: clockAfterMs,
                guidedPromptHabit: guided?.habitID,
                guidedPromptHit: guided.flatMap(\.hit)
            )
        )

        // The one choke point every move that lands passes through exactly
        // once, which is what keeps a single move to a single sound. The
        // opponent's replies sound too: that is the opponent moving rather than
        // the app deciding, and it is the one board change the user may not be
        // looking at. `.stalemate` is deliberately not a check.
        let isCapture = if case .capture = move.result { true } else { false }
        let isCheck = move.checkState == .check || move.checkState == .checkmate
        Sound.play(Sound.outcome(isCapture: isCapture, isCheck: isCheck))
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
        let ladder = self.ladder

        saveTask = Task { [weak self] in
            do {
                try await persistence.save(record)
            } catch {
                self?.recordPersistenceFailure(String(describing: error))
                return
            }

            // The rating moves only once the game is on disk. The Profile chart
            // plots the rating against the games that produced it, and a rating
            // that had advanced for a game nobody can see would be a number with
            // no explanation behind it.
            if let ladder {
                do {
                    try await ladder.apply(record)
                } catch {
                    self?.recordPersistenceFailure(String(describing: error))
                }
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

    func finishedGameRecord(outcome: Outcome) -> FinishedGameRecord {
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
                    clockAfterMs: $0.clockAfterMs,
                    guidedPromptHabit: $0.guidedPromptHabit,
                    guidedPromptHit: $0.guidedPromptHit
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
            isRated: !configuration.secondTryEnabled && !configuration.guidedEnabled,
            ratingWeight: ratingWeight,
            usedAssistedRetry: usedAssistedRetry
        )
    }

    /// How much this game is allowed to move the playing ladder.
    ///
    /// Calibration is excluded outright: `CalibrationModel` already writes the
    /// rating those five games produce, and counting them here would apply the
    /// same evidence twice.
    ///
    /// Everything else counts, because a ladder that only calibration can move
    /// is a frozen number — and the whole app exists to move it. A game with a
    /// coach in it is not worth as much as one without, so anything offering
    /// take-backs or questions comes in at the guided tier, which `EloLadder`
    /// already defines as half K. Inventing a third weight here would put a
    /// tuning constant outside `DomainTuning`, where nobody would find it.
    private var ratingWeight: LadderGameMode? {
        guard configuration.mode != GameMode.calibration.rawValue else { return nil }
        return configuration.secondTryEnabled || configuration.guidedEnabled ? .guided : .sparring
    }

    /// Quick evaluation of whether the just-played move was a blunder worth
    /// interrupting for. Uses a short search — this runs between the user's move
    /// and the opponent's reply, so it has a latency budget of a few hundred ms.
    private func detectBlunder(playedMove: Move, thinkTimeMs: Int) async -> SecondTryState? {
        let device = await engine.deviceProfile()
        let lease = await engine.acquire(.probe, .probe(device: device))
        defer { Task { await engine.release(.probe, lease) } }

        let historyBefore = moves.dropLast().map(\.uci)
        let playedUCI = Self.uciText(for: playedMove)

        do {
            let before = try await engine.search(
                .startPosition(moves: Array(historyBefore)),
                .nodes(Self.probeNodes),
                lease
            )
            let after = try await engine.search(
                .startPosition(moves: Array(historyBefore) + [playedUCI]),
                .nodes(Self.probeNodes),
                lease
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
                refutationArrow: refutation.map { ($0.start, $0.end) },
                thinkTimeMs: thinkTimeMs
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

/// The engine, as one game uses it: a lease, a release, a search, and the
/// device budget the first two are configured from.
///
/// Function values rather than a protocol because `EngineService` is an actor
/// whose lease API is shaped for its own arbitration — priorities, preemption,
/// handoff. A protocol would freeze that shape across every caller, and anything
/// standing in for the engine would have to reimplement a lease it never uses.
/// Wrapping instead also makes the session drivable without Stockfish at all,
/// which matters because `StockfishEngine` is a process-global singleton with a
/// private initialiser: there is no second engine to hand a second game.
struct SessionEngine: Sendable {
    var deviceProfile: @Sendable () async -> EngineService.DeviceProfile
    /// Returns the lease the caller must present when searching. Nil from a
    /// stand-in that arbitrates nothing.
    var acquire: @Sendable (EngineService.Client, EngineService.Configuration) async -> EngineService.Lease?
    var release: @Sendable (EngineService.Client, EngineService.Lease?) async -> Void
    /// The lease is passed rather than assumed, so a search issued after this
    /// game was preempted is refused instead of interleaving with whoever took
    /// the engine — the failure it prevents is two clients' searches arriving on
    /// one UCI loop, which surfaces as an opponent that never moves.
    var search: @Sendable (EnginePosition, SearchLimit, EngineService.Lease?) async throws -> SearchResult

    static func live(_ service: EngineService) -> SessionEngine {
        SessionEngine(
            deviceProfile: { await service.deviceProfile },
            acquire: { client, configuration in
                await service.acquire(client, configuration: configuration)
            },
            release: { client, lease in
                // Release the exact lease when there is one: releasing by client
                // can clear a newer holder's claim if this release lands after
                // someone else has acquired, which `defer { Task { … } }` makes
                // entirely possible.
                if let lease {
                    await service.release(lease)
                } else {
                    await service.release(client)
                }
            },
            search: { position, limit, lease in
                try await service.search(position, limit: limit, lease: lease)
            }
        )
    }
}
