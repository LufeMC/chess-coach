import AnalysisKit
import BoardUI
import ChessKit
import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// The Review screen's coaching surface, all of it pure: the label above a note,
// the chips under it, the game-level verdict, and when a comparison chip is
// entitled to draw a caret. Every one of these is a place where a wrong answer
// is invisible in a screenshot — a cause tag printed as praise, a chip asserting
// a habit for a tag that maps to none, a verdict claiming a game had no moments
// while three sit below it — and every one is reachable with no database.

// MARK: - Fixtures

private let fixtureGameID = UUID()

private func storedMoment(
    id: UUID = UUID(),
    kind: MomentKind = .mistake,
    causeTag: AnalysisKit.CauseTag = .hungMovedPiece,
    stepTag: AnalysisKit.StepTag = .s5BlunderCheck,
    bestSAN: String = "Re8",
    coachText: String? = nil
) -> Database.Moment {
    Database.Moment(
        id: id,
        gameID: fixtureGameID,
        ply: 45,
        fen: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
        kind: kind.rawValue,
        causeTag: causeTag.rawValue,
        stepTag: stepTag.rawValue,
        playedSAN: "Nxe5",
        playedUCI: "f3e5",
        bestSAN: bestSAN,
        bestUCI: "e1e8",
        deltaEP: 0.4,
        score: 0.9,
        coachText: coachText
    )
}

/// A stored moment carrying the payload analysis actually writes, so the verdict
/// path is exercised over a real decode rather than a hand-built value.
private func storedMomentWithPayload(
    id: UUID = UUID(),
    ply: Int = 45,
    severity: Double = 0.8
) -> Database.Moment {
    let moment = AnalysisKit.Moment(
        ply: ply,
        phase: .middlegame,
        fenBefore: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
        sideToMove: .white,
        playedSAN: "Nxe5",
        playedUCI: "f3e5",
        bestSAN: "d3",
        bestUCI: "d2d3",
        cpBefore: 40,
        cpAfter: -280,
        winPctBefore: 56,
        winPctAfter: 22,
        deltaEP: 0.34,
        judgment: .blunder,
        // Real lines, legal in that position: the "what should I have played"
        // chip is built by replaying them, and a chip with nothing to replay is
        // deliberately not offered at all.
        pvBest: ["d2d3", "f8c5", "e1g1"],
        pvRefutation: ["c6e5"],
        criticalityGap: 0.2,
        detector: .hangingPiece,
        causeTag: .hungMovedPiece,
        stepTag: .s5BlunderCheck,
        score: MomentScore(severity: severity, learnability: 1, relevance: 1),
        kind: .mistake,
        srsEligible: true
    )

    return Database.Moment(
        id: id,
        gameID: fixtureGameID,
        ply: ply,
        fen: moment.fenBefore,
        kind: moment.kind.rawValue,
        causeTag: moment.causeTag.rawValue,
        stepTag: moment.stepTag.rawValue,
        playedSAN: moment.playedSAN,
        playedUCI: moment.playedUCI,
        bestSAN: moment.bestSAN ?? "",
        bestUCI: moment.bestUCI ?? "",
        deltaEP: moment.deltaEP,
        score: moment.total,
        coachText: "You left the knight where it could be taken.",
        payload: Database.Moment.encodePayload(moment)
    )
}

private func momentCard(id: UUID, bestSAN: String = "Re8") -> ReviewMomentCard {
    ReviewMomentCard(
        id: id,
        ply: 45,
        moveNumber: 23,
        caption: "Move 23 · Blunder",
        classification: .blunder,
        thumbnail: MomentThumbnail(
            id: id,
            position: .standard,
            orientation: .white,
            moveNumber: 23,
            san: "Nxe5",
            classification: .blunder
        ),
        coachText: nil,
        diagnosis: ReviewDiagnosis(title: "Hanging pieces"),
        playedSAN: "Nxe5",
        bestSAN: bestSAN
    )
}

private func finishedGame(
    result: GameResult? = .whiteWins,
    color: PlayerColor = .white,
    accuracy: Double? = 71,
    analysis: AnalysisState = .complete
) -> Database.Game {
    Database.Game(
        id: fixtureGameID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_002_000),
        mode: .sparring,
        userColor: color,
        opponentRating: 1_400,
        result: result?.rawValue,
        userAccuracy: accuracy,
        analysisState: analysis
    )
}

/// A half-open range rather than `1...count`, so that `count: 0` is the empty
/// game and not a trap: a resignation on move one is exactly the case the
/// verdict has to survive, so the fixture for it must be constructible.
private func moveRows(count: Int) -> [GameMove] {
    (0..<count).map { index in
        GameMove(gameID: fixtureGameID, ply: index + 1, san: "Nf3", uci: "g1f3")
    }
}

// MARK: - Diagnosis label

@Suite("Moment diagnosis")
struct ReviewDiagnosisTests {

    /// The cause has to read the same here as it does on the Profile leak it
    /// feeds; two names for one finding is two findings to the reader.
    @Test("The cause is named in the leak table's words")
    func causeMatchesTheLeakTable() {
        let diagnosis = ReviewDiagnoses.diagnosis(for: storedMoment())

        #expect(diagnosis.title == LeakTable.title(for: TrainingCore.CauseTag.hungMovedPiece))
        #expect(diagnosis.step == "Blunder check")
    }

    /// `MomentBuilder` hands a praised move the `generic` tag and S3, because
    /// every value in the taxonomy names something that went wrong. Printing
    /// either would caption praise as a failure.
    @Test("A reinforcement is labelled as praise and carries no step")
    func reinforcementIsNotDiagnosed() {
        let diagnosis = ReviewDiagnoses.diagnosis(
            for: storedMoment(kind: .reinforcement, causeTag: .generic, stepTag: .s3Candidates)
        )

        #expect(diagnosis.title == ReviewDiagnoses.praiseTitle)
        #expect(diagnosis.step == nil)
    }

    @Test("A move no detector explained says so rather than printing a raw tag")
    func genericMistake() {
        let diagnosis = ReviewDiagnoses.diagnosis(for: storedMoment(causeTag: .generic, stepTag: .s3Candidates))

        #expect(diagnosis.title == ReviewDiagnoses.unexplainedTitle)
        #expect(diagnosis.step == "Candidates")
    }

    /// A row synced down from a newer build names a step this one has never
    /// seen. The cause still prints; only the step drops out.
    @Test("An unknown step tag drops out without taking the cause with it")
    func unknownStepTag() {
        let moment = Database.Moment(
            gameID: fixtureGameID,
            ply: 5,
            fen: "8/8/8/8/8/8/8/8 w - - 0 1",
            kind: MomentKind.mistake.rawValue,
            causeTag: AnalysisKit.CauseTag.kingExposure.rawValue,
            stepTag: "S9",
            playedSAN: "g4",
            playedUCI: "g2g4",
            bestSAN: "O-O",
            bestUCI: "e1g1",
            deltaEP: 0.2,
            score: 0.4
        )

        #expect(ReviewDiagnoses.diagnosis(for: moment).title == "King left exposed")
        #expect(ReviewDiagnoses.diagnosis(for: moment).step == nil)
    }

    /// The numbers pointed back at a routine nothing in the app teaches, so a
    /// first-time reviewer met "Step 5" with no way to find out what steps 1 to
    /// 4 were.
    @Test("Every step of the routine has a name, and none of them is a bare number")
    func everyStepIsNamed() {
        for step in AnalysisKit.StepTag.allCases {
            let title = ReviewDiagnoses.stepTitle(step)
            #expect(!title.isEmpty)
            #expect(title.hasPrefix("Step ") == false)
        }
        #expect(ReviewDiagnoses.stepTitle(.s5BlunderCheck) == "Blunder check")
    }

    /// The lead-in is a question about a mistake. Asked of the one moment in a
    /// review that exists to say *well played*, it reads as an accusation.
    @Test("A reinforcement is never asked what its move allowed in return")
    func reinforcementHasNoQuestion() {
        #expect(ReviewDiagnoses.question(for: storedMoment()) != nil)
        #expect(ReviewDiagnoses.question(for: storedMoment(kind: .reinforcement)) == nil)
    }
}

// MARK: - Suggested questions

@Suite("Suggested questions")
struct ReviewSuggestedQuestionTests {

    /// The answer has to show the reader how to find the move. A bare "Re8 — the
    /// engine's move in this position." is the "wins a knight" announcement in
    /// another costume.
    @Test("Both chips are offered when the app can answer both")
    func bothQuestions() {
        let id = UUID()
        let questions = ReviewSuggestedQuestions.byMoment(
            moments: [storedMomentWithPayload(id: id)],
            cards: [momentCard(id: id)],
            rung: 2
        )

        #expect(questions[id]?.count == 2)
        let best = try! #require(questions[id]?.first?.answer)
        // The engine's own line, replayed into notation, plus the reply that
        // punished what was actually played.
        #expect(best.contains("the line runs d3 Bc5"))
        #expect(best.contains("play Nxe5 instead"))
        #expect(best.contains("Nxe5."))

        // The habit chip says what to do at the board, not just its own name.
        let habit = try! #require(questions[id]?.last?.answer)
        #expect(habit == ReviewSuggestedQuestions.habitInstruction(.blunderCheck))
        #expect(habit != Habit.blunderCheck.microGoalTitle)
        #expect(questions[id]?.last?.habit == .blunderCheck)
    }

    /// Silence beats a move with no reason behind it: without a stored line
    /// there is nothing to show but the SAN, so the chip is not offered.
    @Test("A best move with no line behind it is not turned into a chip")
    func bestMoveWithoutALineIsOmitted() {
        let id = UUID()
        let questions = ReviewSuggestedQuestions.byMoment(
            moments: [storedMoment(id: id, causeTag: .hungMovedPiece)],
            cards: [momentCard(id: id)],
            rung: 2
        )

        #expect(questions[id]?.count == 1)
        #expect(questions[id]?.contains { $0.question == "What should I have played?" } == false)
    }

    /// The habit chip is the curriculum's mapping, and that mapping is
    /// rung-dependent: the same opening error is a blunder-check problem at
    /// rung 1 and a move-choice problem above it.
    @Test("The habit answer follows the user's rung")
    func habitFollowsRung() {
        let id = UUID()
        let stored = [storedMoment(id: id, causeTag: .openingPrinciple)]

        let low = ReviewSuggestedQuestions.byMoment(moments: stored, cards: [momentCard(id: id)], rung: 1)
        let high = ReviewSuggestedQuestions.byMoment(moments: stored, cards: [momentCard(id: id)], rung: 3)

        #expect(low[id]?.last?.habit == .blunderCheck)
        #expect(high[id]?.last?.habit == .candidatesFirst)
        #expect(low[id]?.last?.answer == ReviewSuggestedQuestions.habitInstruction(.blunderCheck))
        #expect(high[id]?.last?.answer == ReviewSuggestedQuestions.habitInstruction(.candidatesFirst))
    }

    /// Nothing is invented: a cause tag from a newer build maps to no habit, and
    /// a moment with no stored best move has nothing to reveal.
    @Test("A chip the app cannot answer is not offered")
    func unanswerableChipsAreOmitted() {
        let id = UUID()
        let moment = Database.Moment(
            id: id,
            gameID: fixtureGameID,
            ply: 45,
            fen: "8/8/8/8/8/8/8/8 w - - 0 1",
            kind: MomentKind.mistake.rawValue,
            causeTag: "somethingFromANewerBuild",
            stepTag: "S5",
            playedSAN: "Nxe5",
            playedUCI: "f3e5",
            bestSAN: "",
            bestUCI: "",
            deltaEP: 0.4,
            score: 0.9
        )

        let questions = ReviewSuggestedQuestions.byMoment(
            moments: [moment],
            cards: [momentCard(id: id, bestSAN: "")],
            rung: 2
        )

        #expect(questions[id]?.isEmpty == true)
    }

    /// Both questions are written about a mistake — what to play instead, how to
    /// catch it next time — and neither belongs under a move the player got
    /// right.
    @Test("A reinforcement is offered no chips")
    func reinforcementIsOfferedNothing() {
        let id = UUID()
        let questions = ReviewSuggestedQuestions.byMoment(
            moments: [storedMoment(id: id, kind: .reinforcement)],
            cards: [momentCard(id: id)],
            rung: 2
        )

        #expect(questions[id]?.isEmpty == true)
    }
}

// MARK: - Verdict

@Suite("Game verdict")
struct ReviewVerdictTests {

    @Test("The result is read from the reviewing player's side")
    func outcomeIsPersonal() {
        #expect(ReviewVerdicts.outcome(result: .whiteWins, color: .white) == .win)
        #expect(ReviewVerdicts.outcome(result: .whiteWins, color: .black) == .loss)
        #expect(ReviewVerdicts.outcome(result: .blackWins, color: .black) == .win)
        #expect(ReviewVerdicts.outcome(result: .draw, color: .white) == .draw)
    }

    @Test("A finished, analysed game gets the summary the explainer writes")
    func verdictIsWritten() {
        let id = UUID()
        let stored = storedMomentWithPayload(id: id)
        let cards = ReviewMomentCards.cards(moments: [stored], orientation: .white, moveRows: [])

        let verdict = ReviewVerdicts.verdict(
            game: finishedGame(),
            moves: moveRows(count: 45),
            moments: [stored],
            cards: cards
        )

        #expect(
            verdict
                == GameSummarizer.summary(
                    outcome: .win,
                    accuracy: 71,
                    // 45 half-moves is 23 moves as a player counts them.
                    moveCount: 23,
                    moments: [AnalysisPipeline.moment(from: stored)!]
                )
        )
    }

    /// The body ends by pointing at the positions below it, so it has to be
    /// written about the same ones the filmstrip shows.
    @Test("A moment the strip left out is left out of the verdict")
    func verdictCoversTheDisplayedSlate() {
        let shown = storedMomentWithPayload(id: UUID(), ply: 21, severity: 0.9)
        let dropped = storedMomentWithPayload(id: UUID(), ply: 45, severity: 0.1)
        let cards = ReviewMomentCards.cards(
            moments: [shown, dropped],
            orientation: .white,
            moveRows: [],
            limit: 1
        )

        let verdict = ReviewVerdicts.verdict(
            game: finishedGame(),
            moves: moveRows(count: 60),
            moments: [shown, dropped],
            cards: cards
        )

        #expect(cards.count == 1)
        #expect(
            verdict
                == GameSummarizer.summary(
                    outcome: .win,
                    accuracy: 71,
                    moveCount: 30,
                    moments: [AnalysisPipeline.moment(from: shown)!]
                )
        )
    }

    /// A game with nothing worth reviewing still earns a verdict — that is the
    /// verdict. The gates below are about games the app cannot describe at all.
    @Test("A clean analysed game still gets one")
    func cleanGame() {
        let verdict = ReviewVerdicts.verdict(
            game: finishedGame(),
            moves: moveRows(count: 60),
            moments: [],
            cards: []
        )

        #expect(verdict != nil)
    }

    /// A game resigned on move one is marked complete with no evaluations, and
    /// the summariser would still write "A loss with no single moment behind it
    /// … The game ran 0 moves" — a considered assessment of a game that never
    /// happened.
    @Test("A game too short to have gone wrong gets no verdict")
    func tooShortForAVerdict() {
        #expect(
            ReviewVerdicts.verdict(
                game: finishedGame(),
                moves: moveRows(count: 0),
                moments: [],
                cards: []
            ) == nil
        )
        #expect(
            ReviewVerdicts.verdict(
                game: finishedGame(),
                moves: moveRows(count: ReviewVerdicts.minimumPlies - 1),
                moments: [],
                cards: []
            ) == nil
        )
        #expect(
            ReviewVerdicts.verdict(
                game: finishedGame(),
                moves: moveRows(count: ReviewVerdicts.minimumPlies),
                moments: [],
                cards: []
            ) != nil
        )
    }

    @Test("An unanalysed or unfinished game gets no verdict rather than a hedged one")
    func gates() {
        let unanalysed = ReviewVerdicts.verdict(
            game: finishedGame(analysis: .pending),
            moves: moveRows(count: 40),
            moments: [],
            cards: []
        )
        let unfinished = ReviewVerdicts.verdict(
            game: finishedGame(result: nil),
            moves: moveRows(count: 40),
            moments: [],
            cards: []
        )

        #expect(unanalysed == nil)
        #expect(unfinished == nil)
    }

    /// A row from before moments carried a payload, or one written by a build
    /// this one cannot decode. Summarising the game as one with no moments in
    /// it, directly above a filmstrip showing them, is a contradiction on a
    /// single screen.
    @Test("A slate that cannot be decoded produces no verdict at all")
    func undecodablePayload() {
        let id = UUID()
        let stored = storedMoment(id: id, coachText: "You left the knight loose.")
        let cards = ReviewMomentCards.cards(moments: [stored], orientation: .white, moveRows: [])

        let verdict = ReviewVerdicts.verdict(
            game: finishedGame(),
            moves: moveRows(count: 40),
            moments: [stored],
            cards: cards
        )

        #expect(cards.count == 1)
        #expect(verdict == nil)
    }
}

// MARK: - Comparison chip

@Suite("Stat comparison")
struct ReviewStatComparisonTests {

    private func comparison(_ value: Double, _ reference: Double) -> ReviewStatComparison {
        ReviewStatComparison(value: value, reference: reference, text: "your avg")
    }

    @Test("A caret is only drawn for a difference worth claiming")
    func deadBand() {
        #expect(comparison(84, 79).symbolName == "arrowtriangle.up.fill")
        #expect(comparison(74, 79).symbolName == "arrowtriangle.down.fill")
        // Inside the dead band: a caret here would report a trend that is
        // rounding error in the accuracy formula.
        #expect(comparison(79.2, 79).symbolName == "minus")
        #expect(comparison(79, 79).symbolName == "minus")
    }
}
