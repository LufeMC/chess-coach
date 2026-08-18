//
//  PuzzleSolveMachine.swift
//  ChessCoach
//

import ChessKit
import Foundation
import TrainingCore

/// One puzzle attempt, as a state machine.
///
/// ## The Lichess move format
///
/// A Lichess puzzle stores a FEN plus a UCI move list in which **move 1 belongs
/// to the opponent**. The stored position is not the one the solver sees: the
/// opponent's move is played first (it is what creates the tactic), and only
/// then is the user asked to move. So the line alternates
/// `opponent, user, opponent, user, …` and always ends on a user move.
///
/// Getting this wrong is the classic puzzle-engine bug — the user is shown a
/// position one ply early and every answer looks wrong — so the setup move is a
/// separate, explicit step (``start()``) rather than something folded into
/// initialisation.
///
/// ## Why a value type
///
/// No UI, no storage, no clock: the whole solve rule is a pure function of the
/// moves played, which is what makes it testable without a board view or an
/// engine. The owning service holds one of these and reads ``phase`` after each
/// event.
struct PuzzleSolveMachine: Sendable {

    // MARK: Configuration

    /// What a wrong move costs.
    ///
    /// The daily session's default is ``endOnFirstMistake``: a puzzle is a test
    /// of whether the user *saw* it, and letting them guess again turns it into
    /// a multiple-choice question. The exception is a relearn item — the
    /// same-day retry `SessionBuilder` appends after a failure — where a second
    /// try is the entire point, and the resulting attempt reports
    /// `retried: true` so `AutoGrader` grades it `.hard` rather than `.good`.
    enum RetryPolicy: Sendable, Hashable {
        case endOnFirstMistake
        case allowRetries(Int)

        var budget: Int {
            switch self {
            case .endOnFirstMistake: return 0
            case .allowRetries(let count): return max(0, count)
            }
        }
    }

    enum Failure: Sendable, Hashable {
        case wrongMove(played: String, expected: String)
    }

    enum Phase: Sendable, Hashable {
        /// Built, but the opponent's setup move has not been played yet.
        case ready
        case awaitingUser
        case solved
        case failed(Failure)

        var isFinished: Bool {
            switch self {
            case .solved, .failed: return true
            case .ready, .awaitingUser: return false
            }
        }
    }

    /// What happened to a move the user offered.
    enum MoveResult: Sendable, Hashable {
        /// Correct. The opponent's reply, if the line continues, has already
        /// been applied to the board.
        case advanced(opponentReply: String?)
        /// Correct and the line is complete.
        case solved
        /// Wrong, but a retry remains. The board is unchanged.
        case retry(expected: String, retriesRemaining: Int)
        /// Wrong, and the attempt is over.
        case failed(expected: String)
        /// Not a legal move in this position.
        ///
        /// Distinct from `failed` on purpose: an illegal move is a slipped
        /// finger, not a wrong answer, and scoring it would punish the user for
        /// the touch target rather than for the chess.
        case illegal
    }

    // MARK: State

    private(set) var board: Board
    /// The full UCI line, setup move first when ``opponentMovesFirst``.
    let line: [String]
    /// Whether `line[0]` belongs to the opponent.
    ///
    /// True for corpus puzzles, which is the Lichess convention. False for a
    /// position mined from the user's own game: that FEN is already the moment
    /// they went wrong, so there is nothing to set up and the first move in the
    /// line is theirs to find.
    let opponentMovesFirst: Bool
    let retryPolicy: RetryPolicy

    private(set) var phase: Phase = .ready
    /// Index into ``line`` of the next move to be played.
    private(set) var cursor: Int = 0
    private(set) var wrongAttempts: Int = 0
    private(set) var usedHint: Bool = false

    /// The FEN the puzzle was built from, *before* the setup move.
    let startFEN: String

    // MARK: Construction

    /// - Parameters:
    ///   - fen: Position before the opponent's setup move.
    ///   - line: UCI moves, setup move first when `opponentMovesFirst`.
    ///   - opponentMovesFirst: See ``opponentMovesFirst``.
    init?(
        fen: String,
        line: [String],
        opponentMovesFirst: Bool = true,
        retryPolicy: RetryPolicy = .endOnFirstMistake
    ) {
        guard line.count >= (opponentMovesFirst ? 2 : 1), let position = Position(fen: fen) else { return nil }
        self.startFEN = fen
        self.board = Board(position: position)
        self.line = line
        self.opponentMovesFirst = opponentMovesFirst
        self.retryPolicy = retryPolicy
    }

    // MARK: Events

    /// Plays the opponent's setup move and hands the position to the user.
    ///
    /// - Returns: The setup move in UCI, so the caller can animate it; `nil`
    ///   when there is no setup move to play, or when the stored move is not
    ///   legal in the stored position. The two are told apart by ``phase``:
    ///   a corrupt line leaves it at ``Phase/ready``.
    @discardableResult
    mutating func start() -> String? {
        guard case .ready = phase else { return nil }
        guard opponentMovesFirst else {
            cursor = 0
            phase = .awaitingUser
            return nil
        }
        let setup = line[0]
        guard Self.apply(uci: setup, to: &board) else { return nil }
        cursor = 1
        phase = .awaitingUser
        return setup
    }

    /// The move the user is expected to find right now.
    ///
    /// Exposed for the hint UI and for tests; never shown to the user without
    /// going through ``revealHint()``, which records that it was shown.
    var expectedMove: String? {
        guard case .awaitingUser = phase, line.indices.contains(cursor) else { return nil }
        return line[cursor]
    }

    /// Reveals the answer.
    ///
    /// The machine stays playable afterwards so the user can walk the rest of
    /// the line and actually learn it — but the attempt is already lost.
    /// `AutoGrader` treats any hint as `.again` regardless of what happens next,
    /// which is the honest reading: once the answer is on screen, nothing after
    /// that point is evidence about recall.
    @discardableResult
    mutating func revealHint() -> String? {
        guard let expected = expectedMove else { return nil }
        usedHint = true
        return expected
    }

    /// Offers a user move.
    mutating func play(uci: String) -> MoveResult {
        guard case .awaitingUser = phase, line.indices.contains(cursor) else { return .illegal }
        let expected = line[cursor]

        guard uci != expected else {
            return advanceThroughExpectedMove()
        }

        // Legality first: a move that is not legal at all is a mis-tap, and
        // scoring it would make a fumbled drag cost the user a card.
        var probe = board
        guard Self.apply(uci: uci, to: &probe) else { return .illegal }

        // A different mate at the end of the line is still a solve. Lichess
        // accepts this and so should we: the puzzle asked for checkmate and the
        // user delivered checkmate, and telling them they are wrong because
        // they picked the other mate in one is indefensible.
        if cursor == line.count - 1, case .checkmate = probe.state {
            board = probe
            cursor = line.count
            phase = .solved
            return .solved
        }

        wrongAttempts += 1
        let remaining = retryPolicy.budget - (wrongAttempts - 1)
        if remaining > 0 {
            return .retry(expected: expected, retriesRemaining: remaining)
        }

        phase = .failed(.wrongMove(played: uci, expected: expected))
        return .failed(expected: expected)
    }

    private mutating func advanceThroughExpectedMove() -> MoveResult {
        guard Self.apply(uci: line[cursor], to: &board) else {
            // The stored line does not replay. Treat it as a corrupt row rather
            // than a user error: refusing the move leaves the attempt unscored.
            return .illegal
        }
        cursor += 1

        guard cursor < line.count else {
            phase = .solved
            return .solved
        }

        // The opponent's reply is part of the puzzle, not a decision, so it is
        // played immediately and the user is asked for the next move.
        let reply = line[cursor]
        guard Self.apply(uci: reply, to: &board) else { return .illegal }
        cursor += 1

        guard cursor < line.count else {
            // A line that ends on the opponent's move is malformed, but the
            // user has played everything asked of them, so it counts.
            phase = .solved
            return .solved
        }

        return .advanced(opponentReply: reply)
    }

    // MARK: Scoring

    /// The attempt, in the shape `AutoGrader` and `CardPolicy` want.
    func attempt(latencyMs: Double, bandMedianLatencyMs: Double) -> PuzzleAttempt {
        PuzzleAttempt(
            correct: phase == .solved,
            usedHint: usedHint,
            retried: wrongAttempts > 0,
            latencyMs: latencyMs,
            bandMedianLatencyMs: bandMedianLatencyMs
        )
    }

    /// Current position as a FEN, for persisting a moment position or for a
    /// board view that renders from FEN.
    var currentFEN: String {
        FENParser.convert(position: board.position)
    }

    // MARK: Move application

    /// Applies a UCI move to a board, including promotion.
    ///
    /// Returns `nil` rather than trapping when the move is not legal: every
    /// caller here has a meaningful answer for "that did not work". The move is
    /// returned rather than discarded because it carries the disambiguation and
    /// check state that SAN needs, and recomputing those is exactly the work
    /// `Board` has just done.
    @discardableResult
    static func move(uci: String, on board: inout Board) -> Move? {
        guard uci.count == 4 || uci.count == 5 else { return nil }
        let characters = Array(uci)
        let start = Square(String(characters[0...1]))
        let end = Square(String(characters[2...3]))

        // `Board.canMove(pieceAt:to:)` answers "is this a legal move for that
        // piece", which is not the same question as "is this a legal move now":
        // it does not check whose turn it is. Without this guard, dragging a
        // white piece while Black is to move is accepted as a *wrong answer* and
        // costs the user the puzzle, rather than being ignored as the mis-tap it
        // is.
        guard let piece = board.position.piece(at: start), piece.color == board.position.sideToMove else {
            return nil
        }

        guard board.canMove(pieceAt: start, to: end), let move = board.move(pieceAt: start, to: end) else {
            return nil
        }

        if case .promotion = board.state {
            // UCI spells the promotion piece in lowercase; ChessKit's `Kind`
            // raw values are uppercase. A missing suffix means queen, which is
            // what every engine and every puzzle line assumes.
            let suffix = characters.count == 5 ? String(characters[4]).uppercased() : "Q"
            let kind = Piece.Kind(rawValue: suffix) ?? .queen
            return board.completePromotion(of: move, to: kind)
        }

        return move
    }

    static func apply(uci: String, to board: inout Board) -> Bool {
        move(uci: uci, on: &board) != nil
    }
}
