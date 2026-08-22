import Database
import Foundation
import Testing

@testable import ChessCoach

// The game → review handoff: what the banner says, when it says it, and what the
// summary promises. All three are pure derivations from an `Outcome` plus
// whatever analysis has managed to finish.

private func outcome(_ termination: GameTermination, userWon: Bool?) -> GameSession.Outcome {
    let result =
        switch userWon {
        case .some(true): "1-0"
        case .some(false): "0-1"
        case nil: "1/2-1/2"
        }
    return GameSession.Outcome(result: result, termination: termination.rawValue, userWon: userWon)
}

// MARK: - Banner

@Suite("Result banner")
struct GameEndBannerTests {

    @Test("Kind comes from the user's result, not White's")
    func kind() {
        #expect(GameEndBanner.make(outcome: outcome(.checkmate, userWon: true), opponentName: "Oscar").kind == .win)
        #expect(GameEndBanner.make(outcome: outcome(.checkmate, userWon: false), opponentName: "Oscar").kind == .loss)
        #expect(GameEndBanner.make(outcome: outcome(.stalemate, userWon: nil), opponentName: "Oscar").kind == .draw)
    }

    @Test("Every termination gets a sentence that names what happened")
    func headlines() {
        #expect(
            GameEndBanner.make(outcome: outcome(.checkmate, userWon: true), opponentName: "Oscar").headline
                == "Checkmate — you win."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.checkmate, userWon: false), opponentName: "Oscar").headline
                == "Checkmate. Oscar wins."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.resignation, userWon: false), opponentName: "Oscar").headline
                == "You resigned."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.timeout, userWon: false), opponentName: "Oscar").headline
                == "You ran out of time."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.timeout, userWon: true), opponentName: "Oscar").headline
                == "Oscar ran out of time."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.stalemate, userWon: nil), opponentName: "Oscar").headline
                == "Stalemate — draw."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.repetition, userWon: nil), opponentName: "Oscar").headline
                == "Threefold repetition — draw."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.insufficientMaterial, userWon: nil), opponentName: "Oscar").headline
                == "Not enough material to mate — draw."
        )
        #expect(
            GameEndBanner.make(outcome: outcome(.fiftyMoves, userWon: nil), opponentName: "Oscar").headline
                == "Fifty moves without a capture — draw."
        )
    }

    @Test("An abandoned game says the engine stopped, not \"Draw.\"")
    func abandonedGame() {
        // `GameSession` records "1/2-1/2" after three failed opponent searches
        // because inventing a result for either side would be worse. A bare
        // "Draw." presents that placeholder as something the players agreed.
        let banner = GameEndBanner.make(
            outcome: outcome(.unknown, userWon: nil),
            opponentName: "Oscar"
        )
        #expect(banner.headline == "The engine stopped responding, so this game was abandoned. It does not count.")
        #expect(banner.headline.contains("Draw.") == false)
    }

    @Test("A flag that draws says so, and does not guess whose it was")
    func timeoutDraw() {
        // Either side flagging with no mating material on the other produces a
        // draw, and the outcome does not record which flag fell — so "You ran
        // out of time." was wrong about the player half the time and silent
        // about the draw the other half.
        let banner = GameEndBanner.make(outcome: outcome(.timeout, userWon: nil), opponentName: "Oscar")
        #expect(banner.kind == .draw)
        #expect(banner.headline == "A flag fell, and there was not enough material to mate — draw.")
    }

    @Test("An unrecognised termination still says who won")
    func unknownTermination() {
        let banner = GameEndBanner.make(
            outcome: GameSession.Outcome(result: "1-0", termination: "asteroid", userWon: true),
            opponentName: "Oscar"
        )
        #expect(banner.headline == "You win.")
        #expect(banner.kind == .win)
    }

    @Test("A loss is stated, not decorated with a failure glyph")
    func lossIsNeutral() {
        // The banner tint is chosen in the view, but the symbol is the part that
        // carries tone, and a checkered flag is a finish line rather than a red
        // X. Craft standards list a red X after a loss by name.
        let loss = GameEndBanner.make(outcome: outcome(.checkmate, userWon: false), opponentName: "Oscar")
        #expect(loss.symbolName == "flag.checkered")
        #expect(!loss.headline.contains("!"))
    }

    @Test("The banner's CTA names its destination")
    func cta() {
        #expect(
            GameEndBanner.make(outcome: outcome(.checkmate, userWon: true), opponentName: "Oscar").ctaTitle
                == "See the summary"
        )
    }
}

// MARK: - Storage failures

@Suite("Storage failure copy")
struct StorageFailureTextTests {

    /// The screen used to print `String(describing: error)` under a chess
    /// result, so the one sentence telling the user their game was lost read
    /// "SQLite error 13: database or disk is full". Honest, and not actionable.
    @Test("A GRDB description becomes a sentence about the phone")
    func writeFailures() {
        #expect(
            StorageFailureText.sentence("SQLite error 13: database or disk is full")
                == "the phone is out of storage."
        )
        // Named as what the phone will not do, not as the SQLite state: "read
        // only" is the cause, "cannot be written to" is the consequence, and
        // the consequence is the half the reader can act on.
        #expect(
            StorageFailureText.sentence("attempt to write a readonly database")
                == "the games file cannot be written to."
        )
        #expect(StorageFailureText.sentence("database is locked").contains("busy"))
        // An error nobody anticipated still says what was lost.
        #expect(StorageFailureText.sentence("something new").contains("could not be written"))
    }

    @Test("No mapped sentence leaks the library's vocabulary")
    func noRawText() {
        for failure in [
            "SQLite error 13: database or disk is full",
            "attempt to write a readonly database",
            "database is locked",
            "something new"
        ] {
            #expect(StorageFailureText.sentence(failure).lowercased().contains("sqlite") == false)
            #expect(StorageFailureText.reading(failure).lowercased().contains("sqlite") == false)
        }
    }
}

// MARK: - Rating

@Suite("Abandoned games and the ladder")
struct AbandonedGameLadderTests {

    private func record(termination: GameTermination) -> FinishedGameRecord {
        FinishedGameRecord(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_000),
            mode: GameMode.sparring.rawValue,
            userColor: .white,
            opponentRating: 1_200,
            result: "1/2-1/2",
            termination: termination.rawValue,
            pgn: "",
            moves: [],
            opponentParams: FinishedGameRecord.OpponentParams(
                opponentRating: 1_200,
                baseSeconds: 300,
                incrementSeconds: 0,
                secondTryEnabled: false,
                guidedEnabled: false
            ),
            isRated: true,
            ratingWeight: .sparring
        )
    }

    /// The "1/2-1/2" written after three failed opponent searches is a
    /// placeholder, not a result. Feeding it to the ladder is evidence about a
    /// game the player never got to finish.
    @Test("A game abandoned by an engine failure does not move the rating")
    func abandonedGameIsUnrated() {
        #expect(record(termination: .unknown).ladderGame == nil)
        #expect(record(termination: .agreement).ladderGame != nil)
    }
}

// MARK: - Sequencing

@Suite("Handoff sequencing")
struct GameEndSequencingTests {

    @Test("The board is left alone for 600ms before anything rises")
    func holdBoundary() {
        #expect(GameEndStage.stage(elapsed: .zero) == .holding)
        #expect(GameEndStage.stage(elapsed: .milliseconds(599)) == .holding)
        #expect(GameEndStage.stage(elapsed: .milliseconds(600)) == .banner)
        #expect(GameEndStage.stage(elapsed: .seconds(3)) == .banner)
        #expect(GameEndStage.holdDuration == .milliseconds(600))
    }

    @MainActor
    @Test("A finished game runs hold → banner")
    func sequence() async {
        let sequencer = GameEndSequencer(hold: .zero)
        #expect(sequencer.stage == .none)
        await sequencer.gameFinished()
        #expect(sequencer.stage == .banner)
    }

    @MainActor
    @Test("Finishing twice does not restart the hold")
    func idempotent() async {
        let sequencer = GameEndSequencer(hold: .zero)
        await sequencer.gameFinished()
        sequencer.collapse()
        // A re-render calling this again must not yank the banner back up over
        // the position the player is studying.
        await sequencer.gameFinished()
        #expect(sequencer.stage == .collapsed)
    }

    @MainActor
    @Test("The banner collapses to a chip and comes back")
    func collapseAndExpand() async {
        let sequencer = GameEndSequencer(hold: .zero)
        await sequencer.gameFinished()

        sequencer.collapse()
        #expect(sequencer.stage == .collapsed)
        sequencer.expand()
        #expect(sequencer.stage == .banner)

        // Expanding from nowhere is a no-op: no banner without a finished game.
        sequencer.reset()
        sequencer.expand()
        #expect(sequencer.stage == .none)
    }

    @MainActor
    @Test("A new game clears the handoff")
    func reset() async {
        let sequencer = GameEndSequencer(hold: .zero)
        await sequencer.gameFinished()
        sequencer.reset()
        #expect(sequencer.stage == .none)
    }
}

// MARK: - Summary

@Suite("Game summary")
struct GameSummaryPresentationTests {

    private func input(
        userWon: Bool? = true,
        plyCount: Int = 61,
        accuracy: Double? = nil,
        momentCount: Int? = nil,
        analysisState: AnalysisState? = nil,
        persistenceFailure: String? = nil
    ) -> GameSummaryPresentation.Input {
        GameSummaryPresentation.Input(
            outcome: outcome(.checkmate, userWon: userWon),
            opponentName: "Oscar",
            opponentRating: 1050,
            plyCount: plyCount,
            accuracy: accuracy,
            momentCount: momentCount,
            analysisState: analysisState,
            persistenceFailure: persistenceFailure
        )
    }

    @Test("Three numbers, no more")
    func statCount() {
        let summary = GameSummaryPresentation.make(input())
        #expect(summary.stats.count == 3)
        #expect(summary.stats.map(\.label) == ["Moves", "Accuracy", "Moments"])
    }

    @Test("Moves counts full moves, not plies")
    func moveCount() {
        #expect(GameSummaryPresentation.make(input(plyCount: 61)).stats[0].value == "31")
        #expect(GameSummaryPresentation.make(input(plyCount: 60)).stats[0].value == "30")
        #expect(GameSummaryPresentation.make(input(plyCount: 1)).stats[0].value == "1")
        #expect(GameSummaryPresentation.make(input(plyCount: 0)).stats[0].value == "0")
    }

    @Test("Pending analysis leaves a skeleton rather than a zero")
    func pendingNumbers() {
        // A `0%` accuracy while the engine is still walking the game is a lie
        // the user has no way to tell from a real result.
        let summary = GameSummaryPresentation.make(input(analysisState: .pending))
        #expect(summary.stats[0].value == "31")
        #expect(summary.stats[1].value == nil)
        #expect(summary.stats[2].value == nil)
    }

    /// An unpriced wait is a wait people leave the app during, and leaving is the
    /// one thing that guarantees it never finishes — the engine suspends in the
    /// background. The figure only has to separate ten seconds from two minutes.
    @Test("The wait is priced from the length of the game")
    func analysisEstimate() {
        let short = GameSummaryPresentation.analysisEstimateSeconds(plyCount: 10)
        let long = GameSummaryPresentation.analysisEstimateSeconds(plyCount: 120)
        #expect(short < long)
        // 61 positions at ~0.35s plus twelve closer looks at ~0.5s.
        #expect(GameSummaryPresentation.analysisEstimateSeconds(plyCount: 60) == 27)

        #expect(GameSummaryPresentation.analysisEstimateText(plyCount: 60) == "about 27 seconds")
        #expect(GameSummaryPresentation.analysisEstimateText(plyCount: 300) == "about 2 minutes")
        // Never zero, however short the game: "about 0 seconds" is not a price.
        #expect(GameSummaryPresentation.analysisEstimateSeconds(plyCount: 0) >= 5)
    }

    @Test("Finished analysis fills both late numbers")
    func completeNumbers() {
        let summary = GameSummaryPresentation.make(
            input(accuracy: 82.4, momentCount: 3, analysisState: .complete)
        )
        #expect(summary.stats[1].value == "82%")
        #expect(summary.stats[2].value == "3")
    }

    @Test("A finished pass with no numbers in it says so rather than skeletoning forever")
    func settledButEmpty() {
        // A game resigned on move one is analysed instantly and has no accuracy
        // to report. A skeleton there would pulse at a number that is never
        // coming.
        let summary = GameSummaryPresentation.make(
            input(plyCount: 0, momentCount: 0, analysisState: .complete)
        )
        #expect(summary.stats[1].value == "—")
        #expect(summary.stats[2].value == "0")
    }

    @Test("Failed analysis says so with a dash instead of waiting forever")
    func failedAnalysis() {
        let summary = GameSummaryPresentation.make(input(analysisState: .failed))
        #expect(summary.stats[1].value == "—")
        #expect(summary.stats[2].value == "—")
        #expect(summary.action == .review(title: "See the game · no analysis for this one"))
    }

    @Test("A game that never reached disk stops waiting for numbers that cannot arrive")
    func persistenceFailureSettles() {
        // The row does not exist, so the poll would read nil for as long as the
        // screen is open and both placeholders would pulse forever.
        let summary = GameSummaryPresentation.make(input(persistenceFailure: "SQLite error 13"))
        #expect(summary.stats[1].value == "—")
        #expect(summary.stats[2].value == "—")
    }

    @Test("The CTA names the step and its price, in the Today checklist's words")
    func ctaNamesTheStep() {
        let three = GameSummaryPresentation.make(input(momentCount: 3, analysisState: .complete)).action
        #expect(
            three
                == .review(
                    title: TodayPlanner.actionTitle(
                        for: .moments,
                        progress: DailyProgress(gamePlayed: true),
                        firstRun: false
                    )
                )
        )
        #expect(three == .review(title: "Review 3 moments · ~5 min"))

        // Singular, and a price scaled to what is actually left.
        #expect(
            GameSummaryPresentation.make(input(momentCount: 1, analysisState: .complete)).action
                == .review(title: "Review 1 moment · ~2 min")
        )
    }

    /// "Open the review" said the same thing about a pass that has not finished
    /// counting and a pass that finished and found nothing — the one distinction
    /// this button exists to draw.
    @Test("A running pass and a clean game do not share a CTA")
    func ctaWhilePending() {
        #expect(
            GameSummaryPresentation.make(input(analysisState: .running)).action
                == .review(title: "Analysing · open the game and its moves")
        )
        #expect(
            GameSummaryPresentation.make(input(momentCount: 0, analysisState: .complete)).action
                == .review(title: "See the game · no moments to review · ~1 min")
        )
    }

    @Test("A game that never reached disk offers no review at all")
    func persistenceFailure() {
        let summary = GameSummaryPresentation.make(
            input(momentCount: 3, analysisState: .complete, persistenceFailure: "disk full")
        )
        #expect(
            summary.action
                == .unavailable(note: "This game could not be saved, so there is nothing to review.")
        )
    }

    @Test("Headline and detail carry the result and the opponent")
    func headline() {
        let win = GameSummaryPresentation.make(input(userWon: true))
        #expect(win.headline == "Checkmate — you win.")
        #expect(win.detail == "Oscar · 1050")

        let loss = GameSummaryPresentation.make(input(userWon: false))
        #expect(loss.headline == "Checkmate. Oscar wins.")
    }
}

// MARK: - Unsaved games

/// A failed write used to be visible only on the summary, which is the one beat
/// of the handoff a user can skip: collapsing the banner or tapping the exit
/// both leave the game without ever passing through it.
@Suite("Banner on a game that was not saved")
struct GameEndBannerPersistenceTests {

    @Test("The headline says the game was not kept, without stuttering the stop")
    func headlineNamesTheLoss() {
        let banner = GameEndBanner.make(
            outcome: outcome(.checkmate, userWon: true),
            opponentName: "Oscar",
            persistenceFailure: "SQLite error 13: database or disk is full"
        )
        #expect(banner.headline == "Checkmate — you win — not saved.")
    }

    @Test("The CTA carries it too")
    func ctaNamesTheLoss() {
        let banner = GameEndBanner.make(
            outcome: outcome(.resignation, userWon: false),
            opponentName: "Oscar",
            persistenceFailure: "disk full"
        )
        #expect(banner.ctaTitle == "See the summary · not saved")
    }

    @Test("A saved game says nothing about saving")
    func savedGameIsUnchanged() {
        let banner = GameEndBanner.make(
            outcome: outcome(.checkmate, userWon: true),
            opponentName: "Oscar"
        )
        #expect(banner.headline == "Checkmate — you win.")
        #expect(banner.ctaTitle == "See the summary")
    }
}

// MARK: - The daily loop

/// Which games count as "the day's game" on Today.
///
/// The five calibration games are played before the loop exists, in one sitting,
/// against opponents chosen to bracket a rating rather than to train anything.
/// Counting them ticked the game step gold the moment the gate closed, so a user
/// arriving on Today for the first time was met with two of three steps already
/// done and a CTA pointing at a game they had not chosen to play.
@Suite("Calibration and the daily loop")
struct CalibrationDailyLoopTests {

    private func record(mode: GameMode) -> FinishedGameRecord {
        FinishedGameRecord(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_002_000),
            mode: mode.rawValue,
            userColor: .white,
            opponentRating: 1_200,
            result: "1-0",
            termination: GameTermination.checkmate.rawValue,
            pgn: "",
            moves: [],
            opponentParams: FinishedGameRecord.OpponentParams(
                opponentRating: 1_200,
                baseSeconds: 900,
                incrementSeconds: 10,
                secondTryEnabled: false,
                guidedEnabled: false
            ),
            isRated: true,
            ratingWeight: .sparring
        )
    }

    private func loopAfterSaving(mode: GameMode) async throws -> DailyLoop {
        let database = AppDatabase(user: try UserDatabase.inMemory(), puzzles: nil)
        let saved = record(mode: mode)
        try await GamePersistence(database: database).save(saved)
        return try database.dailyLoop.loop(for: DailyLoop.dayKey(for: saved.endedAt))
    }

    @Test("A sparring game is the day's game")
    func sparringCounts() async throws {
        #expect(try await loopAfterSaving(mode: .sparring).gamePlayed)
    }

    @Test("A calibration game is not the day's game")
    func calibrationDoesNotCount() async throws {
        #expect(try await loopAfterSaving(mode: .calibration).gamePlayed == false)
    }

    /// The game is still saved and still reviewable — only the streak counter
    /// declines it. A measurement the user cannot look at afterwards would be a
    /// worse trade than the one this fix makes.
    @Test("A calibration game is still written to history")
    func calibrationIsStillSaved() async throws {
        let database = AppDatabase(user: try UserDatabase.inMemory(), puzzles: nil)
        let saved = record(mode: .calibration)
        try await GamePersistence(database: database).save(saved)
        #expect(try database.games.game(id: saved.id) != nil)
    }
}
