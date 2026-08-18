//
//  TrainSessionTests.swift
//  ChessCoachTests
//

import BoardUI
import ChessKit
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
    theme: ThemeTag = .fork,
    rating: Int = 1200,
    kind: SessionItemPlan.Kind = .fresh
) -> SessionItemPlan {
    let item = SolvableItem(
        backing: .corpusPuzzle(id: UUID().uuidString),
        fen: startFEN,
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
    var loadFailure: String?
    /// Rating change applied on every graded item, so the summary's delta has
    /// something to report.
    var ratingStepPerItem: Double = 0

    private(set) var currentIndex = 0
    private(set) var solveMachine: PuzzleSolveMachine?
    private(set) var hintsRequested = 0

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

    private func begin() {
        guard let plan = itemOnScreen else {
            solveMachine = nil
            return
        }
        var machine = plan.presented.machine(retryPolicy: plan.retryPolicy)
        machine?.start()
        solveMachine = machine
    }

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

    @Test("With no answer to point at, the concept still gets named")
    func noAnswer() {
        #expect(
            PuzzleConcept.verdictMessage(solved: false, theme: .skewer, answer: nil)
                == "Missed — the idea was a skewer."
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
        let model = PuzzleSessionModel(driver: driver)
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
        let model = PuzzleSessionModel(driver: driver)
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

    @Test("A wrong move fails the attempt, snaps the piece back and names the concept")
    func wrongMoveFails() async {
        let driver = FakeDriver(plans: [singleMovePlan(theme: .pin)])
        let model = PuzzleSessionModel(driver: driver)
        await model.start()

        let acceptance = model.attemptMove(from: .d7, to: .d5)
        if case .rejected = acceptance {} else { Issue.record("a wrong move must snap back") }

        await model.waitForGrading()

        let verdict = model.stage.verdict
        #expect(verdict?.solved == false)
        #expect(verdict?.message == "Missed — the pin was on the e-file.")
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
        let model = PuzzleSessionModel(driver: driver)
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
        let model = PuzzleSessionModel(driver: driver)
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
        let model = PuzzleSessionModel(driver: driver)
        await model.start()

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

    @Test("A second hint on the same item does not double-count")
    func hintIsIdempotentPerItem() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        let model = PuzzleSessionModel(driver: driver)
        await model.start()

        model.revealHint()
        model.revealHint()
        #expect(driver.hintsRequested == 1)
    }

    @Test("Skipping is graded as a failure")
    func skipCountsAsFailure() async {
        let driver = FakeDriver(plans: [singleMovePlan(theme: .fork)])
        let model = PuzzleSessionModel(driver: driver)
        await model.start()

        await model.skip()

        #expect(model.stage.verdict?.solved == false)
        #expect(model.progress.completed == 1)
        #expect(model.missed.map(\.concept) == ["fork"])
    }

    @Test("Continue advances to the next puzzle and moves the counter")
    func continueAdvances() async {
        let driver = FakeDriver(plans: [singleMovePlan(), twoMovePlan()])
        let model = PuzzleSessionModel(driver: driver)
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

    @Test("The session ends in a summary with the rating delta")
    func summaryAtTheEnd() async {
        let driver = FakeDriver(plans: [singleMovePlan()])
        driver.ratingStepPerItem = 12
        let model = PuzzleSessionModel(driver: driver, clock: TestClock(step: 252).next)
        await model.start()

        _ = model.attemptMove(from: .e7, to: .e5)
        await model.waitForGrading()
        model.continueAfterVerdict()

        #expect(model.stage == .summary)
        #expect(model.progress.ratingDelta == 12)
        #expect(model.progress.timeLabel == "04:12")
        #expect(model.progress.solvedLabel == "1/1")
    }

    @Test("A session that assembles nothing goes straight to the summary")
    func emptySession() async {
        let model = PuzzleSessionModel(driver: FakeDriver(plans: []))
        await model.start()
        #expect(model.stage == .summary)
    }

    @Test("A session that failed to load says so instead of showing an empty board")
    func loadFailure() async {
        let driver = FakeDriver(plans: [])
        driver.loadFailure = "no database"
        let model = PuzzleSessionModel(driver: driver)
        await model.start()
        #expect(model.stage == .unavailable("no database"))
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
}
