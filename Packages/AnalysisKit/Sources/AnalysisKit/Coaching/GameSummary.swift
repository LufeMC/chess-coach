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

        guard let worst = costliest(mistakes) else {
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
        } else if let worst = costliest(mistakes) {
            sentences.append("The costliest decision was \(worst.playedSAN) on move \(moveNumber(worst.ply)): "
                + "\(causeName(worst.causeTag)).")
        }

        if moments.contains(where: { $0.kind == .reinforcement }) {
            sentences.append("One position below is there because you got it right.")
        }

        if mistakes.isEmpty, outcome != .win {
            sentences.append("Nothing in this game crossed the threshold for review.")
        } else {
            // Not "on a board" — the reader is looking at one — and not "the
            // lines", which promised engine variations the review does not
            // print. It names the two things that are actually on the screen,
            // in the order that makes the second one worth reading.
            sentences.append(
                "Tap each position below and find the better move yourself before you open the coach's note."
            )
        }

        return sentences.joined(separator: " ")
    }

    /// The move that actually cost the most.
    ///
    /// Both of the verdict's claims — which phase the game was decided in, and
    /// which decision was the costliest — are claims about size, so they are
    /// made on `deltaEP` and on nothing else. `Moment.total` is the *selection*
    /// score, severity multiplied by learnability and by how relevant the lesson
    /// is to this player's current rung, and it exists to choose which three
    /// moments are worth showing. Reading it as "the worst move" lets a
    /// teachable inaccuracy on the weekly focus habit outrank the blunder that
    /// lost the game, and the verdict then names a phase the graph directly
    /// above it visibly contradicts. Display order is no better: it named
    /// whichever mistake happened first.
    ///
    /// Ties break to the earlier move, because the rest of the game followed
    /// from it.
    static func costliest(_ mistakes: [Moment]) -> Moment? {
        mistakes.max { left, right in
            left.deltaEP == right.deltaEP ? left.ply > right.ply : left.deltaEP < right.deltaEP
        }
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
    ///
    /// Word for word the names the coach card and the Profile leak table use.
    /// This file cannot reach that table — AnalysisKit depends on nothing but
    /// the board and the engine value types — so the alignment is kept by hand,
    /// and it is worth keeping: a diagnosis worded three ways on one scroll is
    /// three diagnoses to a reader trying to follow the thread from the verdict
    /// to the card to the leak costing them the most rating.
    static func causeName(_ tag: CauseTag) -> String {
        switch tag {
        case .missedNewThreat: "Missed opponent threats"
        case .ignoredStandingThreat: "Ignored standing threats"
        case .hungMovedPiece: "Hanging pieces"
        case .hungLeftPiece: "Pieces left hanging"
        case .allowedShallowTactic: "Allowed simple tactics"
        case .allowedDeepTactic: "Allowed deep tactics"
        case .miscalculatedTactic: "Miscalculated tactics"
        case .missedForcingIdea: "Missed forcing ideas"
        case .forcingBias: "Premature forcing moves"
        case .miscountedExchange: "Miscounted exchanges"
        case .planlessTrade: "Planless trades"
        case .kingExposure: "King left exposed"
        case .endgameTechnique: "Endgame technique"
        case .openingPrinciple: "Opening principles"
        case .positionalDrift: "Positional drift"
        case .generic: "A move that cost something"
        }
    }
}
