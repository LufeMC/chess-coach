//
//  GameSummary.swift
//  AnalysisKit
//

import ChessKit

/// How a game finished, from the reviewing player's side.
public enum GameOutcome: String, Sendable, Codable, CaseIterable {
    case win
    case loss
    case draw
}

/// The headline and body shown above a game's moments.
public struct GameSummary: Sendable, Equatable, Codable {
    public let headline: String
    public let body: String

    public init(headline: String, body: String) {
        self.headline = headline
        self.body = body
    }

    /// Layout limits, the same ones the review header was built against.
    public static let headlineBudget = 120
    public static let bodyBudget = 600
}

/// Writes the game-level note.
///
/// Deliberately short and deliberately flat. The summary knows the result, the
/// accuracy, the length of the game and which causes came up — and nothing else.
/// Anything warmer than that would be invented: a line about how well someone
/// fought in a game they lost is a guess, and a player who has just lost can tell
/// the difference between a fact and a consolation. So a loss is reported as a
/// loss, a win is not congratulated, and the only forward-looking sentence names
/// a pattern that actually repeated.
public enum GameSummarizer {

    /// The note for one game.
    ///
    /// - parameter moments: The moments that were selected for review, in the
    ///   order they will be shown.
    public static func summary(
        outcome: GameOutcome,
        accuracy: Double?,
        moveCount: Int,
        moments: [Moment]
    ) -> GameSummary {
        GameSummary(
            headline: MomentExplainer.truncate(
                headline(outcome: outcome, moments: moments),
                to: GameSummary.headlineBudget
            ),
            body: MomentExplainer.truncate(
                body(outcome: outcome, accuracy: accuracy, moveCount: moveCount, moments: moments),
                to: GameSummary.bodyBudget
            )
        )
    }

    static func headline(outcome: GameOutcome, moments: [Moment]) -> String {
        let mistakes = moments.filter { $0.kind == .mistake }

        guard let worst = mistakes.max(by: { $0.total < $1.total }) else {
            switch outcome {
            case .win: return "A win with nothing to pick apart"
            case .loss: return "A loss with no single moment behind it"
            case .draw: return "A draw with no single moment behind it"
            }
        }

        let phase = phaseName(worst.phase)
        switch outcome {
        case .win: return "A win, and the \(phase) is where it was closest"
        case .loss: return "The \(phase) is where this one was decided"
        case .draw: return "A draw, decided in the \(phase)"
        }
    }

    static func body(outcome: GameOutcome, accuracy: Double?, moveCount: Int, moments: [Moment]) -> String {
        var sentences: [String] = []

        let moves = "\(moveCount) move\(moveCount == 1 ? "" : "s")"
        if let accuracy {
            sentences.append("You played \(String(format: "%.0f", accuracy))% accuracy over \(moves).")
        } else {
            sentences.append("The game ran \(moves).")
        }

        let mistakes = moments.filter { $0.kind == .mistake }
        if let repeated = repeatedCause(mistakes) {
            sentences.append(
                "\(causeName(repeated.tag)) came up \(countPhrase(repeated.count)) — that is the pattern, "
                    + "not the individual moves."
            )
        } else if let first = mistakes.first {
            sentences.append("The costliest decision was \(first.playedSAN) on move \(moveNumber(first.ply)): "
                + "\(causeName(first.causeTag)).")
        }

        if moments.contains(where: { $0.kind == .reinforcement }) {
            sentences.append("One position below is there because you got it right.")
        }

        if mistakes.isEmpty, outcome != .win {
            sentences.append("Nothing in this game crossed the threshold for review.")
        } else {
            sentences.append("Work through the positions below on a board before you read the lines.")
        }

        return sentences.joined(separator: " ")
    }

    /// The cause that appeared more than once, if any. Two instances of one habit
    /// is the only claim about a whole game this data can actually support.
    static func repeatedCause(_ moments: [Moment]) -> (tag: CauseTag, count: Int)? {
        var counts: [CauseTag: Int] = [:]
        for moment in moments { counts[moment.causeTag, default: 0] += 1 }
        return counts
            .filter { $0.value >= 2 }
            .max { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }
            .map { ($0.key, $0.value) }
    }

    static func countPhrase(_ count: Int) -> String {
        switch count {
        case 2: "twice"
        case 3: "three times"
        default: "\(count) times"
        }
    }

    static func moveNumber(_ ply: Int) -> Int { (ply + 1) / 2 }

    static func phaseName(_ phase: Phase) -> String {
        switch phase {
        case .opening: "opening"
        case .middlegame: "middlegame"
        case .endgame: "endgame"
        }
    }

    /// The cause tags in the words a student reads, not the words the code uses.
    static func causeName(_ tag: CauseTag) -> String {
        switch tag {
        case .missedNewThreat: "A threat you did not see arrive"
        case .ignoredStandingThreat: "A threat left standing"
        case .hungMovedPiece: "Moving a piece onto a square it could be taken on"
        case .hungLeftPiece: "Leaving a piece loose"
        case .allowedShallowTactic: "Allowing a one-move tactic"
        case .allowedDeepTactic: "Allowing a longer combination"
        case .miscalculatedTactic: "Calculating a tactic to the wrong end"
        case .missedForcingIdea: "Missing a forcing idea"
        case .forcingBias: "Reaching for the forcing move"
        case .miscountedExchange: "Miscounting an exchange"
        case .planlessTrade: "Trading without a reason"
        case .kingExposure: "Loosening your own king"
        case .endgameTechnique: "Endgame technique"
        case .openingPrinciple: "An opening principle"
        case .positionalDrift: "The position drifting"
        case .generic: "A move that cost something"
        }
    }
}
