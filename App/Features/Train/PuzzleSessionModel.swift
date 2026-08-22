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

    /// How much of the answer the user has asked for.
    ///
    /// A ladder rather than a switch, so the first tap can prune the search
    /// instead of ending it. See ``revealHint()``.
    enum HintLevel: Sendable, Equatable {
        case none
        /// A sentence about what kind of move the answer is, naming no move.
        case nudge
        /// The move itself, as an arrow on the board.
        case answer
    }

    private(set) var hintLevel: HintLevel = .none
    /// The nudge on screen, if the user has asked for one.
    private(set) var hintText: String?
    /// The answer, fetched with the first rung and drawn only on the last.
    private var pendingAnswer: String?

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

    /// When the current stretch of solving began, or `nil` while the session is
    /// paused. See ``pauseClock()``.
    private var startedAt: Date?
    /// Time from earlier stretches, already banked.
    private var bankedElapsed: TimeInterval = 0
    /// Whether the session has ever run, so a stray resume cannot start a clock
    /// for a set that was never opened.
    private var clockHasStarted = false
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
        teachesConcept: Bool = true,
        isCalculationSet: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.driver = driver
        self.weeklyFocus = focus
        self.evaluator = evaluator
        self.database = database
        self.soloConcept = soloConcept
        self.injectedConcept = concept
        // A calculation set never opens with a lesson, whatever the caller
        // asked for. It is priced at three puzzles and twelve minutes on the
        // button that opened it, and a lesson plus its exercise in front of them
        // would be two or three minutes the user was not told about — on the one
        // set whose whole premise is that the time is spent on the position.
        self.teachesConcept = teachesConcept && !isCalculationSet
        self.isCalculationSet = isCalculationSet
        self.clock = clock
    }

    /// Whether this is the calculation set rather than the daily queue.
    ///
    /// The model has to know, and not only to pick the right load call: the task
    /// line, the header note and the message an empty queue leaves behind all say
    /// something different here, and every one of them would be a lie carried
    /// over from the daily set if this were inferred from the queue's contents.
    let isCalculationSet: Bool

    /// Whether this set may open with a lesson the scheduler chose.
    ///
    /// False when the user named the subject on the way in — tapping a rating
    /// leak is a request for *that* leak, and answering it with whatever concept
    /// was next in the rotation puts an unrelated lesson between the button and
    /// what the button promised. The scheduler's turn comes round on the next
    /// ordinary set; it does not need this one.
    private let teachesConcept: Bool

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
    /// The concept exercise's own setup move, so the screen can animate it in
    /// the same way a corpus puzzle's is animated.
    private var conceptSetupMove: (position: Position, from: Square, to: Square)?
    /// True while the board is showing the concept exercise rather than a
    /// puzzle from the queue, so grading goes to the concept and not the SRS.
    private(set) var isConceptItem = false
    private var conceptDone = false
    /// Whether the concept's exercise was actually answered, as opposed to
    /// abandoned because it could not be built. The two both set
    /// ``conceptDone``, and only one of them is worth telling the user about.
    private var conceptAttempted = false

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

    // MARK: The session clock

    /// Time spent on this set, counted only while it was on screen.
    ///
    /// The summary reports it as `Time`, and a wall-clock reading answers a
    /// question nobody asked: a set interrupted by a phone call reported twenty
    /// minutes for four minutes of solving, which makes the one number on that
    /// screen measuring effort useless for judging whether the set was rushed.
    private var elapsedSoFar: TimeInterval {
        bankedElapsed + (startedAt.map { clock().timeIntervalSince($0) } ?? 0)
    }

    private func startClock() {
        clockHasStarted = true
        bankedElapsed = 0
        startedAt = clock()
    }

    /// Banks the time so far and stops counting. Called when the app leaves the
    /// foreground; solving cannot continue there, so neither should the clock.
    func pauseClock() {
        guard let startedAt else { return }
        bankedElapsed += clock().timeIntervalSince(startedAt)
        self.startedAt = nil
    }

    /// Starts counting again. A no-op for a set that has finished or was never
    /// opened, so a foreground notification cannot start a clock of its own.
    func resumeClock() {
        guard clockHasStarted, startedAt == nil, stage != .summary else { return }
        startedAt = clock()
    }

    // MARK: Lifecycle

    func start(focus: WeeklyFocus? = nil) async {
        guard stage == .idle else { return }
        stage = .loading

        // A revisit: no queue, no grading, just the idea again.
        if let soloConcept {
            startClock()
            progress.total = 1
            conceptSelection = ConceptScheduler.Selection(concept: soloConcept, teachFirst: true)
            beginConcept()
            return
        }

        await loadConcept()
        startClock()

        if isCalculationSet {
            await driver.startCalculationSet()
        } else {
            await driver.startSession(focus: focus ?? weeklyFocus)
        }

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
        conceptSetupMove = nil
        keyMove = machine.expectedMove
        keyPosition = machine.board.position
        keyContinuation = machine.continuationAfterExpected
        // Read once, from the position the user is asked to solve — after the
        // setup move, before any answer — and held for the whole item.
        orientation = machine.board.position.sideToMove
        clearHint()
        liveRing = nil
        lastOpponentMove = item.presented.item.opponentMovesFirst ? MovePair(uci: item.presented.line.first) : nil
        progress.index = driver.currentIndex
        progress.total = driver.queueCount
        stage = .solving
        // The position is on screen now. The screen calls this again once the
        // setup move has finished animating; until then this is the honest
        // reading for an item that has none.
        driver.markItemShown()
    }

    /// What the setup animation keys off: a new value means a new position.
    ///
    /// The plan's id for a puzzle, the concept's own id for the exercise slot.
    /// Keying off `planOnScreen` alone meant the concept exercise — which has
    /// no plan — never triggered the animation at all.
    var itemIdentity: String? {
        if isConceptItem { return conceptSelection.map { "concept:\($0.concept.id)" } }
        return planOnScreen?.id.uuidString
    }

    /// The board is now the user's to act on.
    ///
    /// Called by the screen after the opponent's setup move has animated in,
    /// which is the first instant the user could have played anything. Anything
    /// measured before it is the app's own animation, and a latency that
    /// includes it is a latency `AutoGrader` will read as slower recall than
    /// actually happened.
    func markPositionInteractive() {
        guard case .solving = stage, !isConceptItem else { return }
        driver.markItemShown()
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

        let side = orientation == .white ? "White" : "Black"

        // A same-day retry is *appended* to the queue when the planned items
        // run out, so a set promised as ten finishes at twelve and the counter
        // goes 10 / 10 → 11 / 12 with nothing on screen to account for the two
        // extra. Naming the item is what gives the denominator a visible cause;
        // it also says why this position looks familiar.
        if let plan = planOnScreen, case .relearn = plan.kind {
            return "Second look — you missed this one earlier. \(side) to play."
        }

        // The calculation set changes the instruction, not the information.
        //
        // "Find the best move" is a search the user is expected to end quickly,
        // and on a position 200 points above them the honest instruction is the
        // opposite one: keep going until the line is finished. It still names no
        // theme, for the reason in this property's own header — and the two
        // standing facts about the mode live in ``modeNote`` instead, so this
        // line stays one line and the board keeps its height.
        if isCalculationSet {
            return "\(side) to play — work the whole line out before you move."
        }

        return "\(side) to play — find the best move."
    }

    /// What the header says this set is, above the task line.
    ///
    /// Nil for the daily set, which names its weekly habit there instead. The
    /// calculation set has no habit to name and two things to say that the task
    /// line should not have to repeat on every puzzle: where these came from,
    /// and that nothing is being timed. The second is not decoration — the daily
    /// set grades a correct answer under ten seconds as recognition, so a user
    /// who has been trained by it will assume a fast answer is wanted here too
    /// unless told otherwise.
    var modeNote: String? {
        isCalculationSet ? "Calculation set — above your rating band, no clock" : nil
    }

    /// The opponent's setup move, so the view can animate it in before handing
    /// the board over. `nil` for a position mined from the user's own game,
    /// which is already the moment they went wrong.
    var setupMove: (position: Position, from: Square, to: Square)? {
        // A concept exercise has no plan behind it — it is not an SRS card —
        // so it keeps its own copy, captured before the machine was started.
        if isConceptItem { return conceptSetupMove }
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
            // The piece snapping back and an orange ring are, on their own,
            // indistinguishable from a mis-drop the board refused to read. The
            // item still has a try left, and saying so is the difference
            // between "it didn't let me move" and "that was wrong, go again".
            return .rejected(reason: "Not that one — one more try.")

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
            // A new move to find, so the ladder starts again — see
            // ``revealHint()`` for why the item is not charged twice.
            rearmHint()
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

    /// Hands out help one rung at a time.
    ///
    /// ## Why the answer is not the first thing offered
    ///
    /// It used to be: one tap drew the arrow, and a stuck user's only two
    /// options — give up, or be shown the move — both ended the attempt without
    /// exercising the search that finding it would have. The first tap now buys
    /// a sentence describing what *kind* of move the answer is (see
    /// ``PuzzleReason/nudge(forAnswer:in:)``), which prunes the search without
    /// finishing it; the second draws the arrow.
    ///
    /// ## Both rungs cost the same
    ///
    /// The answer is fetched from the driver on the *first* tap and held back
    /// until the second, so asking for a nudge records the hint exactly as
    /// asking for the arrow does — `AutoGrader` grades any hint `.again`, and
    /// the button's label says so. A free rung would be a way to buy
    /// information the summary never reports. Pricing the rungs apart is worth
    /// doing and cannot be done here: `PuzzleAttempt.usedHint` is a `Bool` in
    /// `TrainingCore`, so telling the grader "nudged" from "shown" needs that
    /// type to carry a level.
    ///
    /// ## The ladder is per move, not per item
    ///
    /// A multi-move puzzle asks for two or three moves under one attempt. The
    /// ladder used to be charged once and then left at ``HintLevel/answer`` for
    /// the rest of the item — and the button is disabled on exactly that — so a
    /// user who needed help finding the first move was refused it for every
    /// move after it, in the half of the line they had never seen. The attempt
    /// is already lost by then (``usedHintOnItem`` is what the summary and
    /// `AutoGrader` read, and it is set once), so withholding the rest only
    /// hides information the user has already paid for.
    func revealHint() {
        guard stage == .solving, hintLevel != .answer else { return }

        if pendingAnswer == nil {
            // A concept exercise is not an SRS card and is not graded through
            // the driver at all; asking the driver for its hint would hand back
            // the *next puzzle's* move, over a completely different position.
            pendingAnswer = isConceptItem ? conceptExercise?.expectedMove : driver.revealHint()
        }
        usedHintOnItem = true

        if hintLevel == .none,
            let nudge = PuzzleReason.nudge(forAnswer: pendingAnswer, in: machineSnapshot?.board.position)
        {
            hintLevel = .nudge
            hintText = nudge
            return
        }

        guard let move = pendingAnswer else { return }
        hintLevel = .answer
        hintMove = move
    }

    /// Resets the ladder for a new position.
    private func clearHint() {
        rearmHint()
        usedHintOnItem = false
    }

    /// Resets the ladder for the *next move of the same item*.
    ///
    /// Deliberately leaves ``usedHintOnItem`` alone: the attempt was spent the
    /// moment the first rung was bought, and a multi-move line must not be able
    /// to launder that away by advancing.
    private func rearmHint() {
        hintMove = nil
        hintText = nil
        hintLevel = .none
        pendingAnswer = nil
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
        // A relearn item is the same-day retry of a card failed earlier in this
        // set, so it is counted on its own row. Adding it to `Solved n/N` mixed
        // first recall with re-recall of an answer the user had been shown
        // minutes before.
        if case .relearn = plan.kind {
            progress.retries += 1
            if solvedUnaided { progress.retriesSolved += 1 }
        } else if solvedUnaided {
            progress.solved += 1
        }
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
        // Whether the move on the board *is* the puzzle's own answer.
        //
        // A hint makes `solvedUnaided` false — the answer was on screen, so
        // nothing after it is evidence of recall — but it does not make the
        // move wrong, and everything below used `solvedUnaided` as a proxy for
        // "the user played something else". A hinted Qxh7+ therefore came back
        // as `Missed — the queen takes the pawn: … But your queen could be
        // taken by the king`: the app criticising the answer it had just handed
        // over. Where the board could prove nothing it was worse — the engine
        // was asked to compare the move against itself, and a gap of zero reads
        // as `yours was just as good`.
        let playedTheAnswer = played != nil && played == expected
        // A hinted solve is explained the same way an unaided one is: through
        // the move the puzzle is *about*, not through whichever move happened
        // to end the line.
        let explainsTheAnswer = solvedUnaided || playedTheAnswer

        let explains = explainsTheAnswer ? keyMove ?? expected : expected
        let explainedFrom = explainsTheAnswer ? keyPosition ?? answeredFrom : answeredFrom
        let explainedLine = explainsTheAnswer ? keyContinuation : continuation

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
        //
        // A hinted solve is the same case one step further on: there is no
        // missed answer to point at, because the user played it. Marking their
        // own move in the miss tone would be the ring arguing with the board.
        let ringSquare: Square?
        if explainsTheAnswer {
            ringSquare = solvedUnaided && explains == expected
                ? PuzzleConcept.destination(ofUCI: expected)
                : nil
        } else {
            ringSquare = PuzzleConcept.destination(ofUCI: played)
                ?? PuzzleConcept.destination(ofUCI: expected)
        }

        // The board can often prove the mistake outright — a piece left where
        // something cheaper takes it. That answer is free and instant.
        let provenMistake = explainsTheAnswer
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
                answer: explainsTheAnswer ? nil : expected
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
        if explainsTheAnswer {
            guard let explains, let explainedFrom,
                explainedLine.isEmpty,
                PuzzleReason.needsTheLine(answer: explains, in: explainedFrom)
            else { return }

            let solved = solvedUnaided
            explainTask = Task { [weak self] in
                await self?.explainSolve(
                    solved: solved,
                    theme: theme,
                    answer: explains,
                    from: explainedFrom
                )
            }
            return
        }

        // Most wrong moves hang nothing — they are simply not the best, and the
        // board alone cannot say why. That is the case the engine exists for.
        guard provenMistake == nil,
            let played, let expected, let answeredFrom
        else { return }

        // A corpus puzzle's answer is the only move that holds the result; a
        // position mined from the user's own game carries whatever the analysis
        // pass liked best. `PuzzleMoveComparison` needs to know which, because
        // only the second one can honestly be told it had an equal.
        let answerIsForced = plan.presented.item.puzzleID != nil

        let cardID = plan.kind.cardID

        explainTask = Task { [weak self] in
            await self?.explainWithEngine(
                theme: theme,
                answer: expected,
                played: played,
                from: answeredFrom,
                continuation: explainedLine,
                answerIsForced: answerIsForced,
                cardID: cardID
            )
        }
    }

    /// Grows a solved puzzle's sentence into the reason the move worked.
    ///
    /// Same progressive reveal as the miss path, and for the same reason: the
    /// verdict is already on screen, and this either improves it a moment later
    /// or leaves it alone.
    /// - Parameter solved: whether the banner this upgrades says `Solved`. A
    ///   hinted solve says `Missed` — the answer was on screen, so the attempt
    ///   proved nothing — but it is still the *answer* being explained, and it
    ///   is the reader who most needs the explanation.
    private func explainSolve(
        solved: Bool,
        theme: ThemeTag,
        answer: String,
        from position: Position
    ) async {
        guard let evaluator else { return }

        let line = await evaluator.continuation(fen: position.fen, playing: answer)
        guard !line.isEmpty else { return }

        let message = PuzzleConcept.verdictMessage(
            solved: solved,
            theme: theme,
            answer: answer,
            position: position,
            continuation: line
        )

        // The user may have tapped Continue while the engine was thinking.
        guard case .verdict(let current) = stage, current.solved == solved else { return }
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
    ///
    /// ## One question at a time
    ///
    /// These used to run as `async let` siblings. `EngineService` fronts a
    /// single Stockfish process and acquiring the probe lease stops whatever is
    /// running, so the two searches did not overlap — the second one killed the
    /// first, which came back either as `LeaseError.expired` or as a handful of
    /// milliseconds of nodes. The usual outcome was no clause at all, and the
    /// occasional one was a full search compared against a stopped one. Asking
    /// sequentially costs a few hundred milliseconds behind a banner that is
    /// already on screen and is the only way either answer means anything.
    ///
    /// - Parameters:
    ///   - continuation: the rest of the stored line after `answer`. Carried in
    ///     rather than recomputed because the first banner was built with it —
    ///     it is what produces *if they take back, the rook goes to d1 with
    ///     check and you win the queen* — and rebuilding without it replaced a
    ///     sentence that showed the mechanism with one that did not.
    ///   - answerIsForced: see ``PuzzleMoveComparison/verdict(answer:played:answerIsForced:)``.
    ///   - cardID: the review card behind the item, when there is one. Carried
    ///     so the same-day retry can be withdrawn if the engine ends up rating
    ///     the user's move the equal of the stored answer.
    private func explainWithEngine(
        theme: ThemeTag,
        answer: String,
        played: String,
        from position: Position,
        continuation: [String],
        answerIsForced: Bool,
        cardID: SRSCard.ID?
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

        let answerEval = await evaluate(answer)
        let playedEval = await evaluate(played)
        guard let verdict = PuzzleMoveComparison.verdict(
            answer: answerEval,
            played: playedEval,
            answerIsForced: answerIsForced
        ) else { return }

        // The banner is about to say the position cannot tell the two moves
        // apart. Serving the position again in the same set would then be the
        // app asking for the stored move specifically, minutes after telling
        // the user it has no advantage over theirs.
        if verdict == .equivalent, let cardID {
            driver.creditEquivalentAnswer(cardID: cardID)
        }

        func banner(mistake: String) -> String {
            PuzzleConcept.verdictMessage(
                solved: false,
                theme: theme,
                answer: answer,
                position: position,
                mistake: mistake,
                continuation: continuation
            )
        }

        var message = banner(mistake: verdict.phrase)

        // The band names the damage and never names the move that does it. So
        // when the position says the played move really is worse, spend one
        // more search on how the opponent answers it: *after your move, their
        // knight takes the rook* is the check the user failed to make, and the
        // band phrase alone can only teach them to trust a score.
        //
        // It *replaces* the band rather than joining it, for two reasons. The
        // banner reserves a fixed four lines and cannot truncate — the sentence
        // is the whole feature — so the two clauses share one budget; and of
        // the two this is the half worth keeping, because "worse off" is a
        // judgement the reader has to take on trust while "their knight takes
        // the rook" is a move they can put on the board and check.
        //
        // Only on a genuinely worse move. Attaching a refutation to one the
        // engine rates equal would invent a punishment for a move that has
        // none.
        if case .worse = verdict {
            let reply = await evaluator.continuation(fen: fen, playing: played).first
            if let reply,
                let punishment = PuzzleReason.punishment(reply: reply, afterPlaying: played, in: position)
            {
                // Where the answer's own explanation has already spent the
                // budget — a stored line ending "if they take back, the rook
                // goes to d1 with check and you win the queen" — the reader
                // already has a mechanism in front of them, and the band is the
                // honest short form of what is left to say.
                let richer = banner(mistake: "after your move, \(punishment)")
                if richer.count <= ResultBanner.messageBudget { message = richer }
            }
        }

        // The user may have tapped Continue while the engine was thinking; the
        // banner this was written for is gone and rewriting it would flash a
        // sentence about the previous puzzle over the next one.
        guard case .verdict(let current) = stage, !current.solved else { return }

        var upgraded = current
        upgraded.message = message
        withAnimation(Motion.crossfade) { stage = .verdict(upgraded) }
    }

    /// Dismisses the banner and moves on.
    func continueAfterVerdict() {
        guard case .verdict = stage else { return }
        // Whatever the engine was about to say is about a puzzle the user has
        // finished with.
        explainTask?.cancel()
        liveRing = nil
        clearHint()

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

    /// The window the opening-pressure read uses.
    ///
    /// The same one `r3.opening` gates on, so the slot and the ladder are
    /// reading the same twelve games.
    private static let openingPressureWindow = MetricWindow.lastGames(12)

    /// Picks this set's concept and resolves the position it will be shown on.
    ///
    /// Failure here is deliberately quiet: a set with no concept is still a
    /// perfectly good set of puzzles, and a user whose store is unavailable
    /// should not be shown an error about a slot they never asked for.
    ///
    /// Only reached when no concept was handed in. `TrainHomeModel` resolves the
    /// slot a screen earlier so its card can price the set, and passes the
    /// answer down — so in the shipping path the focus and opening-pressure
    /// arguments below bite only on a session that had to resolve its own.
    private func loadConcept() async {
        guard teachesConcept else { return }
        if let injectedConcept {
            conceptSelection = injectedConcept
            return
        }
        guard let database else { return }
        let rating = Int(driver.puzzleRating.rounded())
        let habit = weeklyFocus?.habit
        let openingWindow = Self.openingPressureWindow.key

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
            // The family the previous set used, so this one can differ. Derived
            // from the stored rows rather than kept as its own setting: the
            // most recently seen concept *is* the last one served, and reading
            // it back costs nothing. Passing nil — which is what this call site
            // did — made `ConceptScheduler`'s rotation filter a no-op, so a set
            // could follow an endgame with another endgame indefinitely.
            let lastFamily = stored
                .compactMap { row -> (Date, TrainingConcept.Family)? in
                    guard let seenAt = row.lastSeenAt,
                        let concept = TrainingConcept.concept(id: row.id)
                    else { return nil }
                    return (seenAt, concept.family)
                }
                .max { $0.0 < $1.0 }?
                .1

            // How badly the opening is actually going, from the user's own
            // games. The slot otherwise rotates through eighteen concepts
            // regardless of the evidence, so a player losing every game out of
            // the opening waits eighteen sessions for the family to come round.
            // Absent — no analysed games yet — reads as zero pressure, which
            // leaves the rotation exactly as it was.
            let openingMistakes = (try? database.metrics.metric(
                key: MetricKey.openingMistakesPerGame.rawValue,
                window: openingWindow
            ))?.value ?? 0

            return ConceptScheduler.next(
                rating: rating,
                states: states,
                lastFamily: lastFamily,
                focus: habit,
                openingMistakesPerGame: openingMistakes
            )
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
            clearHint()
            lastOpponentMove = nil
            stage = .teaching(selection.concept)
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

        // Recorded here rather than when the lesson appears on screen.
        //
        // A concept marked taught on sight is one an interrupted session never
        // shows again: the cover has a close button on every stage, so a lesson
        // opened at the wrong moment and dismissed came back the next day as an
        // exercise for a line the user had never read. This is the first point
        // at which the lesson has actually been read to the end — it is what
        // the lesson's own button ("Got it" / "Play the line" / "Try it") does.
        // The write is idempotent, so the already-taught path costs nothing.
        markIntroduced(selection.concept)

        switch selection.concept.exercise {
        case .drill(let kind):
            // A drill needs its own screen and its own twenty moves, so it
            // cannot run inline the way a line or a position can. The lesson
            // has been read; the drill itself is handed to the Train tab when
            // the set closes, and the puzzles carry on in between.
            pendingDrill = kind
            conceptDone = true
            isConceptItem = false
            // Record the serving here, because this is the last point that knows
            // a concept was involved: the drill leaves for its own screen and
            // `recordConceptAttempt` is never reached for this branch. Without
            // it `timesSeen` stays at zero for every drill concept, and since
            // `ConceptScheduler` breaks ties on fewest-seen-then-least-recent, a
            // drill concept then wins every tie-break forever — freezing the
            // concept slot of every future session onto one drill.
            markSeen(selection.concept)
            if driver.isSessionFinished || driver.itemOnScreen == nil {
                finishSession()
            } else {
                beginItem()
            }

        case .line(let fen, let moves, let opponentMovesFirst):
            guard
                let machine = PuzzleSolveMachine(
                    fen: fen,
                    line: moves,
                    opponentMovesFirst: opponentMovesFirst,
                    retryPolicy: .allowRetries(1)
                )
            else {
                abandonConcept()
                return
            }
            present(conceptMachine: machine)

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

    /// Puts a concept exercise on the board.
    ///
    /// Takes the machine *before* ``PuzzleSolveMachine/start()`` has run,
    /// because starting it is what plays the opponent's setup move — and the
    /// position before that move is the only thing the screen has to animate
    /// from. It used to be started at the call site, so by the time this ran
    /// the pre-setup position was already gone and ``setupMove`` had nothing to
    /// return. The concept exercise was then the one place in the app that
    /// dropped the user into a position with the move that created it already
    /// played, which `PuzzleSessionScreen` calls the classic puzzle-app mistake
    /// in its own header.
    private func present(conceptMachine machine: PuzzleSolveMachine) {
        var started = machine
        let before = started.board.position
        let setup = started.start()

        // A line that will not replay leaves the machine at `.ready` with no
        // expected move; running the exercise anyway would ask the user to
        // solve a position with no answer.
        guard started.phase != .ready else {
            abandonConcept()
            return
        }

        conceptExercise = started
        machineSnapshot = started
        conceptSetupMove = setup.flatMap { uci in
            MovePair(uci: uci).map { (position: before, from: $0.from, to: $0.to) }
        }
        missPosition = nil
        planOnScreen = nil
        isConceptItem = true
        orientation = started.board.position.sideToMove
        liveRing = nil
        clearHint()
        lastOpponentMove = setup.flatMap { MovePair(uci: $0) }
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

        // Two plies and no more: the opponent's setup move, then the one move
        // that demonstrates the idea.
        //
        // A Lichess `quietMove` puzzle usually carries several forced tactical
        // plies after the quiet move, and the exercise used to require all of
        // them. So a user who had just read "The outpost" had to find the
        // outpost *and* the tactic that follows it, and `submitConcept`
        // explained a failure anywhere in that tail with the outpost's own cue
        // — pairing the idea being taught with a move that is not it. The
        // attempt `ConceptScheduler` records was measuring the tail as much as
        // the idea. Truncating makes the exercise test what the lesson taught.
        guard let found,
            let machine = PuzzleSolveMachine(
                fen: found.0,
                line: Array(found.1.prefix(2)),
                opponentMovesFirst: true,
                retryPolicy: .allowRetries(1)
            )
        else {
            abandonConcept()
            return
        }
        present(conceptMachine: machine)
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
            rearmHint()
            liveRing = PuzzleConcept.destination(ofUCI: uci).map { BoardRing(square: $0, tone: .correct) }
            lastOpponentMove = MovePair(uci: reply)

        case .retry:
            liveRing = PuzzleConcept.destination(ofUCI: uci).map { BoardRing(square: $0, tone: .wrong) }

        case .solved, .failed:
            let solved = outcome == .solved
            recordConceptAttempt(selection.concept, correct: solved)
            conceptDone = true
            conceptAttempted = true

            // A revisit is a one-item session: the concept *is* the queue, so
            // it has to move the counter. Left at zero, the banner offered
            // "Next" when the next tap was the summary, and that summary then
            // reported `Solved 0/1` for an exercise the user had just played.
            //
            // A full set counts nothing here on purpose. The concept sits
            // outside `driver.queueCount`, so adding it would push `completed`
            // one ahead of the queue and label the ninth puzzle as the tenth.
            if soloConcept != nil {
                progress.completed += 1
                if solved { progress.solved += 1 }
                if usedHintOnItem { progress.hinted += 1 }
            }
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

    /// Records that a concept was served without claiming it was passed.
    ///
    /// Used for the drill branch, which hands its exercise to another screen and
    /// so never learns the outcome. See `ConceptRepository.markSeen`.
    private func markSeen(_ concept: TrainingConcept) {
        guard let database else { return }
        let id = concept.id
        Task.detached(priority: .utility) {
            try? database.concepts.markSeen(id: id)
        }
    }

    private func finishSession() {
        missPosition = nil
        progress.total = driver.queueCount
        progress.elapsed = elapsedSoFar
        // The set is over, so nothing further is counted — a summary left on
        // screen must not keep adding to the number it is reporting.
        pauseClock()
        progress.ratingDelta = Int((driver.puzzleRating - baselineRating).rounded())
        progress.ratingDeviation = driver.puzzleRatingDeviation
        machineSnapshot = nil
        planOnScreen = nil

        // Nothing was served at all — no puzzle, no exercise, no drill to hand
        // on. The summary is the wrong screen for that: `displayTotal` floors
        // the denominator at one, so an empty set reported `Solved 0/1`, which
        // reads as a puzzle the user was shown and missed. Say what happened
        // instead.
        if progress.completed == 0, progress.total == 0, pendingDrill == nil {
            stage = .unavailable(emptyMessage)
            return
        }

        stage = .summary
    }

    /// What a set that served nothing has to say for itself.
    private var emptyMessage: String {
        if soloConcept != nil { return Self.exerciseUnavailable }
        // The daily set's message offers the one thing that refills its band —
        // playing a game, which mines positions regardless of the corpus. That
        // is no help at all here: the calculation band is defined *above* the
        // user's rating and a mined position is never in it, so pointing at it
        // would hand a stuck user an action that cannot work.
        if isCalculationSet { return Self.emptyCalculationBand }
        // The lesson and its exercise came first and did happen. Leaving that
        // out would tell a user who has just worked through one that nothing
        // ran.
        if conceptAttempted { return "\(Self.emptyBand) The exercise you just played still counts." }
        return Self.emptyBand
    }

    /// The raised band came back empty.
    ///
    /// Says which band and why it is empty rather than "no puzzles today". The
    /// two causes a user can actually be in are a corpus that stops below them
    /// and an exclusion window that has just eaten the band, and both are
    /// answered by the same fact: this set only ever draws from above.
    private static let emptyCalculationBand =
        "The corpus has nothing left rated above your puzzle rating that you have not already seen, "
        + "so there is no calculation set to serve. Your daily set is unaffected."

    /// The corpus came back with nothing inside the serving band.
    ///
    /// Named for the cause and paired with the one thing that changes it: a
    /// game the user plays mines its own positions, which is the only source
    /// that does not depend on the band having anything left in it.
    private static let emptyBand =
        "There are no puzzles left in your rating band today. Playing a game adds positions "
        + "from your own mistakes, which are served regardless of the band."

    /// A revisit whose exercise could not be built.
    private static let exerciseUnavailable =
        "This concept's exercise could not be built from the corpus right now. "
        + "The lesson is still on the training list."
}
