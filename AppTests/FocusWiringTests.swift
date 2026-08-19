//
//  FocusWiringTests.swift
//  ChessCoachTests
//

import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// MARK: - Fixtures

/// The standard opening position, used as a puzzle FEN.
///
/// As in `TrainSessionTests`: the only properties these tests need are that the
/// FEN parses and the line replays, and the start position gives both without
/// smuggling in a chess claim the test would then be asserting by accident.
private let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

/// The user's stored puzzle rating in these tests.
///
/// Chosen so every fixture puzzle sits inside the serving band *and* above the
/// curriculum's theme rating floor — the theme counters are only kept above the
/// floor, so a fixture rated below it would make the counting tests pass for the
/// wrong reason.
private let ratingUnderTest = 1300

private func makePuzzle(id: String, themes: [PuzzleTheme]) -> Puzzle {
    let mask = ThemeMask(themes)
    return Puzzle(
        id: id,
        fen: startFEN,
        // Setup move, then the one move the solver has to find.
        moves: "e2e4 e7e5",
        rating: ratingUnderTest,
        ratingDev: 50,
        popularity: 100,
        nbPlays: 1000,
        themesLo: mask.storedLow,
        themesHi: mask.storedHigh
    )
}

/// Everything `TrainingService` writes to, kept together so a test can assemble
/// a session and then read the counters it produced.
@MainActor
private struct Harness {

    let srs = InMemorySRSStore()
    let metrics = InMemoryMetricStore()
    let dailyLoop = InMemoryDailyLoopStore()
    let settings: InMemoryAppSettingsStore
    let corpus: InMemoryPuzzleCorpus

    init(puzzles: [Puzzle], cards: [SRSCard] = []) {
        self.corpus = InMemoryPuzzleCorpus(puzzles: puzzles)
        self.settings = InMemoryAppSettingsStore(
            settings: AppSettings(
                puzzleRating: Double(ratingUnderTest),
                // A settled deviation, so the per-item rating update cannot move
                // the serving band out from under a second session.
                puzzleRD: 40
            )
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

    /// Answers every item by skipping it, which is graded as a failure and — the
    /// part these tests care about — runs the full persistence path.
    func skipAll(_ service: TrainingService) async {
        var iterations = 0
        while service.phase == .solving, iterations < 40 {
            await service.skip()
            iterations += 1
        }
    }

    /// Plays every item correctly.
    ///
    /// Not interchangeable with ``skipAll(_:)``: a *failed* fresh puzzle becomes
    /// a candidate card, so a session that is skipped through leaves the same
    /// puzzles due as reviews tomorrow, and a test that then asked "was this
    /// puzzle served fresh again?" would be answered by the SRS deck rather than
    /// by the serve history it meant to exercise.
    func solveAll(_ service: TrainingService) async {
        var iterations = 0
        while service.phase == .solving, iterations < 40 {
            if let expected = service.machine?.expectedMove {
                await service.play(uci: expected)
            } else {
                await service.skip()
            }
            iterations += 1
        }
    }

    func themeAttempts(_ theme: ThemeTag) -> Double {
        metrics.value(
            TrainingMetricKeys.themeAttempts(theme, ratingFloor: DomainTuning.default.curriculum.themeRatingFloor)
        )
    }

    func themeSolves(_ theme: ThemeTag) -> Double {
        metrics.value(
            TrainingMetricKeys.themeSolves(theme, ratingFloor: DomainTuning.default.curriculum.themeRatingFloor)
        )
    }
}

// MARK: - Focus reaches the session

@MainActor
@Suite("Weekly focus reaches session assembly")
struct FocusAssemblyTests {

    /// Six puzzles carrying a `blunderCheck` theme, six carrying a theme that
    /// habit does not drill.
    private func mixedCorpus() -> [Puzzle] {
        (0..<6).map { makePuzzle(id: "focus-\($0)", themes: [.hangingPiece]) }
            + (0..<6).map { makePuzzle(id: "general-\($0)", themes: [.backRankMate]) }
    }

    @Test("A focus biases the fresh slots 60/40 toward the habit's themes")
    func focusBiasesTheMix() async {
        let harness = Harness(puzzles: mixedCorpus())
        let service = harness.service()

        await service.startSession(focus: WeeklyFocus(habit: .blunderCheck))

        // Ten fresh slots, 60% of them themed.
        #expect(service.session.mix.focusThemed == 6)
        #expect(service.session.items.filter(\.isFocusThemed).count == 6)
        // ...and the themed ones really are drawn from the habit's themes,
        // rather than merely flagged.
        let themed = service.session.items.filter(\.isFocusThemed)
        #expect(themed.allSatisfy { $0.presented.item.primaryTheme == ThemeTag("hangingPiece") })
    }

    /// The regression this whole slice exists for: the screen used to call
    /// `start()` with no focus, so the mix was always general and the week's
    /// habit never reached a puzzle.
    @Test("Without a focus nothing is themed")
    func nilFocusIsGeneral() async {
        let harness = Harness(puzzles: mixedCorpus())
        let service = harness.service()

        await service.startSession(focus: nil)

        #expect(service.session.mix.focusThemed == 0)
        #expect(service.session.items.allSatisfy { !$0.isFocusThemed })
    }

    @Test("The session model carries its focus into the service")
    func modelPassesFocusThrough() async {
        let driver = FocusRecordingDriver()
        let model = PuzzleSessionModel(driver: driver, focus: WeeklyFocus(habit: .scanThreats))

        await model.start()

        #expect(driver.startedWith?.habit == .scanThreats)
    }

    @Test("A focus handed to start wins over the one the model was built with")
    func explicitFocusWins() async {
        let driver = FocusRecordingDriver()
        let model = PuzzleSessionModel(driver: driver, focus: WeeklyFocus(habit: .scanThreats))

        await model.start(focus: WeeklyFocus(habit: .kingSafety))

        #expect(driver.startedWith?.habit == .kingSafety)
    }
}

/// A driver that records the focus it was started with and serves nothing.
@MainActor
private final class FocusRecordingDriver: PuzzleSessionDriver {

    private(set) var startedWith: WeeklyFocus?

    var queueCount: Int { 0 }
    var currentIndex: Int { 0 }
    var itemOnScreen: SessionItemPlan? { nil }
    var solveMachine: PuzzleSolveMachine? { nil }
    var isSessionFinished: Bool { true }
    var loadFailure: String? { nil }
    var puzzleRating: Double { 1000 }

    func startSession(focus: WeeklyFocus?) async { startedWith = focus }
    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult { .illegal }
    func revealHint() -> String? { nil }
    func skipCurrent() async {}
}

// MARK: - Theme counters

@MainActor
@Suite("Theme success counts fresh puzzles only")
struct ThemeCountingTests {

    @Test("A fresh puzzle counts once")
    func freshCounts() async {
        let harness = Harness(puzzles: [makePuzzle(id: "fresh-1", themes: [.fork])])
        let service = harness.service()

        await service.startSession(focus: nil)
        await harness.skipAll(service)

        #expect(harness.themeAttempts(.fork) == 1)
        // Skipped, so attempted but not solved.
        #expect(harness.themeSolves(.fork) == 0)
    }

    @Test("A solved fresh puzzle counts as an attempt and a solve")
    func freshSolveCounts() async {
        let harness = Harness(puzzles: [makePuzzle(id: "fresh-2", themes: [.fork])])
        let service = harness.service()

        await service.startSession(focus: nil)
        await harness.solveAll(service)

        #expect(harness.themeAttempts(.fork) == 1)
        #expect(harness.themeSolves(.fork) == 1)
    }

    /// The bias this fixes: a card the user keeps failing comes back more often
    /// than one they have learned, so counting reviews made the themes they were
    /// worst at collect the most attempts — and rung 2 gates on exactly that
    /// ratio.
    @Test("A review of the same position does not count again")
    func reviewDoesNotCount() async {
        let puzzle = makePuzzle(id: "review-1", themes: [.fork])
        let card = SRSCard(
            kind: SRSCardKind.puzzle.rawValue,
            puzzleID: puzzle.id,
            fen: startFEN,
            due: Date().addingTimeInterval(-86_400),
            stability: 5,
            difficulty: 5,
            state: Database.SRSState.review.rawValue,
            reps: 3,
            lastReview: Date().addingTimeInterval(-6 * 86_400)
        )
        let harness = Harness(puzzles: [puzzle], cards: [card])
        let service = harness.service()

        await service.startSession(focus: nil)
        // Guard against a vacuous pass: the assertion below is only meaningful
        // if the review actually made it into the queue.
        #expect(service.session.items.contains { $0.kind.isReview })

        await harness.skipAll(service)

        #expect(harness.themeAttempts(.fork) == 0)
        #expect(harness.themeSolves(.fork) == 0)
    }
}

// MARK: - Served-puzzle history

@MainActor
@Suite("Served puzzles are not served again")
struct ServedPuzzleHistoryTests {

    @Test("Finishing a fresh puzzle records it")
    func finishingRecords() async {
        let harness = Harness(puzzles: [makePuzzle(id: "seen-1", themes: [.fork])])
        let service = harness.service()

        await service.startSession(focus: nil)
        await harness.solveAll(service)

        #expect(ServedPuzzleHistory.recentlyServed(metrics: harness.metrics) == Set(["seen-1"]))
    }

    /// The leak this closes: exclusion used to live only in `loadSession`'s local
    /// `seenPuzzleIDs`, so it lasted exactly one session and the corpus handed
    /// the same positions back on a later day.
    @Test("A later session serves nothing that has already been served")
    func laterSessionExcludes() async {
        let harness = Harness(
            puzzles: (0..<3).map { makePuzzle(id: "corpus-\($0)", themes: [.fork]) }
        )

        let first = harness.service()
        await first.startSession(focus: nil)
        #expect(first.session.items.count == 3)
        await harness.solveAll(first)

        // A second service over the same stores: a new day, the same corpus.
        let second = harness.service()
        await second.startSession(focus: nil)

        #expect(second.session.items.isEmpty)
    }

    /// A session the user walks away from must not burn the puzzles they never
    /// saw, or an interruption would quietly shrink the corpus.
    @Test("An abandoned session only records what was answered")
    func abandonedSessionRecordsOnlyAnswered() async {
        let harness = Harness(
            puzzles: (0..<3).map { makePuzzle(id: "corpus-\($0)", themes: [.fork]) }
        )
        let service = harness.service()

        await service.startSession(focus: nil)
        let answered = service.currentItem?.presented.item.puzzleID
        if let expected = service.machine?.expectedMove {
            await service.play(uci: expected)
        }

        let served = ServedPuzzleHistory.recentlyServed(metrics: harness.metrics)
        #expect(served == Set([answered].compactMap { $0 }))
        #expect(served.count == 1)
    }
}

// MARK: - Micro-goal streak

@MainActor
@Suite("Consecutive games clearing the micro-goal")
struct MicroGoalStreakTests {

    /// A metric store where the KQK drill streak already clears rung 1's
    /// `r1.basicMates` criterion, which is the first criterion of the skill the
    /// `endgameTechnique` habit trains — and therefore that habit's micro-goal.
    private func metricsMeetingTheGoal() -> InMemoryMetricStore {
        let metrics = InMemoryMetricStore()
        try? metrics.set(
            MetricKey.kqkDrillCleanStreak.rawValue,
            value: Double(DomainTuning.default.curriculum.drillCleanStreakRequired),
            sampleCount: 2
        )
        return metrics
    }

    private func analysedGame(daysAgo: Int) -> Database.Game {
        Database.Game(
            startedAt: Date().addingTimeInterval(Double(-daysAgo) * 86_400),
            mode: .sparring,
            userColor: .white,
            opponentRating: 1000,
            analysisState: .complete
        )
    }

    private func service(games: [Database.Game], metrics: InMemoryMetricStore) -> MetricsService {
        MetricsService(
            games: InMemoryGameStore(games: games),
            moments: InMemoryMomentStore(),
            metrics: metrics,
            settings: InMemoryAppSettingsStore(
                settings: AppSettings(weeklyFocusHabit: Habit.endgameTechnique.rawValue)
            )
        )
    }

    @Test("An analysed game that clears the goal raises the streak")
    func oneGameOneStep() async {
        let metrics = metricsMeetingTheGoal()
        let service = service(games: [analysedGame(daysAgo: 1)], metrics: metrics)

        await service.refresh()

        #expect(metrics.value(MetricsService.Keys.focusConsecutiveGamesMeetingGoal) == 1)
    }

    /// `refresh()` also runs on app foreground and on every Profile load. Without
    /// the watermark, opening the app five times on a good afternoon would rotate
    /// the week's focus.
    @Test("Recomputing over the same games does not inflate the streak")
    func recomputeIsIdempotent() async {
        let metrics = metricsMeetingTheGoal()
        let service = service(games: [analysedGame(daysAgo: 1)], metrics: metrics)

        await service.refresh()
        await service.refresh()
        await service.refresh()

        #expect(metrics.value(MetricsService.Keys.focusConsecutiveGamesMeetingGoal) == 1)
    }

    @Test("A newer analysed game moves the streak on again")
    func newerGameAdvances() async {
        let metrics = metricsMeetingTheGoal()
        let older = analysedGame(daysAgo: 2)

        let first = service(games: [older], metrics: metrics)
        await first.refresh()

        let second = service(games: [older, analysedGame(daysAgo: 1)], metrics: metrics)
        await second.refresh()

        #expect(metrics.value(MetricsService.Keys.focusConsecutiveGamesMeetingGoal) == 2)
    }

    /// The streak is the *reason* the early-rotation rule can fire at all, so the
    /// counter and the threshold have to be talking about the same thing.
    @Test("Five clear games is the rotation threshold")
    func thresholdIsFive() {
        #expect(DomainTuning.default.focus.earlyRotationConsecutiveGames == 5)
    }
}
