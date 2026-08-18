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
        #expect(summary.action == .review(title: "Open the review"))
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

    @Test("With nothing selected yet, the CTA promises no number")
    func ctaWhilePending() {
        #expect(
            GameSummaryPresentation.make(input(analysisState: .running)).action
                == .review(title: "Open the review")
        )
        #expect(
            GameSummaryPresentation.make(input(momentCount: 0, analysisState: .complete)).action
                == .review(title: "Open the review")
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
