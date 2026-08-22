//
//  TrainSessionTests.swift
//  ChessCoachTests
//

import BoardUI
import ChessKit
import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// MARK: - Fixtures

/// The standard opening position, used as a puzzle FEN.
///
/// A real corpus row would be a tactic; for these tests the only properties that
/// matter are that the FEN parses and that the line replays, and the start
/// position gives both without smuggling in a chess claim the test would then be
/// asserting by accident.
private let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

private func makePlan(
    line: [String],
    fen: String = startFEN,
    theme: ThemeTag = .fork,
    rating: Int = 1200,
    kind: SessionItemPlan.Kind = .fresh
) -> SessionItemPlan {
    let item = SolvableItem(
        backing: .corpusPuzzle(id: UUID().uuidString),
        fen: fen,
        line: line,
        opponentMovesFirst: true,
        rating: rating,
        primaryTheme: theme
    )
    return SessionItemPlan(kind: kind, presented: PresentedPuzzle(item: item, preferring: .identity))
}

/// A `PuzzleSessionDriver` with the same advance-on-completion behaviour as
/// `TrainingService`, and none of its I/O.
@MainActor
private final class FakeDriver: PuzzleSessionDriver {

    var plans: [SessionItemPlan]
    var puzzleRating: Double = 1000
    var puzzleRatingDeviation: Double = 0
    var loadFailure: String?
    /// Rating change applied on every graded item, so the summary's delta has
    /// something to report.
    var ratingStepPerItem: Double = 0
    /// A stand-in for the clock `TrainingService` restarts on `markItemShown()`.
    /// Recorded rather than measured so the latency test stays deterministic.
    private(set) var itemShownCount = 0

    private(set) var currentIndex = 0
    private(set) var solveMachine: PuzzleSolveMachine?
    private(set) var hintsRequested = 0
    /// Which entry point the model actually called. Recorded because the two
    /// build different queues, and a model that asked for the wrong one would
    /// otherwise pass every assertion about the queue it was handed.
    private(set) var startedCalculationSet = false

    init(plans: [SessionItemPlan]) {
        self.plans = plans
    }

    var queueCount: Int { plans.count }
    var itemOnScreen: SessionItemPlan? { plans.indices.contains(currentIndex) ? plans[currentIndex] : nil }
    var isSessionFinished: Bool { currentIndex >= plans.count }

    func startSession(focus: WeeklyFocus?) async {
        currentIndex = 0
        begin()
    }

    func startCalculationSet() async {
        startedCalculationSet = true
        currentIndex = 0
        begin()
    }

    private func begin() {
        guard let plan = itemOnScreen else {
            solveMachine = nil
            return
        }
        var machine = plan.presented.machine(retryPolicy: plan.retryPolicy)
        machine?.start()
        solveMachine = machine
    }

    func markItemShown() { itemShownCount += 1 }

    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult {
        guard var machine = solveMachine else { return .illegal }
        let result = machine.play(uci: uci)
        solveMachine = machine
        switch result {
        case .solved, .failed:
            puzzleRating += ratingStepPerItem
            advance()
        case .advanced, .retry, .illegal:
            break
        }
        return result
    }

    func revealHint() -> String? {
        hintsRequested += 1
        guard var machine = solveMachine else { return nil }
        let move = machine.revealHint()
        solveMachine = machine
        return move
    }

    func skipCurrent() async {
        puzzleRating += ratingStepPerItem
        advance()
    }

    /// Cards whose same-day retry the model asked to have withdrawn.
    private(set) var equivalentCredits: [SRSCard.ID] = []

    func creditEquivalentAnswer(cardID: SRSCard.ID) {
        equivalentCredits.append(cardID)
    }

    private func advance() {
        currentIndex += 1
        begin()
    }
}

extension PuzzleSessionModel.Stage {
    fileprivate var verdict: PuzzleSessionModel.Verdict? {
        if case let .verdict(verdict) = self { return verdict }
        return nil
    }
}

// MARK: - Progress accounting

@Suite("Session progress")
struct SessionProgressTests {

    @Test("The counter names the puzzle on screen, not the number finished")
    func counterTracksTheItemOnScreen() {
        // Third puzzle up, two answered.
        let progress = SessionProgress(index: 2, completed: 2, total: 10)
        #expect(progress.counterLabel == "3 / 10")
    }

    @Test("The hairline bar reflects completed items")
    func fractionUsesCompleted() {
        #expect(SessionProgress(index: 0, completed: 0, total: 10).fraction == 0)
        #expect(SessionProgress(index: 4, completed: 5, total: 10).fraction == 0.5)
        #expect(SessionProgress(index: 9, completed: 10, total: 10).fraction == 1)
    }

    /// The queue grows when same-day retries are appended, and for one frame the
    /// service's item index is ahead of the queue it came from.
    @Test("A finished count above the queue length never shows a fraction over 1")
    func denominatorSurvivesAGrowingQueue() {
        let progress = SessionProgress(index: 10, completed: 11, total: 10)
        #expect(progress.displayTotal == 11)
        #expect(progress.fraction == 1)
        #expect(progress.counterLabel == "11 / 11")
    }

    @Test("A queue of nothing does not divide by zero")
    func emptyQueue() {
        let progress = SessionProgress()
        #expect(progress.displayTotal == 1)
        #expect(progress.fraction == 0)
    }

    @Test("Summary values are formatted for a monospaced column")
    func summaryFormatting() {
        let progress = SessionProgress(
            index: 9,
            completed: 10,
            total: 10,
            solved: 8,
            hinted: 1,
            elapsed: 252,
            ratingDelta: 12
        )
        #expect(progress.solvedLabel == "8/10")
        #expect(progress.hintsLabel == "1")
        #expect(progress.timeLabel == "04:12")
        #expect(progress.ratingLabel == "+12")
    }

    @Test("A negative delta keeps its sign and a zero delta is not dressed up")
    func ratingLabelSigns() {
        #expect(SessionProgress(ratingDelta: -4).ratingLabel == "-4")
        #expect(SessionProgress(ratingDelta: 0).ratingLabel == "0")
    }

    @Test("Times under a minute are zero-padded so the column does not jump")
    func shortTimes() {
        #expect(SessionProgress(elapsed: 9).timeLabel == "00:09")
        #expect(SessionProgress(elapsed: 61).timeLabel == "01:01")
    }
}

// MARK: - Verdict copy

@Suite("Verdict copy")
struct VerdictCopyTests {

    /// The failure banner must not be able to grow relative to the success
    /// banner. The strongest cheap guard is that both sentences are built by one
    /// function and differ only in the opening verb.
    @Test("Success and failure produce the same sentence shape")
    func sameShape() {
        let missed = PuzzleConcept.verdictMessage(solved: false, theme: .pin, answer: "d1f3")
        let solved = PuzzleConcept.verdictMessage(solved: true, theme: .pin, answer: "d1f3")

        #expect(missed == "Missed — the pin was on the f-file.")
        #expect(solved == "Solved — the pin was on the f-file.")
        #expect(missed.dropFirst("Missed".count) == solved.dropFirst("Solved".count))
    }

    @Test("Copy never consoles")
    func noConsolation() {
        let missed = PuzzleConcept.verdictMessage(solved: false, theme: .fork, answer: "c4f7")
        for banned in ["Don't worry", "Nice try", "Almost", "!", "Incorrect"] {
            #expect(!missed.contains(banned))
        }
    }

    @Test("A theme with no idea worth naming falls back to the square")
    func metadataThemeFallsBack() {
        let message = PuzzleConcept.verdictMessage(solved: false, theme: ThemeTag("crushing"), answer: "g1f3")
        #expect(message == "Missed — the move was to f3.")
    }

    /// Named *and* defined. "the idea was a skewer" is a word used at a reader
    /// who is here to learn what the word means.
    @Test("With no answer to point at, the concept is still named and defined")
    func noAnswer() {
        #expect(
            PuzzleConcept.verdictMessage(solved: false, theme: .skewer, answer: nil)
                == "Missed — the idea was a skewer — the valuable piece has to move, "
                    + "and the one behind it falls."
        )
    }
}

// MARK: - Solve interaction

@MainActor
@Suite("Puzzle session model")
struct PuzzleSessionModelTests {

    /// `e2e4` is the opponent's setup move; the solver must answer `e7e5`.
    private func singleMovePlan(theme: ThemeTag = .fork) -> SessionItemPlan {
        makePlan(line: ["e2e4", "e7e5"], theme: theme)
    }

    /// Setup `e2e4`, then `e7e5` / `g1f3` / `b8c6` — two user moves with an
    /// auto-played reply between them.
    private func twoMovePlan() -> SessionItemPlan {
        makePlan(line: ["e2e4", "e7e5", "g1f3", "b8c6"])
    }

    @Test("Starting a session serves the first item with its setup move played")
    func startServesFirstItem() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        #expect(model.stage == .solving)
        #expect(model.progress.counterLabel == "1 / 1")
        // The setup move is on the board: it is Black to move.
        #expect(model.machineSnapshot?.expectedMove == "e7e5")
        #expect(model.orientation == .black)
        // ...and the pre-setup position is still available for the animation.
        #expect(model.setupMove?.from == .e2)
        #expect(model.setupMove?.to == .e4)
    }

    @Test("A correct final move solves the puzzle and raises a success verdict")
    func correctMoveSolves() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        let acceptance = model.attemptMove(from: .e7, to: .e5)
        if case .accepted = acceptance {} else { Issue.record("expected the board to keep the piece") }

        // The board answers synchronously; the grade lands a hop later.
        await model.waitForGrading()

        #expect(model.stage.verdict?.solved == true)
        #expect(model.progress.solved == 1)
        #expect(model.progress.completed == 1)
        #expect(model.missed.isEmpty)
    }

    /// Once snapped the piece back. It does not any more — see
    /// ``aMissIsShownOnTheBoard()`` for why refusing the move read to users as
    /// the app ignoring them. Everything else this test asserts is unchanged.
    @Test("A wrong move fails the attempt and names the concept")
    func wrongMoveFails() async {
        let driver = FakeDriver(plans: [singleMovePlan(theme: .pin)])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        let acceptance = model.attemptMove(from: .d7, to: .d5)
        if case .accepted = acceptance {} else { Issue.record("a wrong move must still be shown") }

        await model.waitForGrading()
        #expect(model.position?.piece(at: .d5)?.kind == .pawn)

        let verdict = model.stage.verdict
        #expect(verdict?.solved == false)
        // Two sentences, not `move: theme`. The tag belongs to the puzzle; the
        // move being named is whichever one the user was standing in front of.
        #expect(
            verdict?.message
                == "Missed — the pawn to e5. This puzzle was about a pin — the piece cannot move "
                    + "without exposing the one behind it."
        )
        // The ring marks where the user actually went.
        #expect(verdict?.ring == BoardRing(square: .d5, tone: .wrong))
        // ...and the answer is drawn so they leave knowing the move.
        #expect(verdict?.answer == "e7e5")
        #expect(model.progress.solved == 0)
        #expect(model.missed.map(\.concept) == ["pin"])
    }

    @Test("An illegal move is not scored")
    func illegalMoveIsNotScored() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        // White's rook, with Black to move.
        let acceptance = model.attemptMove(from: .a1, to: .a3)
        if case .rejected = acceptance {} else { Issue.record("an illegal move must snap back") }

        #expect(model.stage == .solving)
        #expect(model.progress.completed == 0)
        #expect(model.missed.isEmpty)
    }

    @Test("The full line must be played; the opponent's reply arrives in between")
    func fullLineRequired() async {
        let driver = FakeDriver(plans: [twoMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        // Still solving: one move of the line is not the answer.
        #expect(model.stage == .solving)
        #expect(model.progress.completed == 0)
        // The opponent's reply was auto-played and is highlighted.
        #expect(model.lastOpponentMove == MovePair(uci: "g1f3"))
        #expect(model.machineSnapshot?.expectedMove == "b8c6")
        #expect(model.liveRing == BoardRing(square: .e5, tone: .correct))

        _ = model.attemptMove(from: .b8, to: .c6)
        await model.waitForGrading()
        #expect(model.stage.verdict?.solved == true)
        #expect(model.progress.solved == 1)
    }

    /// A hint puts the answer on screen, so nothing after it is evidence about
    /// recall — `AutoGrader` grades it `.again` and the summary agrees.
    @Test("A hinted solve counts as hinted, not solved")
    func hintedSolveIsNotASolve() async {
        let driver = FakeDriver(plans: [singleMovePlan(theme: .skewer)])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        // First rung: a description of the move, not the move.
        model.revealHint()
        #expect(model.hintLevel == .nudge)
        #expect(model.hintMove == nil, "the nudge must not draw the arrow")
        // Second rung: the arrow.
        model.revealHint()
        #expect(model.hintMove == "e7e5")
        #expect(driver.hintsRequested == 1)

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        #expect(model.stage.verdict?.solved == false)
        #expect(model.progress.hinted == 1)
        #expect(model.progress.solved == 0)
        #expect(model.missed.map(\.concept) == ["skewer"])
    }

    /// Both rungs of the ladder cost one hint, not two. The answer is fetched
    /// from the driver on the first tap and held back until the second, so the
    /// attempt is spent once however far the user climbs.
    @Test("Climbing the hint ladder does not double-count the hint")
    func hintIsIdempotentPerItem() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        model.revealHint()
        model.revealHint()
        model.revealHint()
        #expect(driver.hintsRequested == 1)
        #expect(model.hintLevel == .answer)

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        #expect(model.progress.hinted == 1)
    }

    @Test("Skipping is graded as a failure")
    func skipCountsAsFailure() async {
        let driver = FakeDriver(plans: [singleMovePlan(theme: .fork)])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        await model.skip()

        #expect(model.stage.verdict?.solved == false)
        #expect(model.progress.completed == 1)
        #expect(model.missed.map(\.concept) == ["fork"])
    }

    @Test("Continue advances to the next puzzle and moves the counter")
    func continueAdvances() async {
        let driver = FakeDriver(plans: [singleMovePlan(), twoMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()
        #expect(model.progress.counterLabel == "1 / 2")

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        // The banner holds the counter on the puzzle that was answered.
        #expect(model.progress.counterLabel == "1 / 2")

        model.continueAfterVerdict()
        #expect(model.stage == .solving)
        #expect(model.progress.counterLabel == "2 / 2")
        #expect(model.hintMove == nil)
        #expect(model.liveRing == nil)
    }

    /// `database: nil` on purpose. A real set ends with its concept slot — the
    /// opening, endgame or positional idea the app chose — and that is covered
    /// by ``ConceptSchedulerTests``. This test is about the *puzzle queue*
    /// finishing, and letting the concept run here would be testing two things
    /// and reporting one.
    /// The complaint this fixes was "it literally didn't let me move". The move
    /// was graded and the banner did appear — but the board snapped the piece
    /// back, so the only feedback the user was actually looking for never came.
    @Test("A wrong move is left on the board, not snapped back")
    func aMissIsShownOnTheBoard() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        // b8-a6 is legal in the position after 1.e4 and is not the answer.
        _ = model.attemptMove(from: .b8, to: .a6)
        await model.waitForGrading()

        #expect(model.position?.piece(at: .a6)?.kind == .knight, "the user's move is not on the board")
        #expect(model.position?.piece(at: .b8) == nil)
        #expect(model.stage.verdict?.solved == false)
    }

    /// A retry means the position is unchanged and you get another go, so the
    /// board must *not* keep the refused move.
    @Test("A move that still has a retry left does snap back")
    func aRetryLeavesTheBoardAlone() async {
        let plan = makePlan(line: ["e2e4", "e7e5"], kind: .relearn(cardID: UUID()))
        let model = PuzzleSessionModel(driver: FakeDriver(plans: [plan]), database: nil)
        await model.start()

        let before = model.position
        _ = model.attemptMove(from: .b8, to: .a6)
        await model.waitForGrading()

        #expect(model.position == before, "a retry has to leave the position alone")
        #expect(model.position?.piece(at: .b8)?.kind == .knight)
    }

    @Test("The session ends in a summary with the rating delta")
    func summaryAtTheEnd() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        driver.ratingStepPerItem = 12
        let model = PuzzleSessionModel(
            driver: driver, database: nil, clock: TestClock(step: 252).next)
        await model.start()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        model.continueAfterVerdict()

        #expect(model.stage == .summary)
        #expect(model.progress.ratingDelta == 12)
        #expect(model.progress.timeLabel == "04:12")
        #expect(model.progress.solvedLabel == "1/1")
    }

    /// `Time` is the summary's only reading of effort, and it used to be wall
    /// clock: a set interrupted by a phone call reported the length of the call.
    @Test("Time spent out of the app is not counted as solving time")
    func backgroundedTimeIsNotCounted() async {
        // In the order the model asks: the start, the pause a minute later, the
        // resume four minutes after that, and the summary a minute later again.
        let clock = SteppedClock(seconds: [0, 60, 300, 360])
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [singleMovePlan()]), database: nil, clock: clock.next)
        await model.start()

        model.pauseClock()
        model.resumeClock()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        model.continueAfterVerdict()

        #expect(model.progress.timeLabel == "02:00", "the four minutes in the background are not solving time")
    }

    /// The summary is the wrong screen for a set that served nothing:
    /// `displayTotal` floors the denominator at one, so an empty queue was
    /// reported as `Solved 0/1` — a puzzle the user was shown and missed.
    @Test("A session that assembles nothing says so instead of claiming a miss")
    func emptySession() async {
        let model = PuzzleSessionModel(driver: FakeDriver(plans: []), database: nil)
        await model.start()

        guard case let .unavailable(message) = model.stage else {
            Issue.record("expected an explanation, got \(model.stage)")
            return
        }
        #expect(message.contains("rating band"))
        #expect(model.progress.completed == 0)
    }

    @Test("A refused move on a second-chance item says another try is left")
    func retrySaysAnotherTryIsLeft() async {
        let plan = makePlan(line: ["e2e4", "e7e5"], kind: .relearn(cardID: UUID()))
        let model = PuzzleSessionModel(driver: FakeDriver(plans: [plan]), database: nil)
        await model.start()

        let acceptance = model.attemptMove(from: .b8, to: .a6)
        await model.waitForGrading()

        guard case let .rejected(reason) = acceptance else {
            Issue.record("a retry has to refuse the move")
            return
        }
        #expect(reason == "Not that one — one more try.")
    }

    /// The same-day retries are appended when the planned queue runs out, so a
    /// set promised as ten finishes at twelve. Naming them is what stops the
    /// counter growing for no visible reason.
    @Test("A same-day retry says why the position is on screen again")
    func relearnItemIsLabelled() async {
        let plan = makePlan(line: ["e2e4", "e7e5"], kind: .relearn(cardID: UUID()))
        let model = PuzzleSessionModel(driver: FakeDriver(plans: [plan]), database: nil)
        await model.start()

        #expect(model.taskLine == "Second look — you missed this one earlier. Black to play.")
    }

    @Test("A first look is not labelled as a second one")
    func freshItemKeepsTheNeutralTaskLine() async {
        let model = PuzzleSessionModel(driver: FakeDriver(plans: [singleMovePlan()]), database: nil)
        await model.start()

        #expect(model.taskLine == "Black to play — find the best move.")
    }

    /// A reveal used to leave the ladder at `.answer` for the whole item, and
    /// the hint button is disabled on exactly that — so a user who needed help
    /// with move one was refused it for the rest of a line they had never seen.
    @Test("A hint on the first move does not disable the hint for the rest of the line")
    func hintReArmsForEachMoveOfALine() async {
        let driver = FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5", "g1f3", "b8c6"])])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        model.revealHint()
        model.revealHint()
        #expect(model.hintLevel == .answer)

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        #expect(model.stage == .solving, "the same item, one move further on")
        #expect(model.hintLevel == .none)
        #expect(model.hintMove == nil)

        model.revealHint()
        model.revealHint()
        #expect(model.hintMove == "b8c6")

        _ = model.attemptMove(from: .b8, to: .c6)
        await model.waitForGrading()

        // Charged once however many moves the line took: the attempt was lost
        // on the first rung and cannot be lost twice.
        #expect(model.progress.hinted == 1)
        #expect(model.progress.solved == 0, "the answer was on screen")
    }

    /// A revisit is a one-item session, so the concept *is* the queue. Left
    /// uncounted, the banner offered "Next" when the next tap was the summary,
    /// and that summary reported `Solved 0/1` for an exercise just played.
    @Test("Revisiting a concept counts the exercise it just played")
    func revisitCountsItsOwnExercise() async {
        let concept = TrainingConcept(
            id: "test.revisit",
            family: .opening,
            title: "A short line",
            teaching: TrainingConcept.Teaching(
                idea: "Play e5.",
                why: "It claims the centre.",
                lookFor: "The centre. Take a share of it."
            ),
            fromRating: 0,
            exercise: .line(fen: startFEN, moves: ["e2e4", "e7e5"], opponentMovesFirst: true)
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: []), database: nil, soloConcept: concept)
        await model.start()
        #expect(model.teachingConcept?.id == concept.id)

        model.beginConceptExercise()
        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        #expect(model.progress.completed == 1, "so the banner reads Finish, not Next")
        model.continueAfterVerdict()
        #expect(model.stage == .summary)
        #expect(model.progress.solvedLabel == "1/1")
    }

    /// Tapping a rating leak names the subject on the way in. The concept slot
    /// is filled by rotation and knows nothing about that request, so a lesson
    /// on, say, an opening line was the first thing between "Train
    /// blunder-checking" and any blunder-checking.
    @Test("A set opened from a leak goes straight to the puzzles")
    func aRequestedFocusSkipsTheLesson() async {
        let concept = TrainingConcept(
            id: "test.unrelatedConcept",
            family: .opening,
            title: "A short line",
            teaching: TrainingConcept.Teaching(
                idea: "Play e5.",
                why: "It claims the centre.",
                lookFor: "The centre. Take a share of it."
            ),
            fromRating: 0,
            exercise: .line(fen: startFEN, moves: ["e2e4", "e7e5"], opponentMovesFirst: true)
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [singleMovePlan()]),
            database: nil,
            concept: ConceptScheduler.Selection(concept: concept, teachFirst: true),
            teachesConcept: false
        )
        await model.start()

        #expect(model.stage == .solving, "the lesson must not stand in front of the request")
        #expect(model.isConceptItem == false)
    }

    /// A full set counts nothing for the concept: it sits outside
    /// `driver.queueCount`, so counting it would push `completed` one ahead of
    /// the queue and label the ninth puzzle as the tenth.
    @Test("A set's concept does not move the puzzle counter")
    func setConceptLeavesTheCounterAlone() async {
        let concept = TrainingConcept(
            id: "test.setConcept",
            family: .opening,
            title: "A short line",
            teaching: TrainingConcept.Teaching(
                idea: "Play e5.",
                why: "It claims the centre.",
                lookFor: "The centre. Take a share of it."
            ),
            fromRating: 0,
            exercise: .line(fen: startFEN, moves: ["e2e4", "e7e5"], opponentMovesFirst: true)
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [singleMovePlan()]),
            database: nil,
            concept: ConceptScheduler.Selection(concept: concept, teachFirst: false)
        )
        await model.start()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        #expect(model.progress.completed == 0)
    }

    /// The band can be empty behind a concept that ran perfectly well. Telling
    /// that user "training could not start" and nothing else would deny the
    /// exercise they just played.
    @Test("An empty queue behind a finished exercise still credits the exercise")
    func emptyQueueAfterAConceptCreditsIt() async {
        let concept = TrainingConcept(
            id: "test.emptyQueue",
            family: .opening,
            title: "A short line",
            teaching: TrainingConcept.Teaching(
                idea: "Play e5.",
                why: "It claims the centre.",
                lookFor: "The centre. Take a share of it."
            ),
            fromRating: 0,
            exercise: .line(fen: startFEN, moves: ["e2e4", "e7e5"], opponentMovesFirst: true)
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: []),
            database: nil,
            concept: ConceptScheduler.Selection(concept: concept, teachFirst: false)
        )
        await model.start()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        model.continueAfterVerdict()

        guard case let .unavailable(message) = model.stage else {
            Issue.record("expected an explanation, got \(model.stage)")
            return
        }
        #expect(message.contains("still counts"))
    }

    @Test("A session that failed to load says so instead of showing an empty board")
    func loadFailure() async {
        let driver = FakeDriver(plans: [])
        driver.loadFailure = "no database"
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()
        #expect(model.stage == .unavailable("no database"))
    }
}

/// A scripted clock: one reading per call, holding the last one once the script
/// runs out, so a test can name exactly when each of the model's readings falls.
private final class SteppedClock: @unchecked Sendable {

    private let readings: [Date]
    private var callCount = 0
    private let lock = NSLock()

    init(seconds: [TimeInterval]) {
        let base = Date(timeIntervalSince1970: 0)
        readings = seconds.map { base.addingTimeInterval($0) }
    }

    var next: @Sendable () -> Date {
        { [self] in
            lock.withLock {
                defer { callCount += 1 }
                return readings[min(callCount, readings.count - 1)]
            }
        }
    }
}

/// Two readings: the session's start, then one fixed interval later.
private final class TestClock: @unchecked Sendable {

    private let step: TimeInterval
    private let base = Date(timeIntervalSince1970: 0)
    private var callCount = 0
    private let lock = NSLock()

    init(step: TimeInterval) {
        self.step = step
    }

    var next: @Sendable () -> Date {
        { [self] in
            lock.withLock {
                defer { callCount += 1 }
                return base.addingTimeInterval(callCount == 0 ? 0 : step)
            }
        }
    }
}

// MARK: - Drill mastery

@Suite("Drill mastery")
struct DrillMasteryTests {

    @Test("The footer reports the streak against the requirement")
    func label() {
        #expect(DrillMastery(cleanStreak: 2, required: 3).label == "2 of 3 clean")
        #expect(DrillMastery(cleanStreak: 2, required: 3).fraction == 2.0 / 3.0)
        #expect(!DrillMastery(cleanStreak: 2, required: 3).isMastered)
    }

    /// The metric keeps counting past the requirement; the card must not.
    @Test("A streak beyond the requirement clamps")
    func clamps() {
        let mastery = DrillMastery(cleanStreak: 9, required: 2)
        #expect(mastery.label == "2 of 2 clean")
        #expect(mastery.fraction == 1)
        #expect(mastery.isMastered)
    }

    /// King and pawn is scored as a *set* of six positions, and the curriculum
    /// counts clean sets. Labelling its streak the same way as a single-run
    /// family told the user six clean sets were needed for a gate that asks for
    /// two.
    @Test("A set-scored family says so")
    func setScoredLabel() {
        #expect(DrillMastery(cleanStreak: 1, required: 2, countsSets: true).label == "1 of 2 clean sets")
    }
}

// MARK: - What a drill says about itself

/// The drill screen used to show a family name, a bare `7 / 25` and "Give up".
/// A user dropped into "Philidor" with Black to move could not tell they were
/// defending, and `24 / 25` means "about to fail" in the rook mate and "about to
/// pass" in Philidor.
@Suite("Drill task line")
@MainActor
struct EndgameDrillPresentationTests {

    private func model(_ kind: EndgameDrillKind) -> EndgameDrillModel {
        EndgameDrillModel(kind: kind, opponent: NullDrillOpponent())
    }

    @Test("The counter says which way it counts")
    func theCounterNamesItsUnit() {
        #expect(model(.krk).budgetLabel.hasPrefix("Move 0 of "))
        #expect(model(.philidor).budgetLabel.hasPrefix("Held 0 of "))
    }

    @Test("Every drill states its goal")
    func theGoalIsOnScreen() {
        #expect(model(.krk).taskLine.contains("Mate in"))
        #expect(model(.philidor).taskLine.contains("Hold the draw"))
        #expect(model(.lucena).taskLine.contains("Win it"))
        // A theoretical-result drill has to say that holding *or* winning is
        // the task, because which one it is changes from position to position.
        #expect(model(.kpk).taskLine.contains("without changing the result"))
    }

    @Test("A multi-position family says where you are in it")
    func theSetSaysHowLongItIs() {
        #expect(model(.kpk).positionLabel == "Position 1 of 6")
        #expect(model(.lucena).positionLabel == "Position 1 of 3")
        // Two bishops is the one family that is still a single position, and a
        // counter reading "Position 1 of 1" would be chrome stating nothing.
        #expect(model(.kbbk).positionLabel == nil, "one position needs no counter")
    }

    /// Each position's own title is the lesson in three words — "Outside the
    /// square" *is* the hint — and it was in the catalogue and on no screen.
    @Test("The position's own title is shown")
    func thePositionIsNamed() {
        #expect(model(.kpk).taskLine.hasPrefix(EndgameDrill.kpkSet[0].title))
    }
}

// MARK: - Why the move works

/// The explanation is read off the board, never from the theme tag.
///
/// These pin the one property that makes the feature safe to ship: it says
/// nothing it cannot prove from the position. A confidently wrong explanation
/// teaches the wrong pattern, which is worse than the bare square it replaced.
@Suite("Puzzle explanations")
struct PuzzleReasonTests {

    private func position(_ fen: String) -> Position {
        guard let position = Position(fen: fen) else {
            Issue.record("bad fixture FEN: \(fen)")
            return .standard
        }
        return position
    }

    @Test("A knight fork names both pieces it hits")
    func namesAFork() {
        // Nb5–c7: the family fork, hitting the king on e8 and the rook on a8.
        let clause = PuzzleReason.clause(
            forAnswer: "b5c7",
            in: position("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1")
        )
        #expect(clause == "it forks the king and rook — only one of them can move away")
    }

    @Test("Mate is the whole explanation")
    func mateNeedsNothingElse() {
        // Ra1–a8 is back-rank mate; the pawns the king is stuck behind are its own.
        let clause = PuzzleReason.clause(
            forAnswer: "a1a8",
            in: position("6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1")
        )
        #expect(clause == "that is checkmate")
    }

    /// `the rook takes the queen: it wins the queen` said one thing twice and
    /// the useful thing not at all. The description already names both pieces;
    /// what the reader cannot see is whether anything takes back — which is the
    /// question they have to learn to ask before every capture.
    @Test("A free capture says why it is free, not what it captured")
    func namesTheReasonNotThePiece() {
        let clause = PuzzleReason.clause(
            forAnswer: "d1d8",
            in: position("3q4/8/8/7k/8/8/8/3R2K1 w - - 0 1")
        )
        #expect(clause == "nothing defends it")
    }

    /// The second position from the same session, and the second way the old
    /// copy failed: `the pawn takes the pawn: it wins the pawn` is true, says
    /// "pawn" three times, and omits the entire point — hxg2 is safe *and*
    /// lands attacking the rook on h1, which is why it is the only move.
    @Test("A capture also names what the piece threatens from its new square")
    func namesTheThreatItCreates() {
        let clause = PuzzleReason.clause(
            forAnswer: "h3g2",
            in: position("2k5/ppp2p2/2r2n2/3rq2p/1QN1p3/P3P2p/2P1NPP1/2R1K2R b - - 0 1")
        )
        #expect(clause == "nothing defends it, and it now attacks the rook")
    }

    /// The bug all of this exists for. `it wins the <piece>` was printed for
    /// *any* capture, and a quarter of the corpus's capture answers are
    /// sacrifices — so the banner announced a queen sacrifice as winning a pawn,
    /// which is the exact reverse of the idea the puzzle teaches.
    @Test("A capture that loses material is never called a win")
    func aSacrificeIsNotAWin() {
        // Rxd5 takes a pawn the c6 pawn defends. The rook is simply lost.
        let clause = PuzzleReason.clause(
            forAnswer: "d1d5",
            in: position("4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1")
        )
        #expect(clause == nil, "nothing here is provable, and silence beats a false claim")
    }

    @Test("An even exchange is named as a trade, not as a win")
    func anEvenExchangeIsATrade() {
        // Rxd5 wins a rook and loses one to the c6 pawn: material is unchanged.
        let clause = PuzzleReason.clause(
            forAnswer: "d1d5",
            in: position("4k3/8/2p5/3r4/8/8/8/3RK3 w - - 0 1")
        )
        #expect(clause == "it trades rooks")
    }

    /// The position that prompted this, from a real session. The rook takes a
    /// knight standing next to the enemy queen, so it reads as dropping the
    /// exchange — and it is right anyway, because the recapture walks into a
    /// deflection. Statically the capture scores -180cp; only the line explains
    /// it, which is exactly what the reader needs and never got.
    @Test("A defended capture answers the recapture instead of ignoring it")
    func answersTheObviousObjection() {
        let clause = PuzzleReason.clause(
            forAnswer: "c6c4",
            in: position("2k5/ppp2p1p/2r1qn2/3r2p1/1QN1p3/P3P2P/2P1NPP1/R3KR2 b - - 0 1"),
            continuation: ["b4c4", "d5d1", "e1d1", "e6c4"]
        )
        // No material clause, and that is the correction rather than a loss.
        // Black wins the knight and then the queen (+12) but gives up both
        // rooks getting there (-10), so the line nets +2 — about the exchange,
        // which is what this test's own doc comment says it is worth. "You win
        // the queen" named the biggest piece captured anywhere in the line and
        // subtracted nothing; a sweep of all 120,000 corpus puzzles found 3,104
        // making that claim falsely. The mechanism is the part that was true and
        // the part the reader asked for, so it stays.
        #expect(clause == "if they take back, the rook goes to d1 with check")
    }

    @Test("Without the line, that same capture claims only what it can prove")
    func claimsNothingUnprovable() {
        let clause = PuzzleReason.clause(
            forAnswer: "c6c4",
            in: position("2k5/ppp2p1p/2r1qn2/3r2p1/1QN1p3/P3P2P/2P1NPP1/R3KR2 b - - 0 1")
        )
        // True, checkable, and not a claim about material it cannot support.
        #expect(clause == "it attacks the queen")
    }

    /// The gate on whether a puzzle costs an engine search at all, so it is
    /// worth pinning down what it excludes as much as what it admits.
    /// Mate at the end of the line outranks every other thing that could be
    /// said about the move, and until the line was read the banner reported a
    /// forced mate as whatever the first move happened to touch.
    @Test("A line that ends in mate says so")
    func namesAForcedMate() {
        // Ra8+ Rd8 Rxd8#: the check is not the point, the mate is.
        let clause = PuzzleReason.clause(
            forAnswer: "a1a8",
            in: position("6k1/3r1ppp/8/8/8/8/8/R3K3 w - - 0 1"),
            continuation: ["d7d8", "a8d8"]
        )
        #expect(clause == "it forces mate")
    }

    /// `it puts the king in check` was a third of everything this file said,
    /// and it describes something already drawn on the board in a colour the
    /// reader cannot miss. What the check forces is the part they cannot see.
    @Test("A check is explained by what it forces, not by being a check")
    func namesWhatTheCheckForces() {
        // Rh8+ Ke7 Bxb6 — the check drags the king off the knight's defence.
        let clause = PuzzleReason.clause(
            forAnswer: "h1h8",
            in: position("4k3/8/1n6/8/3B4/8/8/4K2R w - - 0 1"),
            continuation: ["e8e7", "d4b6"]
        )
        #expect(clause == "it checks, and you win the knight")
    }

    @Test("Without the line, the same check can only say it is a check")
    func fallsBackWhenTheLineIsUnknown() {
        let clause = PuzzleReason.clause(
            forAnswer: "h1h8",
            in: position("4k3/8/1n6/8/3B4/8/8/4K2R w - - 0 1")
        )
        #expect(clause == "it puts the king in check")
    }

    @Test("A search is spent only where it could change the sentence")
    func theEngineIsAskedOnlyWhenItCanAnswer() {
        // A hanging queen: the capture proves itself.
        #expect(
            PuzzleReason.needsTheLine(
                answer: "d1d8",
                in: position("3q4/8/8/7k/8/8/8/3R2K1 w - - 0 1")
            ) == false
        )
        // A check says something true without help.
        #expect(
            PuzzleReason.needsTheLine(
                answer: "a1a5",
                in: position("8/8/k7/8/8/8/8/R3K3 w - - 0 1")
            ) == false
        )
        // A quiet move the board cannot explain is the case the engine exists
        // for. It captures nothing and points at nothing, so every clause
        // declines and the banner falls through to naming the square — which is
        // exactly the shape every position mined from the user's own game has.
        #expect(
            PuzzleReason.needsTheLine(
                answer: "e2e3",
                in: position("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
            )
        )
        // A rook taking a defended knight: nothing on the board justifies it,
        // and the line is the only thing that can.
        #expect(
            PuzzleReason.needsTheLine(
                answer: "c6c4",
                in: position("2k5/ppp2p1p/2r1qn2/3r2p1/1QN1p3/P3P2P/2P1NPP1/R3KR2 b - - 0 1")
            )
        )
    }

    /// The fork clause used to be emitted before any safety check ran, so a
    /// knight dropped on a defended square attacking two pieces was announced
    /// as a winning fork. It is a knight for a pawn, and the sentence taught
    /// the pattern with the half that makes it work left out.
    @Test("A fork whose piece can simply be taken is not called a fork")
    func aHangingForkIsNotAFork() {
        // Nb5-c7 hits the king on e8 and the rook on a8, and the d8 bishop
        // covers c7.
        let clause = PuzzleReason.clause(
            forAnswer: "b5c7",
            in: position("r2bk3/8/8/1N6/8/8/8/4K3 w - - 0 1")
        )
        #expect(clause?.contains("forks") != true, "nothing about this wins material")
        #expect(clause == "it attacks the king and the rook, with check")
    }

    /// `Line.won` is a list of the solver's captures, which is not an outcome.
    /// A line that takes a rook and gives back a queen used to print "you win
    /// the rook".
    @Test("A gain that the line pays for is not announced as a win")
    func aGainIsNetOfWhatItCosts() {
        // Rh8+ Ke7 Rxd8 Kxd8: the rook is won and given straight back, so the
        // line is an even trade and nothing is won at all.
        let clause = PuzzleReason.clause(
            forAnswer: "h1h8",
            in: position("3rk3/8/8/8/8/8/8/3QK2R w - - 0 1"),
            continuation: ["e8e7", "h8d8", "e7d8"]
        )
        #expect(clause?.contains("you win the rook") != true)
    }

    /// `CalibrationScoring` scores the king 0 so that material counting ignores
    /// it. That made the king the "cheapest" attacker of every square it stood
    /// beside, and the banner named it over the pawn that was the real point.
    @Test("The defending pawn is named, not the king standing beside it")
    func namesTheCheapestRealAttacker() {
        // d5 is defended by the c6 pawn *and* by the king on e6.
        let mistake = PuzzleReason.mistake(
            inMove: "d1d5",
            from: position("8/8/2p1k3/3p4/8/8/8/3QK3 w - - 0 1")
        )
        #expect(mistake == "your queen could be taken by the pawn")
    }

    /// The position that prompted this: Black's knight on c6 is attacked by the
    /// queen on b5 and defended by nothing, and the answer simply defends it.
    /// It captures nothing, checks nothing, forks nothing and attacks nothing
    /// bigger than itself — so every other clause declined and the banner read
    /// "Missed — the queen to d6." with no reason at all.
    @Test("A quiet move that saves a hanging piece says so")
    func namesTheDefence() {
        let clause = PuzzleReason.clause(
            forAnswer: "d8d6",
            in: position("r1bqkb1r/p1p1pppp/2n2n2/1Q6/2pP4/5N2/PP2PPPP/RNB1KB1R b KQkq - 0 1")
        )
        #expect(clause == "it defends the knight, which had nothing guarding it")
    }

    /// A piece attacked but adequately defended is not hanging, and saying it
    /// was would teach the reader to fear every attack instead of counting one.
    @Test("A piece that is attacked but defended is not called hanging")
    func defenceNeedsARealThreat() {
        // The knight on c6 is attacked by the queen and defended by the b7
        // pawn: taking it loses a queen for a knight.
        let clause = PuzzleReason.clause(
            forAnswer: "d8d6",
            in: position("r1bqkb1r/pp2pppp/2n2n2/1Q6/2pP4/5N2/PP2PPPP/RNB1KB1R b KQkq - 0 1")
        )
        #expect(clause != "it defends the knight, which had nothing guarding it")
    }

    @Test("A move with nothing to say says nothing")
    func silenceRatherThanFiller() {
        // A quiet pawn push that captures nothing, checks nothing, hits nothing.
        let clause = PuzzleReason.clause(
            forAnswer: "e2e3",
            in: position("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
        )
        #expect(clause == nil, "an invented reason is worse than no reason")
    }

    @Test("A missing position or move explains nothing")
    func degradesQuietly() {
        #expect(PuzzleReason.clause(forAnswer: nil, in: .standard) == nil)
        #expect(PuzzleReason.clause(forAnswer: "e2e4", in: nil) == nil)
        // Not a legal move in this position.
        #expect(PuzzleReason.clause(forAnswer: "a1a8", in: .standard) == nil)
    }

    @Test("The banner keeps its old wording when the position is unknown")
    func copyIsUnchangedWithoutAPosition() {
        // The pure copy tests above rely on this, and so does the summary.
        #expect(
            PuzzleConcept.verdictMessage(solved: false, theme: ThemeTag("crushing"), answer: "g1f3")
                == "Missed — the move was to f3."
        )
    }

    /// The user cannot be taught a word by having it used at them. Every clause
    /// that names a pattern has to define it in the same breath.
    @Test("Naming a pattern always defines it")
    func jargonIsAlwaysExplained() {
        let clause = PuzzleReason.clause(
            forAnswer: "b5c7",
            in: position("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1")
        )
        #expect(clause?.contains("forks") == true, "the word is still worth learning")
        // Matched loosely on purpose: the rule is that the definition is
        // *there*, not that it is phrased in one exact way. Pinning the whole
        // sentence made this test fail when the clause was shortened to fit the
        // banner, which is a wording change and not a doctrine change.
        #expect(clause?.contains("can move away") == true, "and it has to be explained")
    }

    /// `attacks the king, with check` says the same thing twice.
    @Test("A check is not also announced as an attack on the king")
    func checkIsNotDoubled() {
        // Ra1–a5 checks the king on a6 up the file. (a8 would have to pass
        // through the king to get there, which is not a move.)
        let clause = PuzzleReason.clause(
            forAnswer: "a1a5",
            in: position("8/8/k7/8/8/8/8/R3K3 w - - 0 1")
        )
        #expect(clause == "it puts the king in check")
    }

    // MARK: The move the user played

    @Test("A move that hangs a piece says so")
    func namesTheHangingPiece() {
        // Qd1–d5, where a pawn on e6 can simply take it.
        let mistake = PuzzleReason.mistake(
            inMove: "d1d5",
            from: position("4k3/8/4p3/8/8/8/8/3QK3 w - - 0 1")
        )
        #expect(mistake == "your queen could be taken by the pawn")
    }

    @Test("A safe move is not accused of anything")
    func staysSilentOnASoundMove() {
        let mistake = PuzzleReason.mistake(
            inMove: "d1d4",
            from: position("4k3/8/4p3/8/8/8/8/3QK3 w - - 0 1")
        )
        #expect(mistake == nil, "a guess dressed as coaching costs more than silence")
    }

    /// Being recaptured is not the same as blundering: taking a queen with a
    /// rook is correct even when the rook is then taken.
    @Test("A capture that wins more than it risks is not a mistake")
    func profitableCapturesAreLeftAlone() {
        let mistake = PuzzleReason.mistake(
            inMove: "d1d8",
            from: position("3q1k2/8/8/8/8/8/8/3R2K1 w - - 0 1")
        )
        #expect(mistake == nil)
    }

    @Test("A solve is never told what was wrong with it")
    func solvesCarryNoMistake() {
        let board = position("4k3/8/4p3/8/8/8/8/3QK3 w - - 0 1")
        let solved = PuzzleConcept.verdictMessage(
            solved: true, theme: .fork, answer: "d1d5", position: board, mistake: "your queen could be taken by the pawn"
        )
        #expect(!solved.contains("But"))
    }

    @Test("A miss explains the answer and the move that was played")
    func missExplainsBothMoves() {
        let board = position("4k3/8/4p3/8/8/8/8/3QK3 w - - 0 1")
        let missed = PuzzleConcept.verdictMessage(
            solved: false, theme: .fork, answer: "d1d4", position: board,
            mistake: PuzzleReason.mistake(inMove: "d1d5", from: board)
        )
        #expect(missed.contains("But your queen could be taken by the pawn."))
    }

    @Test("Success and failure still share a sentence shape once a reason is added")
    func shapeSurvivesTheExplanation() {
        let board = position("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1")
        let missed = PuzzleConcept.verdictMessage(
            solved: false, theme: .fork, answer: "b5c7", position: board
        )
        let solved = PuzzleConcept.verdictMessage(
            solved: true, theme: .fork, answer: "b5c7", position: board
        )
        #expect(missed.contains("forks the king and rook — only one of them can move away"))
        #expect(missed.dropFirst("Missed".count) == solved.dropFirst("Solved".count))
    }
}

// MARK: - Orientation

@Suite("Board orientation")
@MainActor
struct PuzzleOrientationTests {

    /// The bug: orientation was derived from `sideToMove`, so the board span
    /// round the instant an answer landed — while the user was still reading the
    /// result of the puzzle they had just finished.
    @Test("Solving a puzzle does not spin the board")
    func orientationHoldsThroughTheVerdict() async {
        let driver = FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5"])])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        let solving = model.orientation
        #expect(solving == .black)

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        guard case .verdict = model.stage else {
            Issue.record("expected a verdict")
            return
        }
        #expect(model.orientation == solving, "the board must not turn under the banner")
    }
}

// MARK: - Engine-backed explanations

/// A scripted evaluator, so the upgrade path can be tested without Stockfish.
private struct ScriptedEvaluator: PuzzleMoveEvaluator {
    /// Centipawns keyed by UCI, from the solver's point of view.
    var scores: [String: Int]
    /// Principal variations keyed by the move they follow, opponent's reply
    /// first — the shape `EnginePuzzleEvaluator` returns from a real search.
    var lines: [String: [String]] = [:]

    func evaluate(fen: String, playing uci: String) async -> PuzzleEvaluation? {
        scores[uci].map(PuzzleEvaluation.init(centipawns:))
    }

    func continuation(fen: String, playing uci: String) async -> [String] {
        lines[uci] ?? []
    }
}

/// Most wrong moves hang nothing — they are simply not the best. The board
/// cannot say why; the engine can.
/// A puzzle mined from the user's own game stores one answer — whatever the
/// analysis pass picked — and its second and third choices are often within a
/// few centipawns. The banner says `Missed`; the engine's opinion that the move
/// played was just as good used to be expressed by saying nothing, which reads
/// as agreement with the verdict — and then by saying "yours was just as good"
/// under a heading reading `Missed`, which is the app contradicting itself. The
/// clause now says why the verdict stands: the card holds one answer.
@Suite("Near-equal moves")
struct PuzzleEquivalenceTests {

    @Test("A move the engine rates as good as the answer is said to be")
    func equalMoveIsNotLeftAsAMiss() {
        let clause = PuzzleMoveComparison.clause(
            answer: PuzzleEvaluation(centipawns: -147),
            played: PuzzleEvaluation(centipawns: -130)
        )
        #expect(clause == "the engine rates yours the same — only one answer is stored here")
    }

    @Test("A move that is genuinely worse still gets named as worse")
    func worseMoveIsStillCriticised() {
        let clause = PuzzleMoveComparison.clause(
            answer: PuzzleEvaluation(centipawns: 600),
            played: PuzzleEvaluation(centipawns: 0)
        )
        #expect(clause == "yours only keeps things level")
    }

    /// The gap between "the same move really" and "worse" stays silent, which
    /// is the original behaviour and still the right one: there is nothing
    /// honest to say about a move that is slightly but not meaningfully worse.
    @Test("The middle ground still says nothing")
    func theMiddleStaysQuiet() {
        #expect(
            PuzzleMoveComparison.clause(
                answer: PuzzleEvaluation(centipawns: 300),
                played: PuzzleEvaluation(centipawns: 220)
            ) == nil
        )
    }

    /// The credit exists for cards mined from the user's own game, which store
    /// one arbitrary answer. A corpus puzzle's answer is the only move that
    /// holds the result, and a 40k-node glance rating a second move equal is a
    /// weaker signal contradicting a stronger one.
    @Test("A forced answer is never told it had an equal")
    func forcedAnswersAreNotSecondGuessed() {
        #expect(
            PuzzleMoveComparison.clause(
                answer: PuzzleEvaluation(centipawns: 300),
                played: PuzzleEvaluation(centipawns: 260),
                answerIsForced: true
            ) == nil
        )
        // The criticism is unaffected: a move that really is worse is still
        // named as worse whichever kind of card it came from.
        #expect(
            PuzzleMoveComparison.clause(
                answer: PuzzleEvaluation(centipawns: 600),
                played: PuzzleEvaluation(centipawns: 0),
                answerIsForced: true
            ) == "yours only keeps things level"
        )
    }
}

@Suite("Engine explanations")
struct PuzzleEvaluationTests {

    @Test("Mate outranks any material score, whichever way it falls")
    func mateFoldsToTheExtremes() {
        #expect(PuzzleEvaluation(score: .mate(3)).centipawns == PuzzleEvaluation.mateMagnitude)
        #expect(PuzzleEvaluation(score: .mate(-1)).centipawns == -PuzzleEvaluation.mateMagnitude)
        #expect(PuzzleEvaluation(score: .mate(1)).band == .winning)
        #expect(PuzzleEvaluation(score: .mate(-6)).band == .losing)
    }

    /// The engine reports from the side to move, which after the solver's move
    /// is the opponent. Getting this backwards would praise every blunder.
    @Test("The perspective flips after the move")
    func perspectiveIsNegated() {
        #expect(PuzzleEvaluation(centipawns: 300).negated.centipawns == -300)
    }

    @Test("A move that gives up a winning position is called out")
    func namesTheSquanderedAdvantage() {
        let clause = PuzzleMoveComparison.clause(
            answer: PuzzleEvaluation(centipawns: 600),
            played: PuzzleEvaluation(centipawns: 10)
        )
        #expect(clause == "yours only keeps things level")
    }

    @Test("A move that loses outright says so")
    func namesTheCollapse() {
        let clause = PuzzleMoveComparison.clause(
            answer: PuzzleEvaluation(centipawns: 400),
            played: PuzzleEvaluation(centipawns: -800)
        )
        #expect(clause == "yours leaves you losing")
    }

    /// Puzzles often have a second move that is very nearly as good. Telling the
    /// user it "only keeps things level" would be false coaching.
    ///
    /// This used to assert silence. Silence turned out to be the wrong way to
    /// express it: the banner above still reads `Missed`, so saying nothing
    /// reads as agreeing with that verdict rather than as declining to
    /// criticise. The rule the test exists for is unchanged — a near-equal move
    /// is never called worse — but it is now said out loud.
    @Test("A near-equal move is credited rather than criticised")
    func closeMovesGetNoLecture() {
        let clause = PuzzleMoveComparison.clause(
            answer: PuzzleEvaluation(centipawns: 300),
            played: PuzzleEvaluation(centipawns: 260)
        )
        #expect(clause == "the engine rates yours the same — only one answer is stored here")
        #expect(clause != PuzzleEvaluation.Band.level.playedPhrase)
    }

    @Test("A move in the same band is never called worse")
    func sameBandIsSilent() {
        // A big raw gap, but both moves are winning.
        #expect(
            PuzzleMoveComparison.clause(
                answer: PuzzleEvaluation(centipawns: 2_000),
                played: PuzzleEvaluation(centipawns: 700)
            ) == nil
        )
    }

    /// Mating puzzles are the most common kind, and the position after mate has
    /// no legal moves for an engine to search.
    @Test("A mating move is scored from the board, not the engine")
    func mateNeedsNoEngine() {
        let board = Position(fen: "6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1") ?? .standard
        let mate = PuzzleEvaluation.terminal(playing: "a1a8", in: board)
        #expect(mate?.band == .winning)
        // A move that leaves the game running is left to the engine.
        #expect(PuzzleEvaluation.terminal(playing: "a1a5", in: board) == nil)
    }

    @Test("A missing evaluation explains nothing")
    func degradesWithoutTheEngine() {
        #expect(PuzzleMoveComparison.clause(answer: nil, played: PuzzleEvaluation(centipawns: 0)) == nil)
        #expect(PuzzleMoveComparison.clause(answer: PuzzleEvaluation(centipawns: 500), played: nil) == nil)
    }
}

@Suite("Engine explanation upgrade")
@MainActor
struct PuzzleExplanationUpgradeTests {

    /// The banner appears immediately and *grows* the engine's clause, rather
    /// than making the user wait on two searches for any feedback at all.
    @Test("A wrong move that hangs nothing is explained by the engine")
    func upgradesTheBanner() async {
        let driver = FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5"])])
        let model = PuzzleSessionModel(
            driver: driver,
            evaluator: ScriptedEvaluator(scores: ["e7e5": 500, "b8c6": 0]),
            database: nil
        )
        await model.start()

        // A legal move that is not the answer, and hangs nothing.
        _ = model.attemptMove(from: .b8, to: .c6)
        await model.waitForGrading()

        // The sentence is already on screen before the engine has spoken.
        #expect(model.stage.verdict != nil)

        await model.waitForExplanation()
        let message = model.stage.verdict?.message ?? ""
        #expect(message.contains("But yours only keeps things level."))
    }

    /// A solve used to end at the shortest true sentence available — which for
    /// a capture that cannot prove itself is barely a sentence at all. Solving a
    /// puzzle you did not understand leaves the idea exactly as unlearned as
    /// missing it does.
    @Test("A solved puzzle the board cannot explain is explained by the engine")
    func explainsASolveTheBoardCannotProve() async {
        // The session position from the screenshot, one ply earlier so the
        // machine has a setup move to play.
        let plan = makePlan(
            line: ["b3b4", "c6c4"],
            fen: "2k5/ppp2p1p/2r1qn2/3r2p1/2N1p3/PQ2P2P/2P1NPP1/R3KR2 w - - 0 1"
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [plan]),
            evaluator: ScriptedEvaluator(
                scores: [:],
                lines: ["c6c4": ["b4c4", "d5d1", "e1d1", "e6c4"]]
            ),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .c6, to: .c4)
        await model.waitForGrading()

        // The verdict is up before the engine has said anything.
        #expect(model.stage.verdict?.solved == true)

        await model.waitForExplanation()
        #expect(
            model.stage.verdict?.message
                == "Solved — the rook takes the knight: if they take back, "
                    + "the rook goes to d1 with check."
        )
    }

    @Test("With no engine the banner keeps its shorter sentence")
    func withoutAnEvaluatorNothingChanges() async {
        let driver = FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5"])])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        _ = model.attemptMove(from: .b8, to: .c6)
        await model.waitForGrading()
        await model.waitForExplanation()

        #expect(model.stage.verdict?.message.contains("But") == false)
    }
}

// MARK: - Explaining a miss

/// The position after 1.e4, which is the position every single-move fixture in
/// this file hands to the solver.
private let afterKingPawn = Position(
    fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
) ?? .standard

/// A card mined from the user's own game: no setup move, no corpus rating, and
/// — the property these tests turn on — no guarantee that the stored answer is
/// the only move that works.
private func makeMomentPlan(
    line: [String] = ["e7e5"],
    fen: String = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1",
    kind: SessionItemPlan.Kind = .fresh
) -> SessionItemPlan {
    let item = SolvableItem(
        backing: .momentPosition(momentID: nil),
        fen: fen,
        line: line,
        opponentMovesFirst: false,
        rating: 0,
        primaryTheme: ThemeTag("middlegame")
    )
    return SessionItemPlan(kind: kind, presented: PresentedPuzzle(item: item, preferring: .identity))
}

@Suite("Miss explanations")
@MainActor
struct PuzzleMissExplanationTests {

    /// The stored Lichess continuation is what turns "the rook takes the
    /// knight" into a reason. The engine's clause used to be pasted onto a
    /// banner rebuilt *without* it, so the sentence that showed the mechanism
    /// appeared for a moment and was then crossfaded away by a thinner one —
    /// on precisely the misses where the app had most to say.
    @Test("The engine's clause is added to the stored line, not instead of it")
    func upgradeKeepsTheStoredContinuation() async {
        let plan = makePlan(
            line: ["b3b4", "c6c4", "b4c4", "d5d1", "e1d1", "e6c4"],
            fen: "2k5/ppp2p1p/2r1qn2/3r2p1/2N1p3/PQ2P2P/2P1NPP1/R3KR2 w - - 0 1"
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [plan]),
            evaluator: ScriptedEvaluator(scores: ["c6c4": 600, "c8b8": 0]),
            database: nil
        )
        await model.start()

        // A legal king move that is not the answer and hangs nothing, so the
        // board can prove no mistake and the engine is asked.
        _ = model.attemptMove(from: .c8, to: .b8)
        await model.waitForGrading()

        let mechanism = "if they take back, the rook goes to d1 with check"
        #expect(model.stage.verdict?.message.contains(mechanism) == true)

        await model.waitForExplanation()
        let upgraded = model.stage.verdict?.message ?? ""
        #expect(upgraded.contains(mechanism), "the mechanism must survive the engine's upgrade")
        #expect(upgraded.contains("But yours only keeps things level"))
    }

    /// A band is a verdict with the mechanism removed. Naming the reply is the
    /// check the user did not make.
    @Test("A move the position says is worse is answered with the opponent's reply")
    func namesTheRefutation() async {
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5"], theme: ThemeTag("middlegame"))]),
            evaluator: ScriptedEvaluator(
                scores: ["e7e5": 500, "d7d5": 0],
                lines: ["d7d5": ["e4d5", "d8d5"]]
            ),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .d7, to: .d5)
        await model.waitForGrading()
        await model.waitForExplanation()

        #expect(
            model.stage.verdict?.message
                == "Missed — the pawn to e5. But after your move, their pawn takes the pawn."
        )
    }

    /// The banner reserves four lines and cannot truncate, so the answer's
    /// mechanism and the refutation of the played move share one budget. Where
    /// the stored line has already spent it, the reader has a mechanism in
    /// front of them and the band is the honest short form of the rest.
    @Test("A banner already carrying a mechanism keeps the shorter band phrase")
    func refutationYieldsToTheAnswersOwnExplanation() async {
        let plan = makePlan(
            line: ["b3b4", "c6c4", "b4c4", "d5d1", "e1d1", "e6c4"],
            fen: "2k5/ppp2p1p/2r1qn2/3r2p1/2N1p3/PQ2P2P/2P1NPP1/R3KR2 w - - 0 1"
        )
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [plan]),
            evaluator: ScriptedEvaluator(
                scores: ["c6c4": 600, "c8b8": 0],
                // Qxb7 is legal here and takes a pawn, which is all the
                // fixture needs: the scripted reply stands in for whatever the
                // engine would return, and the assertion below is about
                // length, not about the merits of the move.
                lines: ["c8b8": ["b4b7"]]
            ),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .c8, to: .b8)
        await model.waitForGrading()
        await model.waitForExplanation()

        let message = model.stage.verdict?.message ?? ""
        #expect(message.contains("But yours only keeps things level."))
        #expect(!message.contains("after your move"))
    }

    /// The refutation is attached to the criticism, never on its own: inventing
    /// a punishment for a move the engine rates equal would be the app telling
    /// the user their fine move loses something.
    @Test("A move rated equal is credited, not refuted")
    func noRefutationWithoutACriticism() async {
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [makeMomentPlan()]),
            evaluator: ScriptedEvaluator(
                scores: ["e7e5": 100, "d7d5": 90],
                lines: ["d7d5": ["e4d5", "d8d5"]]
            ),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .d7, to: .d5)
        await model.waitForGrading()
        await model.waitForExplanation()

        let message = model.stage.verdict?.message ?? ""
        #expect(message.contains("the engine rates yours the same"))
        #expect(!message.contains("their"), "no refutation belongs on a move that was not criticised")
    }

    /// The banner says the position cannot tell the two moves apart, and the
    /// set used to hand the same position back twenty seconds later anyway — so
    /// the only thing the retry could teach was to produce the stored move
    /// instead of the one the app had just called its equal.
    @Test("A move rated equal does not earn a same-day retry")
    func equivalentAnswerWithdrawsTheRetry() async {
        let cardID = UUID()
        let driver = FakeDriver(plans: [makeMomentPlan(kind: .review(cardID: cardID))])
        let model = PuzzleSessionModel(
            driver: driver,
            evaluator: ScriptedEvaluator(scores: ["e7e5": 100, "d7d5": 90]),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .d7, to: .d5)
        await model.waitForGrading()
        await model.waitForExplanation()

        #expect(driver.equivalentCredits == [cardID])
    }

    /// The other half of the same contract: a move the engine rates genuinely
    /// worse is a miss like any other, and its card comes back today.
    @Test("A move rated worse keeps its retry")
    func worseAnswerKeepsTheRetry() async {
        let cardID = UUID()
        let driver = FakeDriver(plans: [makeMomentPlan(kind: .review(cardID: cardID))])
        let model = PuzzleSessionModel(
            driver: driver,
            evaluator: ScriptedEvaluator(scores: ["e7e5": 500, "d7d5": 0]),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .d7, to: .d5)
        await model.waitForGrading()
        await model.waitForExplanation()

        #expect(driver.equivalentCredits.isEmpty)
    }

    /// A corpus puzzle's answer is the only move that holds the result, and a
    /// 40k-node glance is not evidence against that. Saying nothing is the
    /// honest answer; crediting the user's move overrides a stronger signal
    /// with a weaker one, on exactly the puzzles whose idea is hardest.
    @Test("A corpus puzzle is never told its answer had an equal")
    func corpusAnswersAreNotSecondGuessed() async {
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5"], theme: ThemeTag("middlegame"))]),
            evaluator: ScriptedEvaluator(scores: ["e7e5": 100, "d7d5": 90]),
            database: nil
        )
        await model.start()

        _ = model.attemptMove(from: .d7, to: .d5)
        await model.waitForGrading()
        await model.waitForExplanation()

        #expect(model.stage.verdict?.message == "Missed — the pawn to e5.")
    }

    /// A hint spends the attempt, so the banner says `Missed`. It does not make
    /// the move wrong — and the miss path used to explain the answer as an
    /// error, so a hinted Qh5 came back as `But your queen could be taken by
    /// the pawn`: the app arguing with the move it had just handed over.
    @Test("A hinted solve is never explained as a mistake")
    func hintedSolveIsNotCriticised() async {
        // White's Qd1-h5 lands on a square the g6 pawn attacks, which is
        // exactly the shape `PuzzleReason.mistake` fires on.
        let plan = makePlan(
            line: ["h7h6", "d1h5"],
            fen: "4k3/pppp3p/6p1/8/8/8/PPPP1PPP/3QK3 b - - 0 1",
            theme: ThemeTag("middlegame")
        )
        let model = PuzzleSessionModel(driver: FakeDriver(plans: [plan]), database: nil)
        await model.start()

        model.revealHint()
        model.revealHint()
        #expect(model.hintMove == "d1h5")

        _ = model.attemptMove(from: .d1, to: .h5)
        await model.waitForGrading()
        await model.waitForExplanation()

        let verdict = model.stage.verdict
        #expect(verdict?.solved == false, "a hint spends the attempt")
        #expect(verdict?.message == "Missed — the queen to h5.")
        #expect(verdict?.ring == nil, "there is no missed answer to mark")
        #expect(verdict?.answer == nil, "the answer is already on the board")
    }
}

// MARK: - The hint ladder

@Suite("Hint ladder")
struct PuzzleHintLadderTests {

    /// The nudge prunes the search without finishing it, so it may describe the
    /// move and must never identify it.
    @Test("The nudge names the kind of move and no square")
    func nudgeNamesTheKind() {
        let nudge = PuzzleReason.nudge(forAnswer: "d7d5", in: afterKingPawn)
        #expect(
            nudge == "No check, no capture — the move makes a threat. Ask what your pieces would hit next."
        )
        for identifier in ["d5", "d7", "queen", "knight"] {
            #expect(nudge?.contains(identifier) != true)
        }
    }

    @Test("A capture and a check are described as such")
    func nudgeSeparatesTheClasses() {
        let afterD5 = Position(
            fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2"
        ) ?? .standard
        #expect(
            PuzzleReason.nudge(forAnswer: "e4d5", in: afterD5)
                == "The move takes something. Work out what takes back first."
        )
        // Ra1-a8 is mate: the king is on g8 with its own pawns in front of it.
        let backRank = Position(fen: "6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1") ?? .standard
        #expect(
            PuzzleReason.nudge(forAnswer: "a1a8", in: backRank)
                == "The move ends the game. Go through every check."
        )
    }
}

// MARK: - The reply to the move you played

@Suite("Refuting the played move")
struct PuzzleRefutationTests {

    @Test("A capturing reply is named")
    func capturingReplyIsNamed() {
        #expect(
            PuzzleReason.punishment(reply: "e4d5", afterPlaying: "d7d5", in: afterKingPawn)
                == "their pawn takes the pawn"
        )
    }

    /// "And now they are simply better" is the judgement the band phrase has
    /// already made, and the reader cannot check it on the board.
    @Test("A quiet reply says nothing")
    func quietReplyStaysSilent() {
        #expect(PuzzleReason.punishment(reply: "g1f3", afterPlaying: "b8c6", in: afterKingPawn) == nil)
    }
}

// MARK: - Material in a line

/// `line.won` is a list of the solver's captures, which is not an outcome. The
/// rule these two guard is that "you win the rook" is only ever said when the
/// line's *net* supports it.
@Suite("Material across a continuation")
struct PuzzleLineMaterialTests {

    /// Black's rook goes to d8, White takes it, Black takes back. An even trade
    /// is not a win, and Lichess lines for quiet themes routinely contain one.
    private let quietRookMove = Position(fen: "r4rk1/8/8/8/8/8/8/3R2K1 b - - 0 1") ?? .standard

    @Test("An exchange inside the line is not reported as winning material")
    func exchangeIsNotAWin() {
        let clause = PuzzleReason.clause(
            forAnswer: "a8d8",
            in: quietRookMove,
            continuation: ["d1d8", "f8d8"]
        )
        #expect(clause == nil)
    }

    /// The control: the same move, with the opponent declining to take. Now the
    /// rook really is won and the clause says so.
    @Test("A line the opponent does not take back in does win the piece")
    func unansweredCaptureIsAWin() {
        let clause = PuzzleReason.clause(
            forAnswer: "a8d8",
            in: quietRookMove,
            continuation: ["g1h1", "d8d1"]
        )
        #expect(clause == "after their king goes to h1, you win the rook")
    }
}

// MARK: - The SRS latency clock

@Suite("Latency clock")
@MainActor
struct PuzzleLatencyClockTests {

    /// `TrainingService` grades, persists and advances in one call, so the
    /// instant it starts serving the next item is the instant the user
    /// submitted the last one — with that item's banner still on screen. Every
    /// reading therefore carried the previous banner's dwell, and the first
    /// review of a set that opened with a lesson carried the whole lesson.
    @Test("The clock restarts when the position appears, not when the last was graded")
    func clockFollowsTheBoard() async {
        let driver = FakeDriver(plans: [
            makePlan(line: ["e2e4", "e7e5"]),
            makePlan(line: ["e2e4", "e7e5"])
        ])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()
        #expect(driver.itemShownCount == 1)

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        // The banner is up and the service has already advanced. Nothing has
        // restarted the clock, so the reading time is not being charged to the
        // next puzzle.
        #expect(driver.itemShownCount == 1)

        model.continueAfterVerdict()
        #expect(driver.itemShownCount == 2)

        // And again once the setup move has finished animating, which is what
        // the screen calls after its 380ms.
        model.markPositionInteractive()
        #expect(driver.itemShownCount == 3)
    }
}

// MARK: - Summary accounting

@Suite("Session summary accounting")
struct SessionSummaryAccountingTests {

    /// `8 / 12` mixed first recall with re-recall of an answer the user had
    /// been shown minutes earlier.
    @Test("Retries are counted apart from first attempts")
    func retriesHaveTheirOwnRow() {
        let progress = SessionProgress(
            index: 11,
            completed: 12,
            total: 12,
            solved: 8,
            hinted: 1,
            retries: 2,
            retriesSolved: 1
        )
        #expect(progress.firstAttempts == 10)
        #expect(progress.solvedLabel == "8/10")
        #expect(progress.retriesLabel == "1/2 clean")
    }

    @Test("A set with nothing to retry has no retry row")
    func noRetriesNoRow() {
        let progress = SessionProgress(completed: 10, total: 10, solved: 9)
        #expect(progress.retriesLabel == nil)
        #expect(progress.solvedLabel == "9/10")
    }
}

@Suite("Retry accounting through a session")
@MainActor
struct SessionRetryAccountingTests {

    @Test("A same-day retry lands on the retry row, not on Solved")
    func relearnCountsAsASecondLook() async {
        let card = UUID()
        let driver = FakeDriver(plans: [
            makePlan(line: ["e2e4", "e7e5"], kind: .review(cardID: card)),
            makePlan(line: ["e2e4", "e7e5"], kind: .relearn(cardID: card))
        ])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        model.continueAfterVerdict()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()

        #expect(model.progress.solved == 1)
        #expect(model.progress.retries == 1)
        #expect(model.progress.retriesSolved == 1)
        #expect(model.progress.solvedLabel == "1/1")
    }
}

// MARK: - Opening variations

/// One stored move order is a move order, not an opening: the first thing a
/// real opponent does is deviate, and that is the position the exercise never
/// showed. These hold the alternatives to the same standard as the main lines.
@Suite("Opening variations")
struct OpeningVariationTests {

    @Test("Every alternative opening line is legal and ends on the solver's move")
    func alternativesAreLegal() throws {
        for concept in TrainingConcept.catalogue {
            guard case let .line(fen, _, opponentMovesFirst) = concept.exercise else {
                #expect(
                    concept.alternateLines.isEmpty,
                    "\(concept.id): alternatives with no stored line to replace"
                )
                continue
            }

            for (variant, moves) in concept.alternateLines.enumerated() {
                let start = try #require(Position(fen: fen), "\(concept.id): unparseable FEN")
                var board = Board(position: start)

                for (index, uci) in moves.enumerated() {
                    #expect(
                        PuzzleSolveMachine.move(uci: uci, on: &board) != nil,
                        "\(concept.id) variation \(variant): move \(index) (\(uci)) is not legal"
                    )
                }

                // As for the main line: the solver has to have the last word, or
                // the exercise ends on the opponent's move and the user is left
                // holding a finished board.
                let solverPlaysEvenIndices = !opponentMovesFirst
                let lastIsSolvers = (moves.count - 1) % 2 == (solverPlaysEvenIndices ? 0 : 1)
                #expect(
                    lastIsSolvers,
                    "\(concept.id) variation \(variant): the line ends on the opponent's move"
                )
            }
        }
    }

    @Test("An opening with alternatives serves a different line each visit")
    func variationsRotate() throws {
        let target = try #require(
            TrainingConcept.catalogue.first { !$0.alternateLines.isEmpty },
            "the catalogue has no branching opening left"
        )
        let variations = target.lineVariations

        var served: [[String]] = []
        for visit in 0..<variations.count {
            // Everything else exhausted, so the scheduler has to pick `target`
            // and the only thing changing between visits is its own count.
            var states: [String: ConceptScheduler.State] = [:]
            for concept in TrainingConcept.catalogue {
                states[concept.id] = ConceptScheduler.State(
                    id: concept.id,
                    isIntroduced: true,
                    timesSeen: concept.id == target.id ? visit : visit + 100,
                    lastSeenAt: Date(timeIntervalSince1970: 0)
                )
            }

            let selection = try #require(ConceptScheduler.next(rating: 3000, rung: 4, states: states))
            #expect(selection.concept.id == target.id)
            guard case let .line(_, moves, _) = selection.concept.exercise else {
                Issue.record("\(target.id): expected a line exercise")
                return
            }
            served.append(moves)
        }

        #expect(served.first == variations.first, "the first visit plays the line the lesson taught")
        #expect(
            Set(served.map { $0.joined(separator: " ") }).count == variations.count,
            "a visit replayed a line an earlier visit had already served"
        )
    }
}

// MARK: - Concept routing

@Suite("Concept routing")
struct ConceptRoutingTests {

    /// Every concept taught, the openings worked hardest, so nothing in the
    /// rotation would come back to an opening on its own.
    private func exhaustedOpenings() -> [String: ConceptScheduler.State] {
        var states: [String: ConceptScheduler.State] = [:]
        for concept in TrainingConcept.catalogue {
            states[concept.id] = ConceptScheduler.State(
                id: concept.id,
                isIntroduced: true,
                timesSeen: concept.family == .opening ? 50 : 0,
                lastSeenAt: Date(timeIntervalSince1970: 0)
            )
        }
        return states
    }

    @Test("Opening mistakes in real games bring the opening slot back")
    func openingPressurePromotesTheFamily() throws {
        let states = exhaustedOpenings()

        let calm = try #require(ConceptScheduler.next(rating: 1600, rung: 3, states: states))
        #expect(calm.concept.family != .opening, "nothing here asks for an opening")

        let pressured = try #require(
            ConceptScheduler.next(rating: 1600, rung: 3, states: states, openingMistakesPerGame: 1.2)
        )
        #expect(pressured.concept.family == .opening)
    }

    @Test("An opening the games say is fine does not jump the queue")
    func pressureBelowThresholdChangesNothing() throws {
        let states = exhaustedOpenings()
        let selection = try #require(
            ConceptScheduler.next(rating: 1600, rung: 3, states: states, openingMistakesPerGame: 0.2)
        )
        #expect(selection.concept.family != .opening)
    }

    @Test("The endgame habit puts an endgame in the slot")
    func endgameHabitSteersTheSlot() throws {
        var states: [String: ConceptScheduler.State] = [:]
        for concept in TrainingConcept.catalogue {
            states[concept.id] = ConceptScheduler.State(
                id: concept.id,
                isIntroduced: true,
                timesSeen: concept.family == .endgame ? 50 : 0,
                lastSeenAt: Date(timeIntervalSince1970: 0)
            )
        }

        let selection = try #require(
            ConceptScheduler.next(rating: 1600, rung: 3, states: states, focus: .endgameTechnique)
        )
        #expect(selection.concept.family == .endgame)
    }

    /// Blunder-checking is not a subject with a lesson behind it. Pretending it
    /// is would put an unrelated opening in front of the user and call it the
    /// answer to their leak.
    @Test("A habit no lesson teaches leaves the rotation alone")
    func habitWithoutAFamilyDoesNotSteerTheSlot() throws {
        // The ladder's own asks are taught already, so the rotation is what is
        // deciding here — which is what this test is about. Left untaught they
        // would win either call, and the comparison would pass for the wrong
        // reason.
        var states: [String: ConceptScheduler.State] = [:]
        for id in Curriculum.requiredConcepts(throughRung: 3) {
            states[id] = ConceptScheduler.State(id: id, isIntroduced: true)
        }

        let plain = try #require(ConceptScheduler.next(rating: 1600, rung: 3, states: states))
        let steered = try #require(
            ConceptScheduler.next(rating: 1600, rung: 3, states: states, focus: .blunderCheck)
        )
        #expect(plain.concept.id == steered.concept.id)
    }
}

// MARK: - Game-mistake cards

/// `CardPolicy` ranks a game mistake above every corpus puzzle, but only within
/// one call — and cards are admitted twice a day from two places. A day that
/// spent its cap on puzzles first used to defer the user's own blunders to a
/// queue that does not exist.
@MainActor
@Suite("Game-mistake cards")
struct GameMistakeCardTests {

    private static let momentFEN = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"

    private func moment(at now: Date) -> Database.Moment {
        Database.Moment(
            gameID: UUID(),
            ply: 4,
            fen: Self.momentFEN,
            kind: "blunder",
            causeTag: "hungMovedPiece",
            stepTag: "play",
            playedSAN: "Qh5",
            playedUCI: "d1h5",
            bestSAN: "Nf3",
            bestUCI: "g1f3",
            deltaEP: 0.4,
            score: 1,
            createdAt: now,
            srsEligible: true
        )
    }

    @Test("A game mistake still becomes a card after puzzles spent the day's cap")
    func gameMistakeKeepsASlot() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cap = DomainTuning.default.cards.newCardsPerDay
        let srs = InMemorySRSStore()
        let metrics = InMemoryMetricStore()
        try metrics.set(
            TrainingMetricKeys.newCardsAdmitted,
            window: DailyLoop.dayKey(for: now),
            value: Double(cap),
            sampleCount: cap,
            at: now
        )

        let service = TrainingService(
            srs: srs,
            corpus: InMemoryPuzzleCorpus(puzzles: []),
            metrics: metrics,
            dailyLoop: InMemoryDailyLoopStore(),
            settings: InMemoryAppSettingsStore(),
            clock: { now }
        )

        let created = await service.createCards(fromMoments: [moment(at: now)])

        let stored = try srs.card(positionKey: PositionKey.make(fen: Self.momentFEN))
        #expect(created == 1, "the user's own blunder must not lose its slot to a corpus puzzle")
        #expect(stored != nil)
        // The day's tally still reports what was actually created, cap or no cap.
        #expect(
            metrics.value(TrainingMetricKeys.newCardsAdmitted, window: DailyLoop.dayKey(for: now))
                == Double(cap + 1)
        )
    }

    @Test("The reserved slot is one card, not an open door")
    func onlyOneSlotIsReserved() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cap = DomainTuning.default.cards.newCardsPerDay
        let srs = InMemorySRSStore()
        let metrics = InMemoryMetricStore()
        try metrics.set(
            TrainingMetricKeys.newCardsAdmitted,
            window: DailyLoop.dayKey(for: now),
            value: Double(cap),
            sampleCount: cap,
            at: now
        )

        let service = TrainingService(
            srs: srs,
            corpus: InMemoryPuzzleCorpus(puzzles: []),
            metrics: metrics,
            dailyLoop: InMemoryDailyLoopStore(),
            settings: InMemoryAppSettingsStore(),
            clock: { now }
        )

        let positions = [
            Self.momentFEN,
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
            "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"
        ]
        let moments = positions.enumerated().map { index, fen -> Database.Moment in
            var value = moment(at: now)
            value.ply = 4 + index * 2
            value.fen = fen
            return value
        }

        let created = await service.createCards(fromMoments: moments)
        #expect(created == 1)
    }
}

// MARK: - Calculation set

/// The user's stored puzzle rating for the calculation tests.
///
/// Chosen so the daily serving band (`1150...1450`) and the calculation band
/// (`1500...1600`) are both round numbers and provably disjoint — the tests
/// below assert on those numbers, so a fixture that let them touch would let a
/// substituted puzzle pass unnoticed.
private let calculationUserRating = 1300

private func makeCorpusPuzzle(
    id: String,
    rating: Int,
    moves: String,
    themes: [PuzzleTheme] = [.fork]
) -> Puzzle {
    Puzzle(
        id: id,
        fen: startFEN,
        moves: moves,
        rating: rating,
        ratingDev: 50,
        popularity: 100,
        nbPlays: 1000,
        themes: ThemeMask(themes)
    )
}

/// Setup move plus a solution of `plies` moves, all legal from the start
/// position, so the same fixture can be replayed by a real solve machine.
private func solutionLine(plies: Int) -> String {
    let all = ["e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "g8f6"]
    return all.prefix(1 + max(1, min(plies, all.count - 1))).joined(separator: " ")
}

@Suite("Calculation set assembly")
struct CalculationAssemblyTests {

    @Test("The longest line in the band leads the set")
    func longestLinesFirst() {
        var tuning = DomainTuning.default.calculation
        tuning.setSize = 2

        let session = SessionAssembler.calculationSet(
            candidates: [
                makeCorpusPuzzle(id: "short", rating: 1550, moves: solutionLine(plies: 1)),
                makeCorpusPuzzle(id: "longest", rating: 1550, moves: solutionLine(plies: 5)),
                makeCorpusPuzzle(id: "medium", rating: 1550, moves: solutionLine(plies: 3))
            ],
            tuning: tuning
        )

        // Longest first, because a user who stops after one has then spent
        // their attention on the deepest line the band could offer.
        #expect(session.items.map(\.presented.item.puzzleID) == ["longest", "medium"])
    }

    @Test("Every item is a fresh calculation item and no card is retired")
    func itemsAreMarked() {
        let session = SessionAssembler.calculationSet(
            candidates: [makeCorpusPuzzle(id: "a", rating: 1550, moves: solutionLine(plies: 3))]
        )

        #expect(session.items.count == 1)
        #expect(session.items.allSatisfy { $0.isCalculation })
        #expect(session.items.allSatisfy { $0.kind == .fresh })
        // Retirement is `SessionBuilder`'s verdict on a card that has finished
        // the anti-memorization ladder. Nothing here has seen a card at all, so
        // reporting one would retire it on the strength of a session it was
        // never in.
        #expect(session.retired.isEmpty)
    }

    @Test("A short band serves what it has rather than padding the set")
    func shortBandIsNotPadded() {
        var tuning = DomainTuning.default.calculation
        tuning.setSize = 3

        let session = SessionAssembler.calculationSet(
            candidates: [
                makeCorpusPuzzle(id: "a", rating: 1550, moves: solutionLine(plies: 3)),
                makeCorpusPuzzle(id: "b", rating: 1550, moves: solutionLine(plies: 3))
            ],
            tuning: tuning
        )
        #expect(session.items.count == 2)
    }

    @Test("An empty band produces an empty set, never a substitute")
    func emptyBandProducesNothing() {
        #expect(SessionAssembler.calculationSet(candidates: []).items.isEmpty)
    }

    @Test("The calculation band sits entirely above the daily serving band")
    func bandsDoNotOverlap() {
        let daily = TrainingVocabulary.servingBand(userPuzzleRating: calculationUserRating)
        let raised = TrainingVocabulary.calculationBand(userPuzzleRating: calculationUserRating)

        // The card's promise in one assertion: nothing this set can serve is
        // something the daily set could have served.
        #expect(raised.lowerBound > daily.upperBound)
        #expect(raised.lowerBound == 1500)
        #expect(raised.upperBound == 1600)
    }
}

/// Everything the calculation set writes to, so a test can run one and then read
/// what it did — and, more to the point, what it left alone.
@MainActor
private struct CalculationHarness {

    let srs = InMemorySRSStore()
    let metrics = InMemoryMetricStore()
    let dailyLoop = InMemoryDailyLoopStore()
    let settings: InMemoryAppSettingsStore
    let corpus: InMemoryPuzzleCorpus

    init(puzzles: [Puzzle], cards: [SRSCard] = []) {
        corpus = InMemoryPuzzleCorpus(puzzles: puzzles)
        settings = InMemoryAppSettingsStore(
            settings: AppSettings(puzzleRating: Double(calculationUserRating), puzzleRD: 40)
        )
        for card in cards { try? srs.save(card) }
    }

    func service() -> TrainingService {
        TrainingService(
            srs: srs,
            corpus: corpus,
            metrics: metrics,
            dailyLoop: dailyLoop,
            settings: settings
        )
    }

    /// Answers every item by skipping it, which is graded as a failure and runs
    /// the whole persistence path.
    func skipAll(_ service: TrainingService) async {
        var iterations = 0
        while service.phase == .solving, iterations < 40 {
            await service.skip()
            iterations += 1
        }
    }
}

@MainActor
@Suite("Calculation set service")
struct CalculationServiceTests {

    /// One puzzle in the daily band, two in the raised one.
    private func mixedCorpus() -> [Puzzle] {
        [
            makeCorpusPuzzle(id: "daily", rating: calculationUserRating, moves: solutionLine(plies: 1)),
            makeCorpusPuzzle(id: "raised-long", rating: 1550, moves: solutionLine(plies: 5), themes: [.long]),
            makeCorpusPuzzle(id: "raised-short", rating: 1520, moves: solutionLine(plies: 1))
        ]
    }

    @Test("Only puzzles from above the user's band are served")
    func servesTheRaisedBandOnly() async {
        let harness = CalculationHarness(puzzles: mixedCorpus())
        let service = harness.service()

        await service.startCalculationSet()

        let served = service.session.items.map(\.presented.item.puzzleID)
        #expect(!served.contains("daily"))
        #expect(served.contains("raised-long"))
        // Whatever came back, every one of it is above the daily band's ceiling.
        let ceiling = TrainingVocabulary.servingBand(userPuzzleRating: calculationUserRating).upperBound
        #expect(service.session.items.allSatisfy { $0.presented.item.rating > ceiling })
        #expect(service.session.items.allSatisfy { $0.isCalculation })
    }

    @Test("A band with nothing in it serves nothing rather than dropping to the daily band")
    func emptyRaisedBandServesNothing() async {
        // A corpus that stops below the raised band — the state a user reaches
        // by outgrowing it. Sliding the band down to fill the set is exactly the
        // substitution the mode exists to prevent.
        let harness = CalculationHarness(
            puzzles: [makeCorpusPuzzle(id: "daily", rating: calculationUserRating, moves: solutionLine(plies: 1))]
        )
        let service = harness.service()

        await service.startCalculationSet()

        #expect(service.session.items.isEmpty)
        #expect(service.phase == .finished)
    }

    @Test("A missed calculation puzzle does not become a card")
    func missesDoNotAdmitCards() async {
        let harness = CalculationHarness(puzzles: mixedCorpus())
        let service = harness.service()

        await service.startCalculationSet()
        await harness.skipAll(service)

        // Skipping is graded as a failure, which is what admits a card out of
        // the daily set. Here it must not: `newCardsPerDay` is three, and a set
        // the user is *expected* to miss would spend the whole day's cap before
        // the daily set or a game had a chance at it.
        #expect(service.summary.newCards == 0)
        #expect((try? harness.srs.card(puzzleID: "raised-long")) == nil)
        #expect((try? harness.srs.dueCount(at: Date())) == 0)
    }

    @Test("A calculation miss does not move the rung-2 theme counters")
    func missesDoNotMoveTheThemeGate() async {
        let floor = DomainTuning.default.curriculum.themeRatingFloor
        let harness = CalculationHarness(
            puzzles: [makeCorpusPuzzle(id: "raised", rating: 1550, moves: solutionLine(plies: 3), themes: [.fork])]
        )
        let service = harness.service()

        await service.startCalculationSet()
        await harness.skipAll(service)

        // The gate reads a success rate per theme at 1200+, and the fixture is
        // well above that floor — so without the exclusion the user's fork
        // number would have gone down for doing the hardest work of their day.
        #expect(harness.metrics.value(TrainingMetricKeys.themeAttempts(.fork, ratingFloor: floor)) == 0)
        #expect(harness.metrics.value(TrainingMetricKeys.themeSolves(.fork, ratingFloor: floor)) == 0)
    }

    @Test("A served calculation puzzle is still recorded, so it is not handed back next week")
    func servedPuzzlesAreRecorded() async {
        let harness = CalculationHarness(
            puzzles: [makeCorpusPuzzle(id: "raised", rating: 1550, moves: solutionLine(plies: 3))]
        )
        let service = harness.service()

        await service.startCalculationSet()
        await harness.skipAll(service)

        #expect(ServedPuzzleHistory.recentlyServed(metrics: harness.metrics).contains("raised"))
    }

    @Test("A due review card is left untouched by a calculation set")
    func reviewQueueIsUntouched() async {
        let now = Date()
        let due = SRSCard(
            kind: SRSCardKind.puzzle.rawValue,
            puzzleID: "daily",
            fen: startFEN,
            due: now.addingTimeInterval(-3600)
        )
        let harness = CalculationHarness(puzzles: mixedCorpus(), cards: [due])
        let service = harness.service()

        await service.startCalculationSet()
        await harness.skipAll(service)

        // Not served, and still due afterwards: the calculation set reads no
        // cards, so the daily set assembled next sees the queue it would have
        // seen.
        #expect(service.session.items.allSatisfy { $0.kind.cardID == nil })
        #expect((try? harness.srs.dueCount(at: now)) == 1)
        #expect((try? harness.srs.reviews(forCard: due.id))?.isEmpty == true)
    }
}

@MainActor
@Suite("Calculation set framing")
struct CalculationFramingTests {

    private func plan() -> SessionItemPlan {
        makePlan(line: ["e2e4", "e7e5", "g1f3", "b8c6"])
    }

    @Test("A calculation session asks the driver for the calculation queue")
    func asksForTheRightQueue() async {
        let driver = FakeDriver(plans: [plan()])
        let model = PuzzleSessionModel(driver: driver, database: nil, isCalculationSet: true)
        await model.start()

        #expect(driver.startedCalculationSet)
    }

    @Test("An ordinary session does not")
    func ordinarySessionAsksForTheDailyQueue() async {
        let driver = FakeDriver(plans: [plan()])
        let model = PuzzleSessionModel(driver: driver, database: nil)
        await model.start()

        #expect(!driver.startedCalculationSet)
    }

    @Test("The task line asks for the whole line rather than the best move")
    func taskLineNamesTheSlowMode() async {
        let model = PuzzleSessionModel(
            driver: FakeDriver(plans: [plan()]),
            database: nil,
            isCalculationSet: true
        )
        await model.start()

        let line = model.taskLine
        #expect(line == "Black to play — work the whole line out before you move.")
        // "Find the best move" is an instruction to end the search quickly,
        // which is the opposite of what this set is asking for.
        #expect(!line.contains("find the best move"))
        // The theme is still never named — a tactic you have been told the name
        // of is a lookup rather than a search.
        #expect(!line.lowercased().contains("fork"))
    }

    @Test("The header names the mode and says nothing is timed")
    func headerNamesTheMode() async {
        let calculation = PuzzleSessionModel(
            driver: FakeDriver(plans: [plan()]),
            database: nil,
            isCalculationSet: true
        )
        await calculation.start()

        let note = calculation.modeNote
        #expect(note == "Calculation set — above your rating band, no clock")
        // Both standing facts have to be on screen somewhere, and the task line
        // deliberately carries neither: the board would lose a line of height on
        // every puzzle to two sentences that never change.
        #expect(note?.contains("above your rating band") == true)
        #expect(note?.contains("no clock") == true)

        let ordinary = PuzzleSessionModel(driver: FakeDriver(plans: [plan()]), database: nil)
        await ordinary.start()
        #expect(ordinary.modeNote == nil)
    }

    @Test("An empty calculation set explains its own band instead of the daily one")
    func emptySetExplainsTheRaisedBand() async {
        let model = PuzzleSessionModel(driver: FakeDriver(plans: []), database: nil, isCalculationSet: true)
        await model.start()

        guard case let .unavailable(message) = model.stage else {
            Issue.record("expected an explanation, got \(model.stage)")
            return
        }
        #expect(message.contains("calculation set"))
        // The daily set's message offers the one thing that refills *its* band.
        // A mined position is never above the user's rating, so offering it here
        // would hand a stuck user an action that cannot work.
        #expect(!message.contains("Playing a game"))
    }
}

@Suite("Calculation card copy")
struct CalculationCopyTests {

    @Test("The button names the step and its cost")
    func buttonNamesStepAndCost() {
        let title = CalculationCopy.title(puzzles: 3, minutes: 12)
        #expect(title == "Calculation · 3 puzzles · ~12 min")
        // The generic CTA the craft standards rule out by name.
        #expect(title != "Start")
        #expect(title != "Continue")
    }

    @Test("A single puzzle is not called one puzzles")
    func singularCount() {
        #expect(CalculationCopy.title(puzzles: 1, minutes: 4) == "Calculation · 1 puzzle · ~4 min")
    }

    @Test("The offer states the distance above the user and the absence of a clock")
    func offerNamesTheDifference() {
        let copy = CalculationCopy.offer(offsetLabel: "200–300", minutesPerPuzzle: 4)

        #expect(copy.contains("200–300 points above you"))
        #expect(copy.contains("no clock"))
        #expect(copy.contains("worked out rather than recognised"))
        #expect(copy.contains("4 minutes"))
        // Nothing that reads as speed: the daily set has already taught the user
        // that a fast answer is the good one.
        #expect(!copy.lowercased().contains("quick"))
        #expect(!copy.lowercased().contains("fast"))
    }

    @Test("An unservable band names the band rather than hiding or apologising")
    func emptyBandNamesItself() {
        let copy = CalculationCopy.emptyBand(1750...1850)

        #expect(copy.contains("1750–1850"))
        #expect(copy.contains("Your daily set is unaffected."))
        // No offer of a set that cannot be served, under any wording.
        #expect(!copy.contains("Calculation ·"))
        // Not consolation: it states the cause, and never softens it.
        #expect(!copy.lowercased().contains("sorry"))
        #expect(!copy.lowercased().contains("don't worry"))
    }
}
