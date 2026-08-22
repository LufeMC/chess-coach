//
//  Habit.swift
//  TrainingCore
//

import Foundation

/// A trainable thinking habit.
///
/// This is the vocabulary the coach speaks in. The list is short and closed on
/// purpose: a user can hold exactly one behaviour change in their head at a
/// time, and "your rating leaks 38 points a game to missed opponent threats"
/// is not actionable, whereas "before every move, ask what your opponent's last
/// move attacked" is. Every leak the analysis finds has to land on one of
/// these nine or it cannot be coached.
public enum Habit: String, Sendable, Hashable, Codable, CaseIterable {

    /// "What changed?" — read the opponent's last move before anything else.
    case whatChanged

    /// Scan for opponent threats: checks, captures, attacks on loose pieces.
    case scanThreats

    /// Generate two or three candidate moves before calculating any of them.
    case candidatesFirst

    /// Calculate a forcing line to a quiet position before judging it.
    case calcToQuiet

    /// The final safety check: is the piece I am about to move, or leaving
    /// behind, hanging?
    case blunderCheck

    /// King safety: castle early, do not loosen the shelter without reason.
    case kingSafety

    /// Endgame technique: known winning and drawing methods.
    case endgameTechnique

    /// Convert a won position cleanly — simplify, avoid counterplay.
    case convertCleanly

    /// Clock discipline: spend time where the position is critical.
    case clockDiscipline

    /// A short imperative the coach can put on a chip.
    public var microGoalTitle: String {
        switch self {
        case .whatChanged: return "Ask what changed"
        case .scanThreats: return "Check opponent threats"
        case .candidatesFirst: return "List candidates first"
        case .calcToQuiet: return "Calculate to a quiet position"
        case .blunderCheck: return "Blunder-check every move"
        case .kingSafety: return "Keep the king safe"
        case .endgameTechnique: return "Use the known technique"
        case .convertCleanly: return "Convert cleanly"
        case .clockDiscipline: return "Spend time where it matters"
        }
    }
}

/// Why a mistake happened, as tagged by the analysis layer.
///
/// A `String`-backed value rather than an enum, and rather than an import: the
/// cause taxonomy lives in the analysis package and is stored as a plain
/// `String` column, and it will keep growing. Modelling it as a closed enum
/// here would mean this package fails to compile every time a detector is
/// added, and — worse — a tag synced down from a newer build would be
/// unrepresentable. An unknown tag simply maps to no habit and is reported
/// as unmapped.
public struct CauseTag: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }

    // Threat-related
    public static let missedNewThreat: CauseTag = "missedNewThreat"
    public static let ignoredStandingThreat: CauseTag = "ignoredStandingThreat"
    public static let missedForcingIdea: CauseTag = "missedForcingIdea"
    public static let kingExposure: CauseTag = "kingExposure"

    // Move-selection
    public static let forcingBias: CauseTag = "forcingBias"
    public static let planlessTrade: CauseTag = "planlessTrade"
    public static let positionalDrift: CauseTag = "positionalDrift"

    // Calculation
    public static let miscalculatedTactic: CauseTag = "miscalculatedTactic"
    public static let allowedDeepTactic: CauseTag = "allowedDeepTactic"
    public static let miscountedExchange: CauseTag = "miscountedExchange"

    // Board vision
    public static let hungMovedPiece: CauseTag = "hungMovedPiece"
    public static let hungLeftPiece: CauseTag = "hungLeftPiece"
    public static let allowedShallowTactic: CauseTag = "allowedShallowTactic"

    // Phase-specific
    public static let endgameTechnique: CauseTag = "endgameTechnique"
    public static let openingPrinciple: CauseTag = "openingPrinciple"

    /// Every tag this build knows how to coach.
    public static let known: [CauseTag] = [
        .missedNewThreat, .ignoredStandingThreat, .missedForcingIdea, .kingExposure,
        .forcingBias, .planlessTrade, .positionalDrift,
        .miscalculatedTactic, .allowedDeepTactic, .miscountedExchange,
        .hungMovedPiece, .hungLeftPiece, .allowedShallowTactic,
        .endgameTechnique, .openingPrinciple
    ]
}

extension CauseTag {

    /// The habit that fixes this cause.
    ///
    /// The mapping is many-to-one by design: several distinct analytical causes
    /// share a single behavioural fix, and the *fix* is what the user works on.
    /// Telling someone they have three separate problems when one checklist
    /// item addresses all three is how coaching advice becomes noise.
    ///
    /// - Parameter rung: The user's curriculum rung. Only
    ///   ``CauseTag/openingPrinciple`` is rung-dependent, and the reason is
    ///   worth stating: at rung 1 an opening mistake is almost always a piece
    ///   left hanging in the first ten moves, which is a blunder-check problem.
    ///   From rung 2 up the user has stopped dropping pieces and their opening
    ///   errors are genuine move-choice errors, which is a candidates problem.
    ///   Coaching "blunder-check harder" to a 1500 who played a dubious
    ///   gambit would be useless.
    public func habit(rung: Int) -> Habit? {
        switch self {
        case .missedNewThreat:
            return .whatChanged

        case .ignoredStandingThreat, .missedForcingIdea, .kingExposure:
            return .scanThreats

        case .forcingBias, .planlessTrade, .positionalDrift:
            return .candidatesFirst

        case .miscalculatedTactic, .allowedDeepTactic, .miscountedExchange:
            return .calcToQuiet

        case .hungMovedPiece, .hungLeftPiece, .allowedShallowTactic:
            return .blunderCheck

        case .endgameTechnique:
            return .endgameTechnique

        case .openingPrinciple:
            return rung <= 1 ? .blunderCheck : .candidatesFirst

        default:
            // An unknown tag from a newer build. No habit, no crash.
            return nil
        }
    }
}

extension Habit {

    /// Whether any `CauseTag` can nominate this habit.
    ///
    /// `CauseTag.habit(rung:)` maps sixteen detector tags onto six habits, so
    /// three of the nine are unreachable from a leak: nothing detects "you
    /// failed to convert a won game", "you managed the clock badly", or a king
    /// exposure that is about king safety rather than a missed threat
    /// (`kingExposure` is deliberately routed to `scanThreats`). A rung whose
    /// required skill names one of the three could never make it the week's
    /// focus — see `FocusSelector.unaskedRungHabits`, which is what stops that
    /// being a dead end.
    ///
    /// Derived rather than hardcoded so it cannot drift: it asks the map, over
    /// `CauseTag.known`, which is the roster the tagger actually emits.
    public static func hasCauseTag(_ habit: Habit) -> Bool {
        causeBackedHabits.contains(habit)
    }

    /// Every habit some cause tag maps to, at any rung.
    private static let causeBackedHabits: Set<Habit> = {
        var out: Set<Habit> = []
        for tag in CauseTag.known {
            for rung in 1...4 {
                if let habit = tag.habit(rung: rung) { out.insert(habit) }
            }
        }
        return out
    }()
}
