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
        #expect(verdict?.message == "Missed — the pawn to e5: a pin.")
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
        #expect(clause == "it forks the king and rook — both attacked, and only one can move away")
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

    @Test("A capture names what it wins")
    func namesTheCapture() {
        let clause = PuzzleReason.clause(
            forAnswer: "d1d8",
            in: position("3q4/8/8/7k/8/8/8/3R2K1 w - - 0 1")
        )
        #expect(clause == "it wins the queen")
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
        #expect(clause?.contains("only one can move away") == true, "and it has to be explained")
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
        #expect(missed.contains("forks the king and rook — both attacked, and only one can move away"))
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
        let model = PuzzleSessionModel(driver: driver)
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

    func evaluate(fen: String, playing uci: String) async -> PuzzleEvaluation? {
        scores[uci].map(PuzzleEvaluation.init(centipawns:))
    }
}

/// Most wrong moves hang nothing — they are simply not the best. The board
/// cannot say why; the engine can.
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
    @Test("A near-equal move is not criticised")
    func closeMovesGetNoLecture() {
        #expect(
            PuzzleMoveComparison.clause(
                answer: PuzzleEvaluation(centipawns: 300),
                played: PuzzleEvaluation(centipawns: 260)
            ) == nil
        )
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
            evaluator: ScriptedEvaluator(scores: ["e7e5": 500, "b8c6": 0])
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

    @Test("With no engine the banner keeps its shorter sentence")
    func withoutAnEvaluatorNothingChanges() async {
        let driver = FakeDriver(plans: [makePlan(line: ["e2e4", "e7e5"])])
        let model = PuzzleSessionModel(driver: driver)
        await model.start()

        _ = model.attemptMove(from: .b8, to: .c6)
        await model.waitForGrading()
        await model.waitForExplanation()

        #expect(model.stage.verdict?.message.contains("But") == false)
    }
}
