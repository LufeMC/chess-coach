//
//  CauseTagger.swift
//  AnalysisKit
//

import ChessKit

/// The coachable cause of a mistake — the "why", in the app's own vocabulary.
public enum CauseTag: String, Sendable, Codable, CaseIterable {
    case missedNewThreat
    case ignoredStandingThreat
    case hungMovedPiece
    case hungLeftPiece
    case allowedShallowTactic
    case allowedDeepTactic
    case miscalculatedTactic
    case missedForcingIdea
    case forcingBias
    case miscountedExchange
    case planlessTrade
    case kingExposure
    case endgameTechnique
    case openingPrinciple
    case positionalDrift
    /// Nothing specific fired. Kept so every move maps to something.
    case generic
}

/// Which step of the thinking routine broke down.
///
/// The app teaches a five-step move routine plus a knowledge bucket; pointing at
/// the step is what turns "you blundered" into something a player can practise.
public enum StepTag: String, Sendable, Codable, CaseIterable {
    /// What changed with the opponent's last move.
    case s1WhatChanged = "S1"
    /// Checks, captures and threats.
    case s2ChecksCapturesThreats = "S2"
    /// Candidate moves.
    case s3Candidates = "S3"
    /// Calculation.
    case s4Calculate = "S4"
    /// Blunder check before moving.
    case s5BlunderCheck = "S5"
    /// Knowledge, not process.
    case kKnowledge = "K"
}

/// Modifiers the time overlays can attach.
public enum MistakeModifier: String, Sendable, Codable, CaseIterable {
    /// Moved fast in a position that needed thought.
    case impulse
    /// Thought for a long time and still missed it.
    case deepMiss
    /// Played with very little time on the clock.
    case clockPressure
    /// Lost on time.
    case flagged
}

/// The tagged outcome for one move.
public struct Mistake: Sendable, Equatable, Codable {
    public let causeTag: CauseTag
    public let stepTag: StepTag
    public let modifiers: [String]
    /// `detector.subtype` keys for every finding that was not chosen as primary.
    public let secondaryTags: [String]
    /// Expected points lost.
    public let severity: Double

    public init(
        causeTag: CauseTag,
        stepTag: StepTag,
        modifiers: [String] = [],
        secondaryTags: [String] = [],
        severity: Double
    ) {
        self.causeTag = causeTag
        self.stepTag = stepTag
        self.modifiers = modifiers
        self.secondaryTags = secondaryTags
        self.severity = severity
    }
}

/// Turns a pile of findings into one cause and one step.
///
/// Two rules do all the work:
///
/// 1. **Priority.** When several detectors fire, the one that best explains *why
///    the move failed* wins. Hanging the piece you just moved beats everything —
///    it is the most concrete, most fixable error there is. Knowledge findings
///    (opening, endgame) come last because they describe a gap rather than a
///    thinking failure.
/// 2. **Time overlays.** Applied after the base mapping, and only to the *step*.
///    A tactic missed in two seconds is not a calculation failure — nothing was
///    calculated — so the coaching moves back to S2. The overlays never touch S1,
///    S3 or K: you cannot fail to calculate something you never got to.
public enum CauseTagger {

    public static func tag(
        findings: [Finding],
        context: MoveContext
    ) -> Mistake {
        let ordered = findings.sorted { priority(of: $0) < priority(of: $1) }
        let primary = ordered.first { baseMapping(for: $0) != nil }

        let base: (cause: CauseTag, step: StepTag)
        if let primary, let mapped = baseMapping(for: primary) {
            base = mapped
        } else {
            base = fallbackMapping(context)
        }

        let secondaryTags = findings
            .filter { $0 != primary }
            .map(\.tagKey)

        var step = base.step
        var modifiers: [String] = []

        // O1: an impulsive move in a critical position is a candidate-generation
        // failure dressed up as a calculation failure.
        if context.thinkBucket == .fast,
            context.isCritical,
            step == .s4Calculate || step == .s5BlunderCheck {
            step = .s2ChecksCapturesThreats
            modifiers.append(MistakeModifier.impulse.rawValue)
        }

        // O2: a long think that still walked into it means the blunder check did
        // happen — the calculation inside it was wrong.
        if context.thinkBucket == .long, step == .s5BlunderCheck {
            step = .s4Calculate
            modifiers.append(MistakeModifier.deepMiss.rawValue)
        }

        // O3: clock pressure explains, it does not relocate.
        if context.clockPressure {
            modifiers.append(MistakeModifier.clockPressure.rawValue)
        }

        if context.didFlag {
            modifiers.append(MistakeModifier.flagged.rawValue)
        }

        return Mistake(
            causeTag: base.cause,
            stepTag: step,
            modifiers: modifiers,
            secondaryTags: secondaryTags,
            severity: context.deltaEP
        )
    }

    // MARK: Priority

    /// Lower is higher priority. `timeError` is deliberately unranked: it never
    /// becomes the primary cause, only a modifier.
    public static func priority(of finding: Finding) -> Int {
        switch (finding.detector, finding.subtype) {
        case (.hangingPiece, .moved): 0
        case (.ignoredThreat, _): 1
        case (.allowedTactic, _): 2
        case (.hangingPiece, .left): 3
        case (.missedTactic, _): 4
        case (.wrongTrade, _): 5
        case (.kingWeakeningPawnMove, _): 6
        case (.endgameTechnique, _): 7
        case (.missedQuietMove, _): 8
        case (.openingPrinciple, _): 9
        default: 100
        }
    }

    // MARK: Decision table

    /// The published detector → cause/step table.
    ///
    /// - note: Two rows in the spec carry an extra condition — "refutation
    ///   captures it" for `hangingPiece(.moved)` and "refutation is check or
    ///   capture" for `allowedTactic(.shallow)`. Those conditions are already
    ///   required for the detector to emit the subtype at all in the common case;
    ///   when a finding arrives without the corroborating flag (it was confirmed
    ///   by the evaluation drop instead) it maps the same way, because the cause
    ///   is identical from the player's side of the board.
    public static func baseMapping(for finding: Finding) -> (cause: CauseTag, step: StepTag)? {
        switch (finding.detector, finding.subtype) {
        case (.ignoredThreat, .newThreat):
            (.missedNewThreat, .s1WhatChanged)
        case (.ignoredThreat, .standingThreat):
            (.ignoredStandingThreat, .s2ChecksCapturesThreats)
        case (.hangingPiece, .moved):
            (.hungMovedPiece, .s5BlunderCheck)
        case (.hangingPiece, .left):
            (.hungLeftPiece, .s5BlunderCheck)
        case (.allowedTactic, .shallow):
            (.allowedShallowTactic, .s5BlunderCheck)
        case (.allowedTactic, .deep):
            (.allowedDeepTactic, .s4Calculate)
        case (.missedTactic, .playedForcing):
            (.miscalculatedTactic, .s4Calculate)
        case (.missedTactic, .playedQuiet):
            (.missedForcingIdea, .s2ChecksCapturesThreats)
        case (.missedQuietMove, _):
            (.forcingBias, .s3Candidates)
        case (.wrongTrade, .losesMaterial):
            (.miscountedExchange, .s4Calculate)
        case (.wrongTrade, .badSimplification):
            (.planlessTrade, .s3Candidates)
        case (.kingWeakeningPawnMove, .tacticalPunish):
            (.kingExposure, .s2ChecksCapturesThreats)
        case (.kingWeakeningPawnMove, .positional):
            (.kingExposure, .s3Candidates)
        case (.endgameTechnique, _):
            (.endgameTechnique, .kKnowledge)
        case (.openingPrinciple, _):
            (.openingPrinciple, .kKnowledge)
        default:
            nil
        }
    }

    /// What to say when no detector explains the move.
    static func fallbackMapping(_ context: MoveContext) -> (cause: CauseTag, step: StepTag) {
        guard context.judgment >= .inaccuracy else {
            // Not actually a mistake. Step S3 is the neutral resting place: the
            // move came from candidate selection like every other move.
            return (.generic, .s3Candidates)
        }
        return context.bestMoveIsQuiet
            ? (.positionalDrift, .s3Candidates)
            : (.missedForcingIdea, .s2ChecksCapturesThreats)
    }
}
