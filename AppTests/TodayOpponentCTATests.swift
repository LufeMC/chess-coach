import Testing

@testable import ChessCoach

/// The Today CTA has to name the person on the other side of the board.
///
/// A bare `Play` is the generic-Continue failure in a different costume: it
/// hides the half of the decision the user actually weighs, which is who they
/// are about to face. These pin the naming *and* the price, because dropping
/// either one to make room for the other was the obvious wrong fix.
@Suite("Today — the CTA names the opponent")
struct TodayOpponentCTATests {

    @Test("The CTA names the opponent and still states the price")
    func namesOpponentAndPrice() {
        let plan = TodayPlanner.plan(
            progress: .zero,
            hasHistory: true,
            streakBroken: false,
            opponentName: "Oscar"
        )

        #expect(plan.primary.title == "Play Oscar · ~10 min")
        #expect(plan.primary.destination == .play)
        #expect(plan.primary.emphasis == .primary)
        #expect(plan.primary.step == .game)
    }

    @Test("The first game is named too — a stranger is still a name")
    func firstRunNamesOpponent() {
        let plan = TodayPlanner.plan(
            progress: .zero,
            hasHistory: false,
            streakBroken: false,
            opponentName: "Oscar"
        )

        #expect(plan.primary.title == "Play Oscar · ~10 min")
    }

    @Test("With nobody to name, the CTA describes the step rather than guessing")
    func fallsBackToTheStep() {
        // A wrong name is worse than a vague one: the Play screen is about to
        // show the real opponent, and a button that promised someone else has
        // spent trust that the number in the same line is trying to build.
        let plan = TodayPlanner.plan(progress: .zero, hasHistory: true, streakBroken: false)

        #expect(plan.primary.title == "Play 1 game · ~10 min")
        #expect(plan.primary.title != "Play")
    }

    @Test("An extra game on a finished day is named and priced as well")
    func completedDayNamesOpponent() {
        let done = DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 10)
        let plan = TodayPlanner.plan(
            progress: done,
            hasHistory: true,
            streakBroken: false,
            opponentName: "Petra"
        )

        #expect(plan.phase == .complete)
        #expect(plan.primary.title == "Play Petra · ~10 min")
        // Still bordered: the filled button never points at optional work.
        #expect(plan.primary.emphasis == .secondary)
    }

    @Test("Naming the opponent never reaches the steps that are not games")
    func onlyTheGameStepIsNamed() {
        let plan = TodayPlanner.plan(
            progress: DailyProgress(gamePlayed: true),
            hasHistory: true,
            streakBroken: false,
            opponentName: "Oscar"
        )

        #expect(plan.primary.title == "Review 3 moments · ~5 min")
        #expect(!plan.primary.title.contains("Oscar"))
    }

    @Test("No CTA in any state is a bare verb")
    func noBareVerbs() {
        let states: [DailyProgress] = [
            .zero,
            DailyProgress(gamePlayed: true),
            DailyProgress(gamePlayed: true, momentsReviewed: 3),
            DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 10)
        ]

        for progress in states {
            let plan = TodayPlanner.plan(
                progress: progress,
                hasHistory: true,
                streakBroken: false,
                opponentName: "Oscar"
            )
            #expect(plan.primary.title.contains("min"), "\(plan.primary.title) states no price")
            #expect(plan.primary.title != "Continue")
            #expect(plan.primary.title != "Play")
        }
    }
}
