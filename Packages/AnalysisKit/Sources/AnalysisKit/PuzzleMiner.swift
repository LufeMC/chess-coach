//
//  PuzzleMiner.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Finds puzzle-worthy positions in a played game.
///
/// The recipe follows the one lichess-puzzler describes: a blunder large enough
/// to swing the game, a solution that is genuinely forced, and a line trimmed so
/// it ends on the winner's move with nothing pointless attached.
/// Written from the published description rather than the AGPL implementation.
///
/// The three rules, and why each is needed:
///
/// * **Trigger.** A big evaluation *and* a big jump. Either alone is wrong: a
///   position that was already winning gains nothing from another good move, and
///   a large jump inside a drawn position produces puzzles with no point.
/// * **Uniqueness.** At every position where the solver moves, the right move has
///   to beat the runner-up decisively. A puzzle with two good answers marks
///   correct solvers wrong, which is worse than having no puzzle.
/// * **Trimming.** Trailing forced moves teach nothing, and a solution has to end
///   on the solver's move — so the length is odd, and a one-move "puzzle" is not
///   a puzzle.
public enum PuzzleMiner {

    /// The winner's evaluation must reach this, in centipawns.
    public static let triggerCentipawns = 200
    /// Jump on the -1...+1 winning-chances scale that marks the blunder.
    public static let triggerWinChanceJump = 0.6
    /// How far the best move must beat the second best, same scale.
    public static let uniquenessMargin = 0.7

    /// One position along the candidate solution, searched with MultiPV ≥ 2.
    public struct Node: Sendable, Equatable {
        public let fen: String
        /// MultiPV rank 1, from the side to move's perspective.
        public let best: UCIInfo
        /// MultiPV rank 2, if the search produced one.
        public let second: UCIInfo?

        public init(fen: String, best: UCIInfo, second: UCIInfo? = nil) {
            self.fen = fen
            self.best = best
            self.second = second
        }

        var position: Position? { Position(fen: fen) }
    }

    /// A mined puzzle.
    public struct Candidate: Sendable, Equatable {
        /// The position the solver is given — the winner is to move.
        public let fen: String
        /// Alternating winner/loser moves in UCI. Odd length, at least three.
        public let solution: [String]
        public let winner: Piece.Color
        /// Uniqueness could not be fully verified from the supplied lines (a node
        /// was missing its second-best move); the caller should re-search deeper
        /// before publishing this puzzle.
        public let needsDeeperValidation: Bool

        public init(fen: String, solution: [String], winner: Piece.Color, needsDeeperValidation: Bool) {
            self.fen = fen
            self.solution = solution
            self.winner = winner
            self.needsDeeperValidation = needsDeeperValidation
        }
    }

    /// - parameter scoreBeforeError: Evaluation of the position *before* the
    ///   losing move, as the engine reported it — i.e. from the perspective of
    ///   the player who is about to blunder.
    /// - parameter line: Consecutive searched positions starting with the puzzle
    ///   position itself; the winner is to move at `line[0]`, and the sides
    ///   alternate from there.
    /// - returns: A candidate puzzle, or `nil` when any rule rejects it.
    public static func mine(scoreBeforeError: UCIScore, line: [Node]) -> Candidate? {
        guard let start = line.first, let startPosition = start.position else { return nil }
        let winner = startPosition.sideToMove

        // The pre-error score belongs to the loser; the winner's view is its
        // negation.
        let winnerBefore = scoreBeforeError.negated
        guard passesTrigger(before: winnerBefore, after: start.best.score) else { return nil }

        var solution: [String] = []
        var needsDeeperValidation = false

        for (index, node) in line.enumerated() {
            guard let position = node.position else { break }
            guard let move = node.best.pv.first else { break }
            let isWinnerToMove = position.sideToMove == winner
            // Defensive: a mis-assembled line breaks the alternation invariant.
            guard isWinnerToMove == (index % 2 == 0) else { break }

            if isWinnerToMove {
                switch uniqueness(of: node, position: position) {
                case .unique: break
                case .ambiguous: return nil
                case .unverified: needsDeeperValidation = true
                }
            }

            solution.append(move)
        }

        solution = stripTrailingOnlyMoves(solution, line: line)
        if solution.count % 2 == 0 { solution.removeLast() }
        guard solution.count >= 3 else { return nil }

        // A line that stopped before the evaluation settled is worth a second
        // look before it becomes a published puzzle.
        if solution.count == line.count, !isDecisive(line.last?.best.score) {
            needsDeeperValidation = true
        }

        return Candidate(
            fen: start.fen,
            solution: solution,
            winner: winner,
            needsDeeperValidation: needsDeeperValidation
        )
    }

    // MARK: Rules

    static func passesTrigger(before: UCIScore, after: UCIScore) -> Bool {
        // Mate appearing out of nowhere is always worth a puzzle, whatever the
        // centipawn arithmetic says.
        if case .mate(let n) = after, n > 0 {
            if case .mate(let previous) = before, previous > 0 { return false }
            return true
        }

        guard after.centipawnValue() >= triggerCentipawns else { return false }
        let jump = EvalMath.winChance(score: after) - EvalMath.winChance(score: before)
        return jump > triggerWinChanceJump
    }

    enum Uniqueness {
        case unique
        case ambiguous
        case unverified
    }

    static func uniqueness(of node: Node, position: Position) -> Uniqueness {
        guard let second = node.second else {
            // Only one legal move: nothing to be ambiguous about.
            return PositionUtilities.legalMovePairs(in: position).count <= 1 ? .unique : .unverified
        }
        let margin = EvalMath.winChance(score: node.best.score) - EvalMath.winChance(score: second.score)
        return margin >= uniquenessMargin ? .unique : .ambiguous
    }

    /// Drops moves off the end that the player had no choice about.
    static func stripTrailingOnlyMoves(_ solution: [String], line: [Node]) -> [String] {
        var result = solution
        while let last = result.indices.last, last < line.count {
            guard let position = line[last].position else { break }
            guard PositionUtilities.legalMovePairs(in: position).count <= 1 else { break }
            result.removeLast()
        }
        return result
    }

    static func isDecisive(_ score: UCIScore?) -> Bool {
        guard let score else { return false }
        if case .mate = score { return true }
        return abs(score.centipawnValue()) >= 600
    }
}
