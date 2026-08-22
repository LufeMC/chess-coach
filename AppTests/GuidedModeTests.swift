import AnalysisKit
import EngineKit
import Testing
import TrainingCore

@testable import ChessCoach

/// The guided-mode gate is the one feature that can actively make the app worse
/// if it is tuned wrong: every pause taxes the user's flow, and the pause itself
/// leaks that the position matters. These tests pin the budget rules rather than
/// the question wording, which is expected to be edited.
@Suite("Guided mode")
struct GuidedModeTests {

    /// A position where the best move is decisively better than the alternative.
    private func criticalContext(
        ply: Int = 30,
        fullMoveNumber: Int = 15,
        userClockMs: Int = 300_000,
        pausesUsed: Int = 0,
        pliesSinceLastPause: Int = 20,
        threatEP: Double? = nil,
        /// Defaults to true so a fixture that names a threat gets a real one.
        /// The gate requires both: a big null-move number with nothing forcing
        /// behind it is zugzwang or the user's own tactic, not a threat.
        threatIsForcing: Bool = true,
        bestIsQuiet: Bool = false,
        bestIsProphylactic: Bool = false,
        phase: Phase = .middlegame,
        userEP: Double = 0.5,
        movingFast: Bool = false
    ) -> GuidedMode.Context {
        GuidedMode.Context(
            ply: ply,
            fullMoveNumber: fullMoveNumber,
            userClockMs: userClockMs,
            pausesUsedThisGame: pausesUsed,
            pliesSinceLastPause: pliesSinceLastPause,
            best: UCIInfo(multipv: 1, score: .centipawns(120), pv: ["e2e4", "e7e5", "g1f3", "b8c6"]),
            // ~0.30 expected points worse — comfortably over any threshold.
            secondBest: UCIInfo(multipv: 2, score: .centipawns(-140), pv: ["d2d4"]),
            nullMoveThreatEP: threatEP,
            nullMoveThreatIsForcing: threatIsForcing,
            bestMoveIsQuiet: bestIsQuiet,
            bestMoveIsProphylactic: bestIsProphylactic,
            phase: phase,
            userExpectedPoints: userEP,
            userIsMovingFast: movingFast
        )
    }

    private var gate: GuidedMode {
        GuidedMode(focusHabit: .blunderCheck)
    }

    @Test("Pauses at a genuinely critical position")
    func pausesWhenCritical() {
        #expect(gate.prompt(for: criticalContext()) != nil)
    }

    @Test("Never pauses in the opening")
    func skipsOpening() {
        // Early moves are book or obvious; a pause there teaches nothing.
        #expect(gate.prompt(for: criticalContext(fullMoveNumber: 4)) == nil)
    }

    @Test("Respects the per-game pause budget")
    func respectsBudget() {
        #expect(gate.prompt(for: criticalContext(pausesUsed: 3)) == nil)
        // Past the reserve, so the third pause is refused by the budget alone.
        #expect(gate.prompt(for: criticalContext(fullMoveNumber: 24, pausesUsed: 2)) != nil)
    }

    @Test("Enforces a cooldown between pauses")
    func enforcesCooldown() {
        // Back-to-back pauses stop reading as "this position is special" and
        // start reading as nagging.
        #expect(gate.prompt(for: criticalContext(pliesSinceLastPause: 3)) == nil)
        #expect(gate.prompt(for: criticalContext(pliesSinceLastPause: 8)) != nil)
    }

    @Test("Never interrupts someone in time trouble")
    func skipsTimeTrouble() {
        #expect(gate.prompt(for: criticalContext(userClockMs: 20_000)) == nil)
    }

    @Test("Ignores quiet positions with no clear best move")
    func ignoresFlatPositions() {
        var context = criticalContext()
        // Both moves equal: nothing to notice, so nothing to ask about.
        context.secondBest = UCIInfo(multipv: 2, score: .centipawns(118), pv: ["d2d4"])
        #expect(gate.prompt(for: context) == nil)
    }

    @Test("A focus-habit position clears a lower criticality bar")
    func focusHabitLowersBar() {
        var gate = GuidedMode(focusHabit: .scanThreats)
        gate.budget = .default

        // The win% curve is far from linear near equality: +40cp is only ~0.037
        // expected points, which would sit under *both* bars. +90cp gives ~0.082
        // — over the focus bar, under the generic one, which is the case this
        // test exists to pin.
        var context = criticalContext(threatEP: 0.15)
        context.best = UCIInfo(multipv: 1, score: .centipawns(90), pv: ["e2e4"])
        context.secondBest = UCIInfo(multipv: 2, score: .centipawns(0), pv: ["d2d4"])

        let prompt = gate.prompt(for: context)
        #expect(prompt?.habit == .scanThreats)

        // The same position without the threat predicate stays under the bar.
        var withoutThreat = context
        withoutThreat.nullMoveThreatEP = nil
        #expect(gate.prompt(for: withoutThreat) == nil)
    }

    @Test("A generic critical position asks a habit that fits the position")
    func situationalHabitSelection() {
        // Focus is blunderCheck, but the position is about conversion — asking
        // the week's habit regardless of fit would waste the interruption.
        let winning = criticalContext(userEP: 0.9)
        #expect(gate.prompt(for: winning)?.habit == .convertCleanly)

        let threatened = criticalContext(threatEP: 0.2)
        #expect(gate.prompt(for: threatened)?.habit == .scanThreats)
    }

    @Test("No question contains move notation")
    func questionsNeverGiveTheAnswer() {
        // The entire point is handing back the thinking step, not the answer.
        // Notation in a question would do the work for the user.
        let notation = /\b([KQRBN]?[a-h][1-8]|O-O(-O)?)\b/
        for habit in Habit.allCases {
            let question = gate.question(for: habit)
            #expect(question.firstMatch(of: notation) == nil, "\(habit) question leaks notation: \(question)")
        }
    }

    @Test("Grading rewards the best move and near-equals only")
    func grading() {
        let best = UCIInfo(multipv: 1, score: .centipawns(100), pv: ["e2e4"])
        let nearEqual = UCIInfo(multipv: 2, score: .centipawns(96), pv: ["d2d4"])
        let clearlyWorse = UCIInfo(multipv: 2, score: .centipawns(-200), pv: ["a2a3"])

        #expect(GuidedMode.grade(playedMove: "e2e4", best: best, secondBest: nearEqual) == 1.0)
        #expect(GuidedMode.grade(playedMove: "d2d4", best: best, secondBest: nearEqual) == 0.7)
        #expect(GuidedMode.grade(playedMove: "a2a3", best: best, secondBest: clearlyWorse) == 0)
    }

    /// The near-miss tier used to be keyed to 0.05 while the loosest bar that
    /// can produce a pause is 0.07, so it could never fire: every second-best a
    /// user could actually be graded against was scored a flat miss.
    @Test("A second-best inside the inaccuracy bar is reachable, and outside it is not")
    func nearMissTierIsReachable() {
        let best = UCIInfo(multipv: 1, score: .centipawns(100), pv: ["e2e4"])

        // ~0.06 expected points worse: over the focus bar that let the pause
        // happen at all, and not something the review would call an inaccuracy.
        let inside = UCIInfo(multipv: 2, score: .centipawns(34), pv: ["d2d4"])
        #expect(GuidedMode.grade(playedMove: "d2d4", best: best, secondBest: inside) == 0.7)

        // ~0.11 — an inaccuracy by the app's own scale, so the coach and the
        // post-game pass agree it was not the move the position asked for.
        let outside = UCIInfo(multipv: 2, score: .centipawns(-20), pv: ["d2d4"])
        #expect(GuidedMode.grade(playedMove: "d2d4", best: best, secondBest: outside) == 0)
    }

    /// The null-move number cannot tell a threat from zugzwang: in a pawn ending
    /// it is large precisely *because* somebody has to move. Asking "what are
    /// every check, capture, and threat" in a position that has none is the one
    /// case where the question cannot be answered from the board at all.
    @Test("An endgame with nothing forcing asks about technique, not threats")
    func endgameOutranksAPhantomThreat() {
        let quietEnding = criticalContext(threatEP: 0.30, threatIsForcing: false, phase: .endgame)
        #expect(gate.prompt(for: quietEnding)?.habit == .endgameTechnique)

        // A pawn about to queen is a threat, and then the threat question wins.
        let realThreat = criticalContext(threatEP: 0.30, threatIsForcing: true, phase: .endgame)
        #expect(gate.prompt(for: realThreat)?.habit == .scanThreats)
    }

    /// The value of the tempo is high whenever the *user* has a tactic the
    /// opponent could defuse, so the raw number credits threat-awareness for
    /// positions that never required a threat scan.
    @Test("A threat number with nothing forcing behind it is not a threat")
    func nonForcingThreatDoesNotMatchTheFocusPredicate() {
        var gate = GuidedMode(focusHabit: .scanThreats)
        gate.budget = .default

        // Over the focus bar, under the generic one — so the pause depends
        // entirely on whether this counts as a threat.
        var context = criticalContext(threatEP: 0.15, threatIsForcing: false)
        context.best = UCIInfo(multipv: 1, score: .centipawns(90), pv: ["e2e4"])
        context.secondBest = UCIInfo(multipv: 2, score: .centipawns(0), pv: ["d2d4"])

        #expect(gate.prompt(for: context) == nil)
    }

    /// Three pauses, an eight-ply cooldown and an opening floor of move six
    /// means the whole budget can be gone by move fourteen — and against a
    /// 1000–1500 opponent the sharpest gaps are early, so it usually is.
    @Test("The last pause of the game is held back for the middlegame")
    func lastPauseIsReserved() {
        let earlyThird = criticalContext(fullMoveNumber: 14, pausesUsed: 2)
        #expect(gate.prompt(for: earlyThird) == nil)

        let laterThird = criticalContext(fullMoveNumber: 24, pausesUsed: 2)
        #expect(gate.prompt(for: laterThird) != nil)

        // The first two are unaffected: holding one back is not a cooldown.
        #expect(gate.prompt(for: criticalContext(fullMoveNumber: 14, pausesUsed: 1)) != nil)
    }

    /// The house rule: coaching copy never asserts something the engine did not
    /// verify. `convertCleanly` is reached two ways, and on the fallback route —
    /// the week's focus habit with nothing else fitting — nothing has checked
    /// that the user is winning at all.
    @Test("No question states a verdict on the position")
    func questionsNeverAssertAnEvaluation() {
        for habit in Habit.allCases {
            let question = gate.question(for: habit)
            #expect(!question.contains("You're winning"))
            #expect(!question.contains("You are winning"))
            #expect(!question.contains("You're losing"))
        }
    }
}
