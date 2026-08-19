//
//  CalibrationStepsTests.swift
//  ChessCoachTests
//

import Testing
import TrainingCore

@testable import ChessCoach

/// The four-step framing every calibration screen carries.
///
/// Calibration gates the whole app, so "how much more of this is there" is the
/// question a first-run user asks loudest and the one the phases alone could not
/// answer: they name the two stretches of work and silently omit the question at
/// the front and the result at the back.
@MainActor
@Suite("Calibration steps")
struct CalibrationStepsTests {

    private var estimate: CalibrationEstimate {
        CalibrationEstimate(
            rating: 1240,
            sigma: 145,
            gameEstimate: 1300,
            gameSigma: 180,
            puzzleEstimate: 1180,
            puzzleSigma: 190,
            ceilingNotFound: false,
            floorNotFound: false,
            startingRung: 2
        )
    }

    @Test("The flow is four steps, numbered from one")
    func stepsAreNumbered() {
        #expect(CalibrationStep.count == 4)
        #expect(CalibrationStep.allCases.map(\.position) == [1, 2, 3, 4])
    }

    /// Every stage the flow can be in has a step, including the two that ask
    /// for no work — otherwise the header would vanish exactly where the user
    /// most wants to know how far in they are.
    @Test("Every stage maps to a step")
    func stagesMapToSteps() {
        #expect(CalibrationModel.Stage.intro.step == .question)
        #expect(CalibrationModel.Stage.games.step == .games)
        #expect(CalibrationModel.Stage.puzzles.step == .puzzles)
        #expect(CalibrationModel.Stage.reveal(estimate).step == .result)
    }

    /// The reveal is the last step rather than something after the flow. A
    /// result presented outside the progression reads as an interruption, and
    /// the whole point of the counter is that the payoff is inside it.
    @Test("The result is the final step, not an epilogue")
    func resultIsTheLastStep() {
        #expect(CalibrationStep.result.position == CalibrationStep.count)
    }

    @Test("The two working phases are the two middle steps")
    func phasesMapToSteps() {
        #expect(CalibrationPhase.games.step == .games)
        #expect(CalibrationPhase.puzzles.step == .puzzles)
    }

    /// The counter names the item being worked on, so it reads 1 before the
    /// first game rather than 0.
    @Test("The position leads the completed count by one")
    func positionLeadsCompletion() {
        var progress = CalibrationProgress(required: [5, 20], completed: [0, 0], phaseIndex: 0)
        #expect(progress.currentPosition == 1)

        progress.recordItem()
        #expect(progress.currentPosition == 2)
        #expect(progress.counterLabel == "Game 2 of 5")
    }

    @Test("The position never runs past the requirement")
    func positionClamps() {
        let progress = CalibrationProgress(required: [5, 20], completed: [5, 0], phaseIndex: 0)
        #expect(progress.currentPosition == 5)
    }

    /// Every step says what it contributes, because the question the disclosure
    /// is really asked is not "how many are left" but "is any of this optional".
    @Test("Every step states what it contributes")
    func stepsExplainThemselves() {
        for step in CalibrationStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.contribution.isEmpty)
        }
    }
}
