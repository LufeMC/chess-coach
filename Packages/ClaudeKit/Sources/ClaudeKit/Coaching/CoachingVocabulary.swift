//
//  CoachingVocabulary.swift
//  ClaudeKit
//

import Foundation

/// The closed vocabulary the coaching contract is written against.
///
/// Habits and cause tags are enumerated rather than free text for one reason:
/// the app has to be able to act on them. A habit id selects a drill mix and a
/// progress metric; a cause tag selects a fallback question. A near-miss string
/// the model invented ("checkThreats") would look fine in prose and silently do
/// nothing, so anything outside these lists is a verification failure.
public enum CoachingVocabulary {

    // MARK: Habits

    /// A weekly focus habit: one behaviour, one step of the thinking algorithm,
    /// and the metrics that show whether it is taking hold.
    public struct Habit: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// The thinking-algorithm step this habit trains.
        public var stepTag: String
        /// Metrics that belong to this habit. A micro-goal must target one of
        /// these — a goal measured by an unrelated metric cannot be moved by
        /// practising the habit.
        public var metricIDs: [String]
        /// Cause tags this habit is the natural answer to.
        public var causeTags: [String]

        public init(id: String, title: String, stepTag: String, metricIDs: [String], causeTags: [String]) {
            self.id = id
            self.title = title
            self.stepTag = stepTag
            self.metricIDs = metricIDs
            self.causeTags = causeTags
        }
    }

    public static let habits: [Habit] = [
        Habit(
            id: "checkOpponentThreats",
            title: "Ask what their move threatens",
            stepTag: "threats",
            metricIDs: ["ignoredStandingThreatRate", "missedNewThreatRate", "threatScanHitRate"],
            causeTags: ["missedNewThreat", "ignoredStandingThreat"]
        ),
        Habit(
            id: "blunderCheckBeforeMoving",
            title: "Check your move is safe before playing it",
            stepTag: "safety",
            metricIDs: ["hangRatePerGame", "blunderCheckHitRate", "movedIntoAttackRate"],
            causeTags: ["hungMovedPiece", "hungLeftPiece"]
        ),
        Habit(
            id: "scanForcingMoves",
            title: "Look at every check, capture and threat",
            stepTag: "candidates",
            metricIDs: ["missedForcingRate", "forcingScanHitRate", "tacticFoundRate"],
            causeTags: ["missedForcingIdea", "allowedShallowTactic", "allowedDeepTactic"]
        ),
        Habit(
            id: "calculateToQuiet",
            title: "Calculate forcing lines to a quiet position",
            stepTag: "calculate",
            metricIDs: ["calculationErrorRate", "depthReachedAvg", "tacticConversionRate"],
            causeTags: ["miscalculatedTactic", "allowedDeepTactic"]
        ),
        Habit(
            id: "countTheExchange",
            title: "Count the exchange before you take",
            stepTag: "safety",
            metricIDs: ["exchangeErrorRate", "seeAccuracy"],
            causeTags: ["miscountedExchange", "planlessTrade"]
        ),
        Habit(
            id: "tradeWithAPurpose",
            title: "Name a reason before each trade",
            stepTag: "plan",
            metricIDs: ["purposelessTradeRate", "structureAfterTradeScore"],
            causeTags: ["planlessTrade", "positionalDrift"]
        ),
        Habit(
            id: "makeAPlan",
            title: "Name the worst piece and improve it",
            stepTag: "plan",
            metricIDs: ["planlessMoveRate", "pieceActivityDelta"],
            causeTags: ["positionalDrift", "planlessTrade"]
        ),
        Habit(
            id: "watchKingSafety",
            title: "Check what the pawn move does to your king",
            stepTag: "safety",
            metricIDs: ["kingExposureRate", "castleByMoveRate"],
            causeTags: ["kingExposure"]
        ),
        Habit(
            id: "followOpeningPrinciples",
            title: "Develop, castle, connect — in that order",
            stepTag: "opening",
            metricIDs: ["developmentByMove10", "openingPrincipleBreachRate"],
            causeTags: ["openingPrinciple"]
        ),
        Habit(
            id: "practiseEndgameTechnique",
            title: "Convert with technique, not hope",
            stepTag: "endgame",
            metricIDs: ["endgameConversionRate", "endgameAccuracy"],
            causeTags: ["endgameTechnique"]
        ),
        Habit(
            id: "slowDownAtCriticalMoments",
            title: "Spend your time where the game turns",
            stepTag: "time",
            metricIDs: ["criticalMomentThinkShare", "impulseErrorRate"],
            causeTags: ["forcingBias", "miscalculatedTactic"]
        )
    ]

    /// Habit ids the model may return.
    public static let habitIDs: Set<String> = Set(habits.map(\.id))

    public static func habit(id: String) -> Habit? {
        habits.first { $0.id == id }
    }

    /// Whether a micro-goal metric belongs to a habit. Enforced by the app
    /// rather than trusted from the model.
    public static func metric(_ metricID: String, belongsTo habitID: String) -> Bool {
        habit(id: habitID)?.metricIDs.contains(metricID) ?? false
    }

    /// The habit that best answers a cause tag, used when a fallback has to
    /// pick one without the model's help.
    public static func habit(forCauseTag causeTag: String) -> Habit? {
        habits.first { $0.causeTags.contains(causeTag) }
    }

    // MARK: Cause tags

    /// Every cause the app's detectors can assign.
    public static let causeTags: [String] = [
        "hungMovedPiece",
        "hungLeftPiece",
        "missedNewThreat",
        "ignoredStandingThreat",
        "allowedShallowTactic",
        "allowedDeepTactic",
        "miscalculatedTactic",
        "missedForcingIdea",
        "forcingBias",
        "miscountedExchange",
        "planlessTrade",
        "kingExposure",
        "endgameTechnique",
        "openingPrinciple",
        "positionalDrift"
    ]

}
