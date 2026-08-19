//
//  CoachingQuestions.swift
//  AnalysisKit
//

import ChessKit

/// The Socratic lead-in for a moment: one question per cause tag.
///
/// Each is written to be answerable from the position, in words only — no
/// notation and no square names that could be read as a move — because a
/// question that names its own answer is not a question, and because the student
/// is meant to look at the board rather than at the sentence.
public enum CoachingQuestions {

    /// Used when a cause tag has no question of its own: a detector shipping
    /// ahead of its copy should not leave the student with nothing.
    ///
    /// It is deliberately not asked of a reinforcement — see ``question(for:)``.
    public static let defaultQuestion =
        "What did you want this move to achieve, and what did it allow in return?"

    public static let bank: [CauseTag: String] = [
        .hungMovedPiece:
            "Before you let go of that piece, what would be attacking it on the square you picked?",
        .missedNewThreat:
            "Their last move changed something — what does it attack now that it did not attack a moment ago?",
        .ignoredStandingThreat:
            "You already knew about their threat; did the move you chose actually deal with it, or only ignore it politely?",
        .allowedShallowTactic:
            "If you play this, what is their most forcing reply — every check and every capture, not just the natural-looking move?",
        .allowedDeepTactic:
            "After the obvious recapture, does your position still hold, or does a second forcing move arrive right behind it?",
        .miscalculatedTactic:
            "At the end of the line you calculated, whose pieces are still hanging?",
        .missedForcingIdea:
            "Before settling on a quiet move, which checks and captures did you look at?",
        .forcingBias:
            "You went for the forcing move; what would you have played if none of the checks and captures worked?",
        .miscountedExchange:
            "How many defenders does that square really have, and in what order do they arrive?",
        .planlessTrade:
            "What does this trade improve for you — and what does it improve for them?",
        .kingExposure:
            "After this pawn move, which squares around your own king is nothing covering any more?",
        .endgameTechnique:
            "What is the winning method in this endgame, and what is the very first step of it?",
        .openingPrinciple:
            "Which of your pieces is still sitting on its starting square, and does this move help it get out?",
        .positionalDrift:
            "Which of your pieces is doing the least work right now, and how would you give it something to do?"
    ]

    /// `hungLeftPiece` has two questions rather than one.
    ///
    /// The subtype means only "something other than the piece you moved is
    /// hanging", which is a much weaker claim than "you moved its defender away"
    /// — in the detector's own fixture the knight that moved never defended the
    /// rook that hangs. Asking which piece the moved one was defending sends the
    /// student looking for a relationship that does not exist, and a question
    /// with no answer teaches them to distrust the coaching.
    public static let abandonedDefenderQuestion =
        "Which of your pieces was being defended by the piece you just moved away?"
    public static let alreadyLooseQuestion =
        "One of your pieces was already undefended before this move — which one, and what were you going to do about it?"

    /// The question for a cause tag, with no position to check against.
    public static func question(forCauseTag causeTag: CauseTag) -> String {
        if causeTag == .hungLeftPiece { return alreadyLooseQuestion }
        return bank[causeTag] ?? defaultQuestion
    }

    /// The question for a moment.
    ///
    /// A reinforcement gets no question at all. Every question in the bank asks
    /// what went wrong, and the fallback asks what the move "allowed in return" —
    /// put in front of the one moment in a review that exists to say *well
    /// played*, it reads as an accusation.
    public static func question(for moment: Moment, context: MoveContext? = nil) -> String? {
        guard moment.kind == .mistake else { return nil }
        guard moment.causeTag == .hungLeftPiece else { return question(forCauseTag: moment.causeTag) }

        guard let context, let hanging = moment.evidence?.squares.first else { return alreadyLooseQuestion }
        let defendedBefore = Occupancy(context.positionBefore)
            .attackers(of: hanging, by: context.mover)
            .contains(context.playedMove.start)
        return defendedBefore ? abandonedDefenderQuestion : alreadyLooseQuestion
    }
}
