import AnalysisKit
import EngineKit
import Foundation
import TrainingCore

/// Decides when to interrupt a game with a coaching question, and which one.
///
/// Guided mode is the one feature that can actively make the app worse if it is
/// tuned wrong. Every pause is a tax on the user's flow, and — more subtly — the
/// pause itself leaks information: stopping the clock at a position tells the
/// user "this one matters" before they have done any thinking. That is why the
/// budget is small (3 per game), why there is a cooldown, and why calibration
/// games disable it entirely.
///
/// Pure policy: no engine, no state mutation. The caller supplies evaluations
/// and receives a decision, which makes the whole thing testable without playing
/// a game.
struct GuidedMode: Sendable {

    /// A question the coach asks instead of an answer it gives.
    struct Prompt: Sendable, Equatable {
        var habit: Habit
        var question: String
        var ply: Int
    }

    /// Everything the gate needs to judge one position.
    struct Context: Sendable {
        var ply: Int
        var fullMoveNumber: Int
        var userClockMs: Int
        var pausesUsedThisGame: Int
        var pliesSinceLastPause: Int
        /// Best and second-best lines for the side to move.
        var best: UCIInfo
        var secondBest: UCIInfo?
        /// The strongest threat the opponent has if the user passes, in expected
        /// points. Produced by a null-move probe; nil when it wasn't run.
        var nullMoveThreatEP: Double?
        /// Whether the opponent's free move in that probe is one the user would
        /// have to answer — a check, a capture or a promotion.
        ///
        /// The expected-points figure on its own cannot tell a threat from the
        /// user's own tactic or from zugzwang; both make a free move valuable
        /// without anything being threatened. See
        /// ``GameSession/isForcing(uci:inNullMovePosition:)`` for why the test is
        /// deliberately narrower than the truth.
        var nullMoveThreatIsForcing: Bool = false
        /// True when the engine's best move is quiet (no check, capture, or
        /// promotion).
        var bestMoveIsQuiet: Bool
        /// True when the engine's best move parries the null-move threat.
        var bestMoveIsProphylactic: Bool
        var phase: Phase
        var userExpectedPoints: Double
        /// Whether the user has been moving quickly this game relative to budget.
        var userIsMovingFast: Bool
    }

    struct Budget: Sendable {
        /// Interruptions cost flow; three is enough to teach a habit in one game.
        var maxPausesPerGame = 3
        /// Never pause twice in quick succession — the second one stops reading
        /// as "this position is special" and starts reading as nagging.
        var minPliesBetweenPauses = 8
        /// Opening moves are usually book or obvious; pausing there teaches
        /// nothing.
        var minFullMoveNumber = 6
        /// Don't interrupt someone in time trouble.
        var minClockMs = 30_000
        /// The last pause of the game is held back until here.
        ///
        /// Three pauses, an eight-ply cooldown and an opening floor of move six
        /// means the entire budget can be spent by move fourteen — and it
        /// usually is, because the gate is first-come and the sharpest gaps of a
        /// game against a 1000–1500 opponent are early. Then a genuinely
        /// instructive quiet position on move thirty gets nothing, because the
        /// coach spent its questions on the first sharp thing it saw. Holding one
        /// back costs nothing in a short game — an unspent pause was never worth
        /// anything — and buys a question in the phase where these games are
        /// actually decided.
        var reservedPauseMinFullMoveNumber = 20

        /// Criticality bar for a generic pause.
        var genericGapThreshold = 0.10
        /// A lower bar applies when the position also matches the week's focus
        /// habit — those are the positions the user is specifically training for,
        /// so it is worth spending a pause on a slightly less sharp one.
        var focusGapThreshold = 0.07

        static let `default` = Budget()
    }

    var focusHabit: Habit
    var budget: Budget = .default

    /// Returns a prompt when this position is worth interrupting for.
    func prompt(for context: Context) -> Prompt? {
        guard context.fullMoveNumber >= budget.minFullMoveNumber else { return nil }
        guard context.pausesUsedThisGame < budget.maxPausesPerGame else { return nil }
        guard
            context.pausesUsedThisGame < budget.maxPausesPerGame - 1
                || context.fullMoveNumber >= budget.reservedPauseMinFullMoveNumber
        else { return nil }
        guard context.pliesSinceLastPause >= budget.minPliesBetweenPauses else { return nil }
        guard context.userClockMs > budget.minClockMs else { return nil }

        let gap = criticalityGap(context)

        // A position matching the focus habit's own trigger clears a lower bar:
        // these are the positions the user is specifically training for, so a
        // slightly less sharp one is still worth a pause.
        let focusMatches = matchesFocusPredicate(context)
        let threshold = focusMatches ? budget.focusGapThreshold : budget.genericGapThreshold
        guard gap >= threshold else { return nil }

        // Which question to ask is a separate decision from whether to pause.
        //
        // Some habits have predicates that match essentially any sharp position
        // — blunderCheck is the obvious one, since "could this move be refuted?"
        // always applies. Letting those claim every pause would mean a user
        // whose focus is blunderCheck gets asked about refutations even in a
        // position that is plainly about converting a won game. So a
        // non-discriminating focus yields to a situational habit that actually
        // fits; a discriminating one keeps the pause it earned.
        let habit: Habit
        if focusMatches, focusHabit.hasDiscriminatingTrigger {
            habit = focusHabit
        } else {
            habit = situationalHabit(for: context) ?? focusHabit
        }
        return Prompt(habit: habit, question: question(for: habit), ply: context.ply)
    }

    /// How much better the best move is than the alternative, in expected points.
    private func criticalityGap(_ context: Context) -> Double {
        guard let second = context.secondBest else { return 0 }
        let best = EvalMath.expectedPoints(score: context.best.score)
        let alternative = EvalMath.expectedPoints(score: second.score)
        return best - alternative
    }

    /// Whether this position is the kind the focus habit exists to train.
    func matchesFocusPredicate(_ context: Context) -> Bool {
        switch focusHabit {
        case .whatChanged, .scanThreats:
            return hasThreat(context)
        case .candidatesFirst:
            return context.bestMoveIsQuiet
        case .calcToQuiet:
            return !context.bestMoveIsQuiet && context.best.pv.count >= 4
        case .blunderCheck:
            return true
        case .kingSafety:
            return context.phase != .endgame
        case .endgameTechnique:
            return context.phase == .endgame
        case .convertCleanly:
            return context.userExpectedPoints >= 0.85
        case .clockDiscipline:
            return context.userIsMovingFast
        }
    }

    /// Whether the opponent actually threatens something here.
    ///
    /// Two conditions, not one. The expected-points figure says a free move
    /// would be worth a lot to the opponent; the forcing bit says there is
    /// something on the board for the user to *find*. Without the second, the
    /// same number fires on a position that is entirely about the user's own
    /// tactic and on zugzwang in a pawn ending — and the question this gates
    /// ("what are every check, capture, and threat — theirs first?") is then
    /// unanswerable, while the move the user plays anyway is recorded as having
    /// answered it.
    private func hasThreat(_ context: Context) -> Bool {
        (context.nullMoveThreatEP ?? 0) >= 0.10 && context.nullMoveThreatIsForcing
    }

    /// Picks a habit that matches what actually makes this position sharp, so a
    /// generic pause still asks a relevant question rather than the week's habit
    /// regardless of fit.
    private func situationalHabit(for context: Context) -> Habit? {
        // An endgame with nothing forcing available is about technique, and the
        // threat branch has to yield to it rather than the other way round: in a
        // pawn ending the null-move number is large precisely *because* someone
        // has to move, so the threat question would win every time and ask about
        // checks and captures that are not on the board.
        if context.phase == .endgame, !context.nullMoveThreatIsForcing { return .endgameTechnique }
        if hasThreat(context) { return .scanThreats }
        if context.bestMoveIsProphylactic { return .scanThreats }
        if context.userExpectedPoints >= 0.85 { return .convertCleanly }
        if context.phase == .endgame { return .endgameTechnique }
        if context.bestMoveIsQuiet { return .candidatesFirst }
        return nil
    }

    /// The question bank.
    ///
    /// Every question is answerable *from the position* and names no move — the
    /// point is to hand back the thinking step the user skipped, not the answer.
    /// A question containing notation would do the work for them.
    func question(for habit: Habit) -> String {
        switch habit {
        case .whatChanged:
            "Their last move changed something. What does it now attack, defend, or leave behind?"
        case .scanThreats:
            "Before you move: what are every check, capture, and threat — theirs first?"
        case .candidatesFirst:
            "Name two candidate moves that fit your plan, before you calculate anything."
        case .calcToQuiet:
            "Pick your move, then calculate the forcing line until it goes quiet. What does the final position look like?"
        case .blunderCheck:
            "Whatever you're about to play — what's their most annoying check or capture in reply?"
        case .kingSafety:
            "How safe is your king three moves from now? Which square around it is weakest?"
        case .endgameTechnique:
            "Where does your king need to stand here? Can you force it there?"
        // No verdict in the sentence. `convertCleanly` is reached two ways —
        // because the position matches its 0.85 predicate, and as the fallback
        // when the week's focus habit is this one and nothing else fits — and on
        // the second route "You're winning" is an eval assertion the engine
        // never made. Even on the first it primes exactly the wrong thing: a
        // 1200 who is told they are winning stops looking for the counterplay
        // this question is asking them to find.
        case .convertCleanly:
            "What's their only source of counterplay here, and can you take it away?"
        case .clockDiscipline:
            "This one deserves real time. What makes it different from the last three moves?"
        }
    }

    /// Scores the user's answer — which is simply the move they then play.
    ///
    /// There is no text input: asking someone to type an answer mid-game would
    /// cost more flow than the question is worth, and the move they choose is a
    /// more honest signal than what they say they were thinking.
    static func grade(playedMove: String, best: UCIInfo, secondBest: UCIInfo?) -> Double {
        guard let bestMove = best.bestMove else { return 0 }
        if playedMove == bestMove { return 1.0 }

        // Within a hair of best still shows the user saw the idea.
        //
        // "A hair" is the app's own inaccuracy bar rather than a number of this
        // rule's own, and the difference is the whole reason this branch works
        // at all. A pause only happens when best beats second by at least
        // `focusGapThreshold` (0.07), so a tier keyed to 0.05 could never fire:
        // the two constants were written apart and the near-miss tier had been
        // dead ever since, quietly recording a user who parried the threat with
        // the engine's second choice as having missed the idea entirely.
        //
        // `EvalMath.inaccuracyThreshold` is also the only bar that keeps this
        // verdict consistent with the rest of the app: a move the post-game pass
        // will not even call an inaccuracy is not one the coach should be
        // marking wrong in front of the user mid-game.
        if let second = secondBest, playedMove == second.bestMove {
            let gap = EvalMath.expectedPoints(score: best.score)
                - EvalMath.expectedPoints(score: second.score)
            return gap < EvalMath.inaccuracyThreshold ? 0.7 : 0
        }
        return 0
    }
}

extension Habit {
    /// Whether this habit's trigger actually narrows the field.
    ///
    /// `blunderCheck` applies to every sharp position by definition — "could
    /// this move be refuted?" is always a fair question — so it can never lose a
    /// tie-break on specificity. Treating it as discriminating would let it
    /// answer for positions another habit describes far better, which is exactly
    /// what a weekly focus of blunderCheck would otherwise cause.
    var hasDiscriminatingTrigger: Bool {
        self != .blunderCheck
    }
}
