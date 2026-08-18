//
//  CoachVocabularyBridge.swift
//  ChessCoach
//

import ClaudeKit
import Foundation
import TrainingCore

/// Translates between the app's habit vocabulary and the coaching contract's.
///
/// `TrainingCore.Habit` and `ClaudeKit.CoachingVocabulary.Habit` are two
/// deliberately independent lists: the first is what the curriculum measures and
/// the focus selector ranks, the second is the closed enum the model is allowed
/// to answer with and the verifier checks against. They are not the same size
/// and they do not share ids, so any code that assumes `habit.rawValue` is a
/// valid `habitID` is silently sending an unknown value that the verifier will
/// reject on the way back.
///
/// The mapping is many-to-one in the app→contract direction (the contract splits
/// some habits more finely than the curriculum measures them) and many-to-one
/// the other way too. Both directions are total: an id from a newer contract
/// still lands somewhere the curriculum can track.
enum CoachVocabularyBridge {

    /// The coaching contract's habit id for a curriculum habit.
    static func habitID(for habit: Habit) -> String {
        switch habit {
        case .whatChanged: return "checkOpponentThreats"
        case .scanThreats: return "scanForcingMoves"
        case .candidatesFirst: return "makeAPlan"
        case .calcToQuiet: return "calculateToQuiet"
        case .blunderCheck: return "blunderCheckBeforeMoving"
        case .kingSafety: return "watchKingSafety"
        case .endgameTechnique: return "practiseEndgameTechnique"
        // The contract has no separate conversion habit; endgame technique is
        // the one whose metrics (`endgameConversionRate`) actually move when the
        // user learns to convert.
        case .convertCleanly: return "practiseEndgameTechnique"
        case .clockDiscipline: return "slowDownAtCriticalMoments"
        }
    }

    /// The curriculum habit a contract habit id maps back to.
    ///
    /// - Parameter rung: Only `followOpeningPrinciples` is rung-dependent, for
    ///   the same reason `CauseTag.habit(rung:)` is: at rung 1 an opening error
    ///   is a hung piece, and above it, a move-choice error.
    static func habit(forID id: String, rung: Int) -> Habit? {
        switch id {
        case "checkOpponentThreats": return .whatChanged
        case "blunderCheckBeforeMoving": return .blunderCheck
        case "scanForcingMoves": return .scanThreats
        case "calculateToQuiet", "countTheExchange": return .calcToQuiet
        case "tradeWithAPurpose", "makeAPlan": return .candidatesFirst
        case "watchKingSafety": return .kingSafety
        case "followOpeningPrinciples": return rung <= 1 ? .blunderCheck : .candidatesFirst
        case "practiseEndgameTechnique": return .endgameTechnique
        case "slowDownAtCriticalMoments": return .clockDiscipline
        default: return nil
        }
    }

    /// The thinking-algorithm step a habit belongs to, as the contract names it.
    static func stepTag(for habit: Habit) -> String {
        CoachingVocabulary.habit(id: habitID(for: habit))?.stepTag ?? "candidates"
    }

    /// A metric id the contract will accept for this habit's micro-goal.
    ///
    /// Must come from the habit's own list: `WeeklyFocusValidator` rejects a
    /// goal measured by a metric the habit cannot move, and sending one in the
    /// *request* would be inviting the model to echo it back and fail.
    static func metricID(for habit: Habit) -> String {
        CoachingVocabulary.habit(id: habitID(for: habit))?.metricIDs.first ?? habitID(for: habit)
    }

    /// How a leak is trending, in the contract's three-way vocabulary.
    ///
    /// `Leak.deltaVsPreviousWeek` is expected points per game, and is exactly
    /// zero when the comparison is undefined (one of the two weeks has no
    /// games), which is why the dead band is checked before the sign.
    static func trend(forDelta delta: Double, tolerance: Double = 0.005) -> CoachRequest.Trend {
        if abs(delta) <= tolerance { return .flat }
        // Positive delta means more expected points are being lost, i.e. worse.
        return delta > 0 ? .worsening : .improving
    }
}
