//
//  PuzzleMoveEvaluator.swift
//  ChessCoach
//

import ChessKit
import EngineKit
import Foundation

/// How good a position is for the side that just moved into it.
///
/// Centipawns, clamped, with mate folded in at the extremes so one comparison
/// covers both. Mate is worth more than any material score, which is the only
/// property the bands below actually need from it.
struct PuzzleEvaluation: Equatable, Sendable {

    /// Centipawns from the solver's point of view. Positive is better for them.
    var centipawns: Int

    /// The value a forced mate is folded to, above any real material score.
    static let mateMagnitude = 10_000

    init(centipawns: Int) {
        self.centipawns = centipawns
    }

    init(score: UCIScore) {
        switch score {
        case .centipawns(let value):
            centipawns = value
        case .mate(let moves):
            // Sign, not distance: a mate in 1 and a mate in 6 are both "winning"
            // and nothing in this file needs to tell them apart.
            centipawns = moves >= 0 ? Self.mateMagnitude : -Self.mateMagnitude
        }
    }

    /// Flips the perspective. An engine reports from the side to move, and after
    /// the solver's move that is the *opponent*.
    var negated: PuzzleEvaluation { PuzzleEvaluation(centipawns: -centipawns) }

    /// The evaluation of a move that *ends* the game, or `nil` if it does not.
    ///
    /// Asked before the engine, and not merely as an optimisation. A position
    /// that is already checkmate has no legal moves, so Stockfish answers
    /// `bestmove (none)` with no score at all — which arrives here as "no
    /// evaluation" and silences the explanation on precisely the puzzles where
    /// the answer is most emphatic. Mating puzzles are the single most common
    /// kind, so the engine path was mute exactly where it mattered most.
    static func terminal(playing uci: String, in position: Position) -> PuzzleEvaluation? {
        var board = Board(position: position)
        guard PuzzleSolveMachine.move(uci: uci, on: &board) != nil else { return nil }
        switch board.state {
        case .checkmate:
            // Only ever called for the side that just moved, so the mate is
            // always theirs.
            return PuzzleEvaluation(centipawns: mateMagnitude)
        case .draw:
            return PuzzleEvaluation(centipawns: 0)
        default:
            return nil
        }
    }

    var band: Band { Band(centipawns: centipawns) }

    /// The five states worth distinguishing in a sentence.
    ///
    /// Deliberately coarse. The engine's number is precise to a centipawn and
    /// that precision is fake to a human reader: nobody plays differently at
    /// +0.7 than at +0.9, and a banner that quoted either would be inviting the
    /// user to trust a decimal the position cannot support.
    enum Band: Int, Comparable, Sendable {
        case losing
        case worse
        case level
        case better
        case winning

        init(centipawns: Int) {
            switch centipawns {
            case ..<(-450): self = .losing
            case ..<(-120): self = .worse
            case ..<120: self = .level
            case ..<450: self = .better
            default: self = .winning
            }
        }

        /// How the *played* move's outcome is described, as the second half of
        /// "But yours…".
        /// Carries its own subject. The banner joins these with `"But "`, and a
        /// clause without a subject produced "But only keeps things level." —
        /// which reads as a sentence somebody forgot to finish.
        var playedPhrase: String {
            switch self {
            case .losing: "yours leaves you losing"
            case .worse: "yours leaves you worse off"
            case .level: "yours only keeps things level"
            case .better: "yours is better too, just by less"
            case .winning: "yours also wins"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

/// Evaluates a candidate move in a puzzle position.
///
/// A protocol so the session model can be tested without Stockfish. The live
/// implementation is a lease on the shared engine; the tests hand over a script.
protocol PuzzleMoveEvaluator: Sendable {
    /// The evaluation after `uci` is played in `fen`, from the point of view of
    /// the side that played it. `nil` when the engine could not be reached, was
    /// busy, or the move is not legal.
    func evaluate(fen: String, playing uci: String) async -> PuzzleEvaluation?

    /// The engine's principal continuation after `uci`, opponent's reply first.
    ///
    /// A different question from ``evaluate(fen:playing:)`` — that one sorts a
    /// move into a band, this one is the *line*, which is the only thing that
    /// can explain a move whose point arrives two moves later. Empty when the
    /// engine could not be reached.
    func continuation(fen: String, playing uci: String) async -> [String]
}

extension PuzzleMoveEvaluator {
    /// No line, which the caller reads as "nothing to add" and leaves the
    /// banner alone. Default so an evaluator that only scores moves — every
    /// existing test double — keeps compiling.
    func continuation(fen: String, playing uci: String) async -> [String] { [] }
}

/// The real one: a short, node-capped search on the shared engine.
///
/// ## Why this is allowed to fail silently
///
/// The engine is a process-wide singleton with a lease, and a game or an
/// analysis pass outranks a banner. If the lease is busy or the search errors,
/// the caller keeps the sentence it already had. The explanation is an upgrade
/// to the feedback, never a precondition for it — a puzzle session that stalled
/// waiting for Stockfish to describe a move the user has already moved on from
/// would be a strictly worse app.
struct EnginePuzzleEvaluator: PuzzleMoveEvaluator {

    let service: EngineService

    /// Small on purpose. This is not analysis — it is one number, twice, while
    /// a banner is already on screen. The guided-mode probe uses 60k for a
    /// decision that changes the game; this only has to sort a move into one of
    /// five bands.
    static let nodes = 40_000

    /// Larger, because a line is held to a harder standard than a band.
    ///
    /// The banner quotes this variation back as a claim about the position —
    /// *if they take back, the rook to d1 with check wins the queen* — and a
    /// shallow search that picks the wrong reply puts a wrong sentence on
    /// screen. It is also spent at most once per puzzle, and only on the ones
    /// the board could not explain by itself, so the budget buys accuracy where
    /// nothing cheaper is available.
    static let continuationNodes = 150_000

    func evaluate(fen: String, playing uci: String) async -> PuzzleEvaluation? {
        let device = await service.deviceProfile
        let lease = await service.acquire(.probe, configuration: .probe(device: device))
        defer { Task { await service.release(lease) } }

        guard
            let result = try? await service.search(
                .fen(fen, moves: [uci]),
                limit: .nodes(Self.nodes),
                lease: lease
            ),
            let principal = result.principal
        else { return nil }

        // The search ran *after* the move, so the score belongs to the opponent.
        return PuzzleEvaluation(score: principal.score).negated
    }

    func continuation(fen: String, playing uci: String) async -> [String] {
        let device = await service.deviceProfile
        let lease = await service.acquire(.probe, configuration: .probe(device: device))
        defer { Task { await service.release(lease) } }

        guard
            let result = try? await service.search(
                .fen(fen, moves: [uci]),
                limit: .nodes(Self.continuationNodes),
                lease: lease
            )
        else { return [] }

        // The search started after `uci`, so the variation opens with the
        // opponent's reply — which is exactly the order the clause wants.
        return result.principal?.pv ?? []
    }
}

/// Builds the "But yours…" clause from two evaluations.
///
/// Pure, and separate from both the engine and the view, because the judgement
/// it encodes — when is a move different enough to be worth a sentence — is the
/// part most likely to need tuning, and the part impossible to tune against a
/// live engine.
enum PuzzleMoveComparison {

    /// How much worse the played move has to be before it is worth saying
    /// anything. A puzzle can have a second move that is very nearly as good,
    /// and telling a user their near-equal move "only keeps things level" when
    /// the answer was barely better is the kind of false coaching that costs
    /// trust in every other line.
    static let significantGap = 150

    /// Below this the two moves are the same move as far as the position is
    /// concerned.
    ///
    /// Worth a sentence of its own. A puzzle mined from the user's own game has
    /// one stored answer — whatever the analysis pass picked — and the second
    /// and third choices are often within a few centipawns of it. The banner
    /// says `Missed`, and until now the engine's considered opinion that the
    /// user's move was just as good was expressed by saying nothing at all.
    /// Silence there reads as agreement with the `Missed`.
    static let equivalentGap = 50

    /// - Parameters:
    ///   - answer: the evaluation after the puzzle's answer.
    ///   - played: the evaluation after the move the user chose.
    /// - Returns: a clause such as `"only keeps things level"`, or `nil` when
    ///   the two moves are close enough that there is nothing honest to add.
    static func clause(answer: PuzzleEvaluation?, played: PuzzleEvaluation?) -> String? {
        guard let answer, let played else { return nil }
        let gap = answer.centipawns - played.centipawns

        // Not worse in any way the position can tell. Say so rather than let
        // "Missed" stand as the last word on a move that was fine.
        if gap <= equivalentGap, played.band >= answer.band {
            return "yours was just as good"
        }

        guard gap >= significantGap else { return nil }
        // A band that is not actually worse says nothing useful, however big the
        // raw gap: "also wins" is not a criticism.
        guard played.band < answer.band else { return nil }
        return played.band.playedPhrase
    }
}
