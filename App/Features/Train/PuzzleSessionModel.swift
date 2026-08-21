//
//  PuzzleSessionModel.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import Database
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
        /// The lesson for this set's concept, before its exercise.
        case teaching(TrainingConcept)
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

    /// The board left showing the user's own move after a miss.
    ///
    /// The solve machine refuses a wrong move — correctly, it is not part of
    /// the solution — and the board used to snap the piece back to where it
    /// started. From the user's side that is indistinguishable from the app
    /// ignoring the input: "it literally didn't let me move". The move was
    /// being graded and the banner did appear, but the one piece of feedback
    /// they were looking for — their own move, on the board — never arrived.
    ///
    /// A retry is different and still snaps back: the point of a retry is that
    /// the position is unchanged and they get another go at it.
    private(set) var missPosition: Position?
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
    /// Reads the concept catalogue's progress and finds positions for it.
    /// Optional so the whole session still runs in tests with no store.
    private let database: AppDatabase?
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

    /// The move the puzzle is *about*, the position it is played from, and what
    /// follows it.
    ///
    /// A multi-move puzzle ends with the user playing its *last* move, which is
    /// usually a recapture, and the banner explained that one. So a knight fork
    /// of king and rook three plies earlier was reported as `the knight takes
    /// the rook: nothing defends it`, and the pattern the puzzle exists to
    /// teach was never named. The idea lives in the first move the solver is
    /// asked for; that is the move a solve gets explained through.
    ///
    /// Held from ``beginItem()`` because by the time the banner is built the
    /// machine has been replayed to the end of the line.
    private var keyMove: String?
    private var keyPosition: Position?
    private var keyContinuation: [String] = []

    init(
        driver: any PuzzleSessionDriver,
        focus: WeeklyFocus? = nil,
        evaluator: (any PuzzleMoveEvaluator)? = nil,
        database: AppDatabase? = AppDatabase.sharedIfAvailable,
        soloConcept: TrainingConcept? = nil,
        concept: ConceptScheduler.Selection? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.driver = driver
        self.weeklyFocus = focus
        self.evaluator = evaluator
        self.database = database
        self.soloConcept = soloConcept
        self.injectedConcept = concept
        self.clock = clock
    }

    /// A concept handed in rather than scheduled, so the set's shape can be
    /// tested without a store behind it. The driver and the evaluator are
    /// injected the same way and for the same reason.
    private let injectedConcept: ConceptScheduler.Selection?

    /// Set when the user asked to revisit one concept rather than play a set.
    ///
    /// Choosing what to *practise next* stays with the app; choosing to go back
    /// over something already taught is a different decision and a reasonable
    /// one — it is the only way to see a lesson twice.
    private let soloConcept: TrainingConcept?

    // MARK: Concept slot

    /// The one opening, endgame or positional idea this set carries.
    ///
    /// Chosen by ``ConceptScheduler`` rather than by the user — see that type
    /// for why the choice is not offered. Nil when the store is unavailable or
    /// the catalogue has nothing at this rating, in which case the set is
    /// simply the puzzles, which is what it always used to be.
    private(set) var conceptSelection: ConceptScheduler.Selection?
    /// The position the concept's exercise is played from, once resolved.
    private var conceptExercise: PuzzleSolveMachine?
    /// True while the board is showing the concept exercise rather than a
    /// puzzle from the queue, so grading goes to the concept and not the SRS.
    private(set) var isConceptItem = false
    private var conceptDone = false

    /// An endgame drill the finished set wants the user to play.
    ///
    /// Surfaced rather than launched here: the drill has its own screen and its
    /// own model, and the session cover is not the place to host a second one.
    /// The Train screen reads this when the cover closes.
    private(set) var pendingDrill: EndgameDrillKind?

    /// What the header shows in place of `3 / 10` while the concept is up.
    var progressLabel: String? {
        guard isConceptItem, let concept = conceptSelection?.concept else { return nil }
        return concept.family.label
    }

    /// The lesson currently on screen, if any.
    var teachingConcept: TrainingConcept? {
        if case .teaching(let concept) = stage { return concept }
        return nil
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

        // A revisit: no queue, no grading, just the idea again.
        if let soloConcept {
            startedAt = clock()
            progress.total = 1
            conceptSelection = ConceptScheduler.Selection(concept: soloConcept, teachFirst: true)
            beginConcept()
            return
        }

        await loadConcept()
        startedAt = clock()

        await driver.startSession(focus: focus ?? weeklyFocus)

        if let failure = driver.loadFailure {
            stage = .unavailable(failure)
            return
        }

        baselineRating = driver.puzzleRating
        progress.total = driver.queueCount

        // The concept goes first.
        //
        // It used to close the set, on the reasoning that the puzzles are what
        // the user came for. The effect was that almost nobody ever saw one:
        // reaching it meant finishing all ten puzzles in a sitting, and a set
        // abandoned at puzzle four — which is most of them — taught nothing at
        // all. Opening with it also puts the idea in front of the tactics
        // rather than after them, which is the order it is useful in.
        if conceptSelection != nil, !conceptDone {
            beginConcept()
            return
        }

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
        missPosition = nil
        keyMove = machine.expectedMove
        keyPosition = machine.board.position
        keyContinuation = machine.continuationAfterExpected
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
    var position: Position? { missPosition ?? machineSnapshot?.board.position }

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
        // An opening is not a search. "Find the best move" is the right
        // instruction for a tactic and the wrong one for a line you were taught
        // ninety seconds ago and are now rehearsing — there is nothing to find.
        //
        // A positional exercise keeps the neutral wording. The user has just
        // been taught the idea, but the point is still to *see* it in a
        // position, and naming it above the board would turn the exercise into
        // a lookup — which is the same reason the task line never names a
        // puzzle's theme.
        if isConceptItem, let concept = conceptSelection?.concept,
            case .line = concept.exercise
        {
            return "\(concept.title) — play your moves in order."
        }
        return orientation == .white
            ? "White to play — find the best move."
            : "Black to play — find the best move."
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

        case .retry:
            grade(uci: uci)
            return .rejected(reason: nil)

        case .failed:
            // Accepted so the board plays it, and held on screen underneath the
            // verdict. The answer arrow is drawn from the move's own squares
            // rather than from the position, so it still reads correctly over
            // the board the user actually produced.
            var shown = current.board
            PuzzleSolveMachine.move(uci: uci, on: &shown)
            missPosition = shown.position
            grade(uci: uci)
            return .accepted

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
        if isConceptItem {
            await submitConcept(uci: uci)
            return
        }
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
                answeredFrom: before.board.position,
                continuation: before.continuationAfterExpected
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
            answeredFrom: before.board.position,
            continuation: before.continuationAfterExpected
        )
    }

    // MARK: Verdict

    /// - Parameter answeredFrom: the position the answer is played *from*.
    ///   Passed in rather than read from ``machineSnapshot``, because a solve
    ///   advances that snapshot past the move before this runs — the explanation
    ///   would then describe the position after the answer, which is the one
    ///   position in which the answer is not available.
    /// - Parameter continuation: the rest of the stored line after ``expected``,
    ///   opponent's reply first. The puzzle already knows how the opponent's
    ///   best defence is refuted; without this the banner explained the answer
    ///   as though the position ended with it.
    private func completeItem(
        plan: SessionItemPlan,
        solvedUnaided: Bool,
        played: String?,
        expected: String?,
        answeredFrom: Position?,
        continuation: [String] = []
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

        // A solve is explained through the move the puzzle is about; a miss
        // through the move that was actually missed, which is the one the user
        // was standing in front of when it went wrong.
        let explains = solvedUnaided ? keyMove ?? expected : expected
        let explainedFrom = solvedUnaided ? keyPosition ?? answeredFrom : answeredFrom
        let explainedLine = solvedUnaided ? keyContinuation : continuation

        // The ring lands on the square that ends the story: the answer's
        // destination when the answer is what we are showing, the user's own
        // destination when they played something and it was wrong.
        //
        // With one exception. A solved multi-move puzzle is now explained
        // through its *key* move while the board is frozen on the final
        // position, so a ring on the last move's square points at one square
        // while the sentence talks about another. Ringing the key square
        // instead is no better — by the end of the line the piece that went
        // there has usually moved on, so the ring would draw the eye to
        // whatever happens to be standing on it now. On a solve the ring is
        // decoration anyway; its real job is showing a missed answer. So it is
        // dropped where it would contradict the words, and kept everywhere it
        // still agrees with them.
        let ringSquare: Square?
        if solvedUnaided {
            ringSquare = explains == expected ? PuzzleConcept.destination(ofUCI: expected) : nil
        } else {
            ringSquare = PuzzleConcept.destination(ofUCI: played)
                ?? PuzzleConcept.destination(ofUCI: expected)
        }

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
                    answer: explains,
                    position: explainedFrom,
                    mistake: provenMistake,
                    continuation: explainedLine
                ),
                ring: ringSquare.map { BoardRing(square: $0, tone: solvedUnaided ? .correct : .wrong) },
                answer: solvedUnaided ? nil : expected
            )
        )

        // A solve is explained too.
        //
        // The engine used to run only on a miss, on the reasoning that a solved
        // puzzle needs no feedback. But solving a puzzle you did not understand
        // leaves you exactly as unable to find the idea again as missing it
        // does, and the board can justify an answer outright only when it is
        // mate, a fork, or a capture that statically wins. Everything else —
        // every sacrifice, every deflection, and every position mined from the
        // user's own game, which carries no stored line at all — ended at
        // `the rook takes the knight` with the reason left unsaid.
        if solvedUnaided {
            guard let explains, let explainedFrom,
                explainedLine.isEmpty,
                PuzzleReason.needsTheLine(answer: explains, in: explainedFrom)
            else { return }

            explainTask = Task { [weak self] in
                await self?.explainSolve(theme: theme, answer: explains, from: explainedFrom)
            }
            return
        }

        // Most wrong moves hang nothing — they are simply not the best, and the
        // board alone cannot say why. That is the case the engine exists for.
        guard provenMistake == nil,
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

    /// Grows a solved puzzle's sentence into the reason the move worked.
    ///
    /// Same progressive reveal as the miss path, and for the same reason: the
    /// verdict is already on screen, and this either improves it a moment later
    /// or leaves it alone.
    private func explainSolve(theme: ThemeTag, answer: String, from position: Position) async {
        guard let evaluator else { return }

        let line = await evaluator.continuation(fen: position.fen, playing: answer)
        guard !line.isEmpty else { return }

        let message = PuzzleConcept.verdictMessage(
            solved: true,
            theme: theme,
            answer: answer,
            position: position,
            continuation: line
        )

        // The user may have tapped Continue while the engine was thinking.
        guard case .verdict(let current) = stage, current.solved else { return }
        // Nothing learned: rewriting the banner with the sentence it already
        // shows would be a crossfade to itself.
        guard message != current.message else { return }

        var upgraded = current
        upgraded.message = message
        withAnimation(Motion.crossfade) { stage = .verdict(upgraded) }
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

        // The concept has just been answered, so the puzzles are what is left.
        if isConceptItem {
            isConceptItem = false
            conceptExercise = nil
        }

        if driver.isSessionFinished || driver.itemOnScreen == nil {
            finishSession()
            return
        }
        beginItem()
    }

    /// Picks this set's concept and resolves the position it will be shown on.
    ///
    /// Failure here is deliberately quiet: a set with no concept is still a
    /// perfectly good set of puzzles, and a user whose store is unavailable
    /// should not be shown an error about a slot they never asked for.
    private func loadConcept() async {
        if let injectedConcept {
            conceptSelection = injectedConcept
            return
        }
        guard let database else { return }
        let rating = Int(driver.puzzleRating.rounded())

        let selection = await Task.detached(priority: .userInitiated) { () -> ConceptScheduler.Selection? in
            let stored = (try? database.concepts.all()) ?? []
            let states = Dictionary(
                stored.map {
                    (
                        $0.id,
                        ConceptScheduler.State(
                            id: $0.id,
                            isIntroduced: $0.introducedAt != nil,
                            timesSeen: $0.timesSeen,
                            lastSeenAt: $0.lastSeenAt
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            return ConceptScheduler.next(rating: rating, states: states)
        }.value

        conceptSelection = selection
    }

    /// Moves from the puzzles to the set's concept, or to the summary when
    /// there is nothing to teach.
    private func beginConcept() {
        guard let selection = conceptSelection, !conceptDone else {
            abandonConcept()
            return
        }

        // Taught the first time, exercised afterwards. A technique tested
        // before it has been explained is not a test, it is a guess.
        if selection.teachFirst {
            machineSnapshot = nil
            planOnScreen = nil
            liveRing = nil
            hintMove = nil
            lastOpponentMove = nil
            stage = .teaching(selection.concept)
            markIntroduced(selection.concept)
            return
        }
        beginConceptExercise()
    }

    /// Starts the exercise for the concept on screen.
    func beginConceptExercise() {
        guard let selection = conceptSelection else {
            abandonConcept()
            return
        }

        switch selection.concept.exercise {
        case .drill(let kind):
            // A drill needs its own screen and its own twenty moves, so it
            // cannot run inline the way a line or a position can. The lesson
            // has been read; the drill itself is handed to the Train tab when
            // the set closes, and the puzzles carry on in between.
            pendingDrill = kind
            conceptDone = true
            isConceptItem = false
            if driver.isSessionFinished || driver.itemOnScreen == nil {
                finishSession()
            } else {
                beginItem()
            }

        case .line(let fen, let moves, let opponentMovesFirst):
            guard
                var machine = PuzzleSolveMachine(
                    fen: fen,
                    line: moves,
                    opponentMovesFirst: opponentMovesFirst,
                    retryPolicy: .allowRetries(1)
                )
            else {
                abandonConcept()
                return
            }
            machine.start()
            present(conceptMachine: machine, opponentMovesFirst: opponentMovesFirst)

        case .corpusFeature(let feature):
            Task { [weak self] in await self?.presentCorpusConcept(feature: feature) }
        }
    }

    /// Gives up on the concept and gets on with the puzzles.
    ///
    /// A concept that cannot be built is a disappointment, not a failure of the
    /// set — and before the slot moved to the front, this path ended the whole
    /// session before a single puzzle had been served.
    private func abandonConcept() {
        conceptDone = true
        isConceptItem = false
        if driver.isSessionFinished || driver.itemOnScreen == nil {
            finishSession()
        } else {
            beginItem()
        }
    }

    private func present(conceptMachine machine: PuzzleSolveMachine, opponentMovesFirst: Bool) {
        conceptExercise = machine
        machineSnapshot = machine
        missPosition = nil
        planOnScreen = nil
        isConceptItem = true
        orientation = machine.board.position.sideToMove
        liveRing = nil
        hintMove = nil
        lastOpponentMove = opponentMovesFirst ? MovePair(uci: machine.line.first) : nil
        stage = .solving
    }

    /// Finds a corpus position that actually contains the idea being taught.
    ///
    /// Positions are searched rather than stored because a positional exercise
    /// cannot be authored — see ``PositionalFeatureDetector``. If nothing in
    /// the sample matches, the set ends rather than showing a position that
    /// does not demonstrate the concept.
    private func presentCorpusConcept(feature: PositionalFeature) async {
        guard let database else {
            abandonConcept()
            return
        }
        let rating = Int(driver.puzzleRating.rounded())

        let found = await Task.detached(priority: .userInitiated) { () -> (String, [String])? in
            let band = max(600, rating - 300)...(rating + 400)
            guard let corpus = database.puzzleQueries else { return nil }
            let candidates = (try? corpus.puzzles(
                ratingRange: band,
                themes: ThemeMask([.quietMove]),
                limit: 60
            )) ?? []

            for puzzle in candidates {
                let line = puzzle.moveList
                guard line.count >= 2, let start = Position(fen: puzzle.fen) else { continue }
                var board = Board(position: start)
                guard PuzzleSolveMachine.move(uci: line[0], on: &board) != nil else { continue }
                if PositionalFeatureDetector.matches(feature, uci: line[1], in: board.position) {
                    return (puzzle.fen, line)
                }
            }
            return nil
        }.value

        guard let found,
            var machine = PuzzleSolveMachine(
                fen: found.0,
                line: found.1,
                opponentMovesFirst: true,
                retryPolicy: .allowRetries(1)
            )
        else {
            abandonConcept()
            return
        }
        machine.start()
        present(conceptMachine: machine, opponentMovesFirst: true)
    }

    /// Grades the concept exercise. Deliberately *not* through the driver: a
    /// concept is not an SRS card and must not move a puzzle rating.
    private func submitConcept(uci: String) async {
        guard let machine = conceptExercise, let selection = conceptSelection else { return }

        var probe = machine
        let outcome = probe.play(uci: uci)
        guard outcome != .illegal else { return }
        conceptExercise = probe
        machineSnapshot = probe

        switch outcome {
        case let .advanced(reply):
            liveRing = PuzzleConcept.destination(ofUCI: uci).map { BoardRing(square: $0, tone: .correct) }
            lastOpponentMove = MovePair(uci: reply)

        case .retry:
            liveRing = PuzzleConcept.destination(ofUCI: uci).map { BoardRing(square: $0, tone: .wrong) }

        case .solved, .failed:
            let solved = outcome == .solved
            recordConceptAttempt(selection.concept, correct: solved)
            conceptDone = true
            // `isConceptItem` deliberately stays true until the session moves
            // on. Clearing it here dropped the header back to "1 / 1" and the
            // task line back to "find the best move" the instant the banner
            // appeared — so the one screen where the concept's name matters
            // most stopped saying it. `conceptDone` is what routes the session
            // onward, so nothing else depends on this being cleared early.

            let expected = solved ? uci : machine.expectedMove
            let from = machine.board.position
            stage = .verdict(
                Verdict(
                    solved: solved,
                    message: PuzzleConcept.conceptMessage(
                        solved: solved,
                        concept: selection.concept,
                        answer: expected,
                        position: from
                    ),
                    ring: PuzzleConcept.destination(ofUCI: expected)
                        .map { BoardRing(square: $0, tone: solved ? .correct : .wrong) },
                    answer: solved ? nil : expected
                )
            )

        case .illegal:
            break
        }
    }

    private func markIntroduced(_ concept: TrainingConcept) {
        guard let database else { return }
        let id = concept.id
        Task.detached(priority: .utility) {
            try? database.concepts.markIntroduced(id: id)
        }
    }

    private func recordConceptAttempt(_ concept: TrainingConcept, correct: Bool) {
        guard let database else { return }
        let id = concept.id
        Task.detached(priority: .utility) {
            try? database.concepts.recordAttempt(id: id, correct: correct)
        }
    }

    private func finishSession() {
        missPosition = nil
        progress.total = driver.queueCount
        progress.elapsed = startedAt.map { clock().timeIntervalSince($0) } ?? 0
        progress.ratingDelta = Int((driver.puzzleRating - baselineRating).rounded())
        machineSnapshot = nil
        planOnScreen = nil
        stage = .summary
    }
}
