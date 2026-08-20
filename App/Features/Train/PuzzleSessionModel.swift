//
//  PuzzleSessionModel.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import Foundation
import Observation
import SwiftUI
import TrainingCore

/// A ring drawn round a destination square.
///
/// Duolingo's chess course annotates the *destination* rather than washing the
/// whole square, and it is the right call: a tinted square dims the piece
/// standing on it, which is exactly the piece the user needs to read. A ring
/// leaves the piece untouched.
struct BoardRing: Sendable, Hashable {

    enum Tone: Sendable, Hashable {
        case correct
        case wrong
    }

    var square: Square
    var tone: Tone
}

/// The two squares a move touched.
struct MovePair: Sendable, Hashable {
    var from: Square
    var to: Square

    init?(uci: String?) {
        guard
            let from = PuzzleConcept.origin(ofUCI: uci),
            let to = PuzzleConcept.destination(ofUCI: uci)
        else { return nil }
        self.from = from
        self.to = to
    }
}

/// Drives the solve surface: one puzzle at a time, a result banner between them,
/// and a summary at the end.
///
/// ## Why the banner needs its own stage
///
/// `TrainingService` grades, persists and **advances** in one call — by the time
/// `offer(uci:)` returns, the next puzzle is already the current item. That is
/// the right shape for a service, and the wrong shape for a screen that has to
/// show the user what just happened. So this model keeps its own frozen copy of
/// the finished position (``machineSnapshot``) and holds the board on it until
/// the user taps Continue. Nothing is rolled back; the service is simply one
/// item ahead of the view for the length of the banner.
@MainActor
@Observable
final class PuzzleSessionModel {

    // MARK: Stage

    enum Stage: Equatable {
        case idle
        case loading
        case solving
        /// The board is frozen on the finished position and the banner is up.
        case verdict(Verdict)
        case summary
        /// The session could not be built — no corpus, no database.
        case unavailable(String)
    }

    /// Everything the result banner renders.
    ///
    /// One struct for both outcomes, with `solved` selecting the tint and the
    /// glyph and *nothing else*. See ``ResultBanner`` for why that matters.
    struct Verdict: Equatable, Sendable {
        var solved: Bool
        var message: String
        var ring: BoardRing?
        /// Drawn on a miss so the user leaves knowing the move.
        var answer: String?
    }

    // MARK: Observable state

    private(set) var stage: Stage = .idle
    private(set) var progress = SessionProgress()
    private(set) var missed: [MissedItem] = []

    /// The position on screen. Frozen during a verdict.
    private(set) var machineSnapshot: PuzzleSolveMachine?
    private(set) var planOnScreen: SessionItemPlan?

    /// Hint arrow, once revealed. Drawn in grey, never in the accent colour:
    /// a hint is a concession, not a recommendation.
    private(set) var hintMove: String?

    /// Ring shown while solving a multi-move line — green as each correct move
    /// lands, orange on a retry that did not end the attempt.
    private(set) var liveRing: BoardRing?

    /// The opponent's most recent move — the setup move, then each auto-played
    /// reply. Highlighted because in a multi-move line the user has to see what
    /// the opponent just did before they can find the next move.
    private(set) var lastOpponentMove: MovePair?

    // MARK: Dependencies

    private let driver: any PuzzleSessionDriver
    private let clock: @Sendable () -> Date
    /// Judges a wrong move the board cannot explain. Optional: with no engine
    /// the banner simply keeps the shorter sentence.
    private let evaluator: (any PuzzleMoveEvaluator)?
    /// The in-flight explanation, retained so it can be cancelled when the user
    /// moves on and so tests can wait for it.
    private var explainTask: Task<Void, Never>?

    /// The week's habit, applied when the session is assembled.
    ///
    /// Held from construction rather than handed to ``start(focus:)`` at the
    /// call site, because the screen starts the session from a `.task` and a
    /// `.task` takes no arguments. Without it the whole leak → habit → drill
    /// pipeline is computed, stored, shown on Today, and then dropped on the
    /// floor: `SessionAssembler.mix` reads a `nil` focus as "no theme bias" and
    /// serves a general session, so the week's work never reaches a puzzle.
    private let weeklyFocus: WeeklyFocus?

    private var startedAt: Date?
    private var baselineRating: Double = 0
    /// The in-flight grade for the move just accepted.
    ///
    /// Retained so there is only ever one — and so tests can wait for it, which
    /// is the only way to assert on a flow whose first half is synchronous (the
    /// board's answer) and whose second half is not (the service's grade).
    private var gradingTask: Task<Void, Never>?
    /// Whether the item on screen has had its answer revealed. Reset per item,
    /// because a hint invalidates the *attempt*, not the session.
    private var usedHintOnItem = false

    init(
        driver: any PuzzleSessionDriver,
        focus: WeeklyFocus? = nil,
        evaluator: (any PuzzleMoveEvaluator)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.driver = driver
        self.weeklyFocus = focus
        self.evaluator = evaluator
        self.clock = clock
    }

    /// Waits for the engine's explanation of the move just played.
    ///
    /// Exists for tests, like ``waitForGrading()``: the banner is already on
    /// screen by the time this is running, and the UI never waits on it.
    func waitForExplanation() async {
        await explainTask?.value
    }

    // MARK: Lifecycle

    func start(focus: WeeklyFocus? = nil) async {
        guard stage == .idle else { return }
        stage = .loading
        startedAt = clock()

        await driver.startSession(focus: focus ?? weeklyFocus)

        if let failure = driver.loadFailure {
            stage = .unavailable(failure)
            return
        }

        baselineRating = driver.puzzleRating
        progress.total = driver.queueCount

        guard !driver.isSessionFinished, driver.itemOnScreen != nil else {
            finishSession()
            return
        }
        beginItem()
    }

    private func beginItem() {
        guard let item = driver.itemOnScreen, let machine = driver.solveMachine else {
            finishSession()
            return
        }
        planOnScreen = item
        machineSnapshot = machine
        // Read once, from the position the user is asked to solve — after the
        // setup move, before any answer — and held for the whole item.
        orientation = machine.board.position.sideToMove
        hintMove = nil
        liveRing = nil
        lastOpponentMove = item.presented.item.opponentMovesFirst ? MovePair(uci: item.presented.line.first) : nil
        usedHintOnItem = false
        progress.index = driver.currentIndex
        progress.total = driver.queueCount
        stage = .solving
    }

    // MARK: Board input

    /// The position the board renders.
    var position: Position? { machineSnapshot?.board.position }

    /// The puzzle is always shown from the solver's side.
    ///
    /// Pinned when the item begins rather than read from the live position.
    /// `sideToMove` flips with every move played, so deriving orientation from
    /// it spun the board the instant an answer landed — the user solved a
    /// puzzle and watched the board rotate underneath the result banner, before
    /// the next puzzle had even been asked for. The side you are solving for is
    /// a property of the *item*, not of whose turn it happens to be mid-line.
    private(set) var orientation: Piece.Color = .white

    /// The one line above the board.
    ///
    /// Names the side to move and nothing else. The obvious enrichment is to add
    /// the puzzle's theme — "White to play, find the fork" — and it is the one
    /// thing this line must never do: the theme *is* the answer, and a tactic
    /// you have been told the name of is a lookup rather than a search.
    var taskLine: String {
        orientation == .white ? "White to play — find the best move." : "Black to play — find the best move."
    }

    /// The opponent's setup move, so the view can animate it in before handing
    /// the board over. `nil` for a position mined from the user's own game,
    /// which is already the moment they went wrong.
    var setupMove: (position: Position, from: Square, to: Square)? {
        guard let plan = planOnScreen,
            plan.presented.item.opponentMovesFirst,
            let uci = plan.presented.line.first,
            let before = Position(fen: plan.presented.fen),
            let from = PuzzleConcept.origin(ofUCI: uci),
            let to = PuzzleConcept.destination(ofUCI: uci)
        else { return nil }
        return (before, from, to)
    }

    /// Answers a move attempt from the board.
    ///
    /// Decided synchronously against a **local copy** of the solve machine, so
    /// the piece either stays or snaps back on the same frame as the drop. The
    /// copy is a value type and the machine is deterministic, so this can never
    /// disagree with what the service decides a moment later.
    func attemptMove(from: Square, to: Square, promotion: Piece.Kind? = nil) -> MoveAcceptance {
        guard stage == .solving, let current = machineSnapshot else { return .rejected }

        // Asked *before* the move is judged, not after it fails. A four-letter
        // promotion move is perfectly legal — `PuzzleSolveMachine` reads a
        // missing suffix as a queen — so a promotion to anything else would be
        // silently graded as a wrong answer if the picker came up late.
        if promotion == nil, isPromotion(from: from, to: to, in: current.board.position) {
            return .needsPromotion(complete: { [weak self] kind in
                self?.attemptMove(from: from, to: to, promotion: kind) ?? .rejected
            })
        }

        let suffix = promotion.map { $0.rawValue.lowercased() } ?? ""
        let uci = from.notation + to.notation + suffix

        var probe = current
        let outcome = probe.play(uci: uci)

        switch outcome {
        case .illegal:
            return .rejected

        case .retry, .failed:
            grade(uci: uci)
            return .rejected(reason: nil)

        case .advanced, .solved:
            grade(uci: uci)
            return .accepted
        }
    }

    private func isPromotion(from: Square, to: Square, in position: Position) -> Bool {
        guard let piece = position.piece(at: from), piece.kind == .pawn else { return false }
        return to.rank.value == 8 || to.rank.value == 1
    }

    private func grade(uci: String) {
        gradingTask = Task { [weak self] in await self?.submit(uci: uci) }
    }

    /// Waits for the grade of the move just played.
    ///
    /// Exists for tests. The UI never calls it: the board has already answered
    /// by the time this is running, and blocking on it would serialise the
    /// animation behind a database write.
    func waitForGrading() async {
        await gradingTask?.value
    }

    /// Grades a move: forwards it to the service and updates the screen.
    private func submit(uci: String) async {
        guard stage == .solving, let plan = planOnScreen, let before = machineSnapshot else { return }

        var probe = before
        let outcome = probe.play(uci: uci)
        guard outcome != .illegal else { return }

        // The service persists and advances; the local probe is what the screen
        // renders until Continue is tapped.
        await driver.offer(uci: uci)

        switch outcome {
        case let .advanced(reply):
            machineSnapshot = probe
            liveRing = PuzzleConcept.destination(ofUCI: uci).map { BoardRing(square: $0, tone: .correct) }
            lastOpponentMove = MovePair(uci: reply)

        case .retry:
            // The machine refuses the move, so the board is unchanged; the ring
            // marks where the user tried to go.
            liveRing = PuzzleConcept.destination(ofUCI: uci).map { BoardRing(square: $0, tone: .wrong) }

        case .solved:
            machineSnapshot = probe
            completeItem(
                plan: plan,
                solvedUnaided: !usedHintOnItem,
                played: uci,
                expected: uci,
                answeredFrom: before.board.position
            )

        case .failed:
            completeItem(
                plan: plan,
                solvedUnaided: false,
                played: uci,
                expected: before.expectedMove,
                answeredFrom: before.board.position
            )

        case .illegal:
            break
        }
    }

    // MARK: Hint and skip

    /// Reveals the move as a thin grey arrow. The attempt is already lost —
    /// `AutoGrader` grades any hint `.again` — and the summary counts it.
    func revealHint() {
        guard stage == .solving, !usedHintOnItem else { return }
        guard let move = driver.revealHint() else { return }
        usedHintOnItem = true
        hintMove = move
    }

    /// Gives up on the current puzzle. Graded as a failure, because it is one:
    /// the position was on screen and the move was not found.
    func skip() async {
        guard stage == .solving, let plan = planOnScreen, let before = machineSnapshot else { return }
        let expected = before.expectedMove
        await driver.skipCurrent()
        completeItem(
            plan: plan,
            solvedUnaided: false,
            played: nil,
            expected: expected,
            answeredFrom: before.board.position
        )
    }

    // MARK: Verdict

    /// - Parameter answeredFrom: the position the answer is played *from*.
    ///   Passed in rather than read from ``machineSnapshot``, because a solve
    ///   advances that snapshot past the move before this runs — the explanation
    ///   would then describe the position after the answer, which is the one
    ///   position in which the answer is not available.
    private func completeItem(
        plan: SessionItemPlan,
        solvedUnaided: Bool,
        played: String?,
        expected: String?,
        answeredFrom: Position?
    ) {
        progress.completed += 1
        progress.total = driver.queueCount
        if solvedUnaided { progress.solved += 1 }
        if usedHintOnItem { progress.hinted += 1 }

        let theme = plan.presented.item.primaryTheme
        if !solvedUnaided {
            missed.append(
                MissedItem(
                    concept: PuzzleConcept.chipLabel(theme: theme, answer: expected),
                    expected: expected
                )
            )
        }

        // The ring lands on the square that ends the story: the answer's
        // destination when the answer is what we are showing, the user's own
        // destination when they played something and it was wrong.
        let ringSquare =
            solvedUnaided
            ? PuzzleConcept.destination(ofUCI: expected)
            : PuzzleConcept.destination(ofUCI: played) ?? PuzzleConcept.destination(ofUCI: expected)

        // The board can often prove the mistake outright — a piece left where
        // something cheaper takes it. That answer is free and instant.
        let provenMistake = solvedUnaided
            ? nil
            : PuzzleReason.mistake(inMove: played, from: answeredFrom)

        stage = .verdict(
            Verdict(
                solved: solvedUnaided,
                message: PuzzleConcept.verdictMessage(
                    solved: solvedUnaided,
                    theme: theme,
                    answer: expected,
                    position: answeredFrom,
                    mistake: provenMistake
                ),
                ring: ringSquare.map { BoardRing(square: $0, tone: solvedUnaided ? .correct : .wrong) },
                answer: solvedUnaided ? nil : expected
            )
        )

        // Most wrong moves hang nothing — they are simply not the best, and the
        // board alone cannot say why. That is the case the engine exists for.
        guard !solvedUnaided, provenMistake == nil,
            let played, let expected, let answeredFrom
        else { return }

        explainTask = Task { [weak self] in
            await self?.explainWithEngine(
                theme: theme,
                answer: expected,
                played: played,
                from: answeredFrom
            )
        }
    }

    /// Upgrades the banner once the engine has judged both moves.
    ///
    /// Deliberately *after* the verdict is already on screen. Blocking the
    /// banner on two searches would put a spinner between the user's move and
    /// any feedback at all, to add one clause — the wrong trade. So the sentence
    /// appears immediately and grows a tail if the engine has something to say,
    /// which is the same progressive reveal the Today screen uses for its rung.
    private func explainWithEngine(
        theme: ThemeTag,
        answer: String,
        played: String,
        from position: Position
    ) async {
        guard let evaluator else { return }
        let fen = position.fen

        /// A move that ends the game is scored from the board; only the rest
        /// need the engine.
        func evaluate(_ uci: String) async -> PuzzleEvaluation? {
            if let terminal = PuzzleEvaluation.terminal(playing: uci, in: position) {
                return terminal
            }
            return await evaluator.evaluate(fen: fen, playing: uci)
        }

        async let answerEval = evaluate(answer)
        async let playedEval = evaluate(played)
        guard let clause = await PuzzleMoveComparison.clause(
            answer: answerEval,
            played: playedEval
        ) else { return }

        // The user may have tapped Continue while the engine was thinking; the
        // banner this was written for is gone and rewriting it would flash a
        // sentence about the previous puzzle over the next one.
        guard case .verdict(let current) = stage, !current.solved else { return }

        var upgraded = current
        upgraded.message = PuzzleConcept.verdictMessage(
            solved: false,
            theme: theme,
            answer: answer,
            position: position,
            mistake: clause
        )
        withAnimation(Motion.crossfade) { stage = .verdict(upgraded) }
    }

    /// Dismisses the banner and moves on.
    func continueAfterVerdict() {
        guard case .verdict = stage else { return }
        // Whatever the engine was about to say is about a puzzle the user has
        // finished with.
        explainTask?.cancel()
        liveRing = nil
        hintMove = nil

        if driver.isSessionFinished || driver.itemOnScreen == nil {
            finishSession()
            return
        }
        beginItem()
    }

    private func finishSession() {
        progress.total = driver.queueCount
        progress.elapsed = startedAt.map { clock().timeIntervalSince($0) } ?? 0
        progress.ratingDelta = Int((driver.puzzleRating - baselineRating).rounded())
        machineSnapshot = nil
        planOnScreen = nil
        stage = .summary
    }
}
