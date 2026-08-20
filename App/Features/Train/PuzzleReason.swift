//
//  PuzzleReason.swift
//  ChessCoach
//

import ChessKit

/// Why the answer was the answer, and why the move you played was not — both
/// read off the board.
///
/// ## The problem this solves
///
/// The banner used to end at `Missed — the move was to d3.` A square is *what*
/// the move was, never *why*, and "why" is the entire content of a tactics
/// puzzle.
///
/// ## Naming a pattern is not explaining it
///
/// The first version of this said `f3 is the fork: it forks the queen and rook`,
/// which is circular and, worse, assumes the reader already knows the word. The
/// user this app is built for is on their way *to* 2000, not back from it: "fork"
/// is exactly the vocabulary they are here to acquire, and a term used as though
/// it were common knowledge teaches nothing and quietly signals that the app is
/// for somebody else.
///
/// So every clause names the pattern **and** says what it means in the same
/// breath — `forks the queen and rook — both attacked, and only one can move
/// away`. The definition is short enough to survive being read fifty times,
/// which is the real constraint on a line that appears after every puzzle.
///
/// ## Everything here is a fact, not a guess
///
/// Every clause is derived by playing the move on a copy of the board and
/// reading the result. Nothing is inferred from the puzzle's theme tag, which is
/// a label attached by a database and can disagree with the position in front of
/// the user. Where the position supports no confident sentence this returns
/// `nil` and the caller keeps its plain wording: a missing explanation is a
/// small disappointment, a confidently wrong one teaches the wrong pattern.
enum PuzzleReason {

    // MARK: Naming the move

    /// The move in words a beginner already has, e.g. `"the queen takes the
    /// rook"` or `"the knight to f3"`.
    ///
    /// ## Why the square alone was not enough
    ///
    /// The banner used to open `Missed — e1:` and stop. Algebraic notation is
    /// the first thing a chess book assumes and close to the last thing a new
    /// player learns, so for the reader this app is built for that prefix was
    /// two characters of noise in front of the only sentence that mattered.
    ///
    /// A capture is describable without notation at all — *the queen takes the
    /// rook* is a complete thought — so captures never mention a square. A quiet
    /// move has no such phrasing, so it keeps the square but anchors it to the
    /// piece: *the knight to f3*, next to a board already drawing a target on
    /// f3. That pairing is how notation is actually learned, and it costs the
    /// reader who does not know it nothing.
    static func description(ofMove uci: String?, in position: Position?) -> String? {
        guard let uci, let position,
            let destination = PuzzleConcept.destination(ofUCI: uci),
            let origin = PuzzleConcept.origin(ofUCI: uci),
            let mover = position.piece(at: origin)
        else { return nil }

        if let captured = capturedPiece(playing: uci, in: position) {
            return "the \(noun(for: mover.kind)) takes the \(noun(for: captured.kind))"
        }
        return "the \(noun(for: mover.kind)) to \(destination.notation)"
    }

    // MARK: The right move

    /// Why the answer works, e.g.
    /// `"forks the queen and rook — both attacked, and only one can move away"`.
    /// Nil when nothing certain can be said.
    ///
    /// - Parameters:
    ///   - uci: the answer move.
    ///   - position: the position the move is played *from*.
    static func clause(forAnswer uci: String?, in position: Position?) -> String? {
        guard let uci, let position else { return nil }

        var board = Board(position: position)
        let captured = capturedPiece(playing: uci, in: position)
        guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { return nil }

        // Mate ends the conversation; nothing else about the move matters.
        if move.checkState == .checkmate { return "that is checkmate" }

        let mover = position.piece(at: PuzzleConcept.origin(ofUCI: uci) ?? .a1)
        let hit = attackedPieces(after: uci, board: board, mover: mover)
        let isCheck = move.checkState == .check

        // The fork is the most useful thing to name, because it is the pattern
        // that repeats. Named and defined in one breath.
        if hit.count >= 2 {
            let names = hit.prefix(2).map(noun(for:))
            return "it forks the \(names[0]) and \(names[1]) — both attacked, and only one can move away"
        }

        if let captured {
            let phrase = "it wins the \(noun(for: captured.kind))"
            return isCheck ? phrase + ", with check" : phrase
        }

        // "attacks the king, with check" says the same thing twice. Attacking
        // the king *is* check, so the single-target phrasing skips it.
        if let target = hit.first, target != .king {
            let phrase = "it attacks the \(noun(for: target))"
            return isCheck ? phrase + ", with check" : phrase
        }

        return isCheck ? "it puts the king in check" : nil
    }

    // MARK: The move you played

    /// What was wrong with the move the user actually chose.
    ///
    /// Only one mistake is reported, and only when it is *certain*: the move put
    /// a piece where something cheaper can take it. That is unarguable — even if
    /// the square is defended, trading a queen for a pawn and recapturing still
    /// loses eight points of material — so it can be stated flatly without any
    /// engine analysis.
    ///
    /// Everything vaguer is deliberately left unsaid. "It doesn't create a
    /// threat" or "it's not the strongest" are the kind of sentences that sound
    /// like coaching and carry no information, and a beginner cannot tell the
    /// difference between those and the true ones. Returning `nil` costs a line
    /// of feedback; guessing costs the user's trust in every line that follows.
    static func mistake(inMove uci: String?, from position: Position?) -> String? {
        guard let uci, let position,
            let destination = PuzzleConcept.destination(ofUCI: uci),
            let mover = position.piece(at: PuzzleConcept.origin(ofUCI: uci) ?? .a1)
        else { return nil }

        var board = Board(position: position)
        guard PuzzleSolveMachine.move(uci: uci, on: &board) != nil else { return nil }

        // A capture that wins more than it risks is not the mistake worth
        // naming, even if the piece can be taken back.
        let gained = capturedPiece(playing: uci, in: position).map { value(of: $0.kind) } ?? 0
        let moverValue = value(of: mover.kind)

        let attackers = enemyPiecesAttacking(destination, in: board.position, mover: mover)
        guard let cheapest = attackers.min(by: { value(of: $0) < value(of: $1) }),
            value(of: cheapest) < moverValue - gained
        else { return nil }

        return "your \(noun(for: mover.kind)) could be taken by the \(noun(for: cheapest))"
    }

    // MARK: Facts

    /// What the move captures, if anything. Read before the move is played.
    private static func capturedPiece(playing uci: String, in position: Position) -> Piece? {
        guard let destination = PuzzleConcept.destination(ofUCI: uci) else { return nil }
        guard let piece = position.piece(at: destination) else { return nil }
        // Only an enemy piece is a capture; a friendly piece on the destination
        // means the move is castling notated as king-takes-rook, which is not.
        return piece.color == position.sideToMove ? nil : piece
    }

    /// Enemy pieces the moved piece attacks from its new square, worth more than
    /// the mover itself — which is what makes a fork a fork rather than a pair
    /// of even trades.
    private static func attackedPieces(after uci: String, board: Board, mover: Piece?) -> [Piece.Kind] {
        guard let mover,
            let destination = PuzzleConcept.destination(ofUCI: uci),
            let nullMoved = nullMovePosition(from: board.position)
        else { return [] }

        var probe = Board(position: nullMoved)
        let moverValue = value(of: mover.kind)

        return probe.legalMoves(forPieceAt: destination)
            .compactMap { nullMoved.piece(at: $0) }
            .filter { target in
                guard target.color != mover.color else { return false }
                // The king counts however the arithmetic falls: an attack on it
                // is check, and check is never an even trade.
                return target.kind == .king || value(of: target.kind) > moverValue
            }
            .map(\.kind)
            // Kings first, so `forks the king and rook` reads the way a player
            // would say it.
            .sorted { lhs, rhs in
                if (lhs == .king) != (rhs == .king) { return lhs == .king }
                return value(of: lhs) > value(of: rhs)
            }
    }

    /// Enemy pieces that can capture on `square` in the position after the move.
    ///
    /// The side to move here is already the opponent, so their moves generate
    /// directly — no null move needed.
    private static func enemyPiecesAttacking(
        _ square: Square,
        in position: Position,
        mover: Piece
    ) -> [Piece.Kind] {
        var probe = Board(position: position)
        return position.pieces
            .filter { $0.color != mover.color }
            .filter { probe.legalMoves(forPieceAt: $0.square).contains(square) }
            .map(\.kind)
    }

    /// The same position with the other side to move.
    ///
    /// Done through FEN because `sideToMove` is `private(set)` in `ChessKit`,
    /// and forking that package for one setter would make every future update a
    /// merge.
    private static func nullMovePosition(from position: Position) -> Position? {
        let fields = position.fen.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        var flipped = fields.map(String.init)
        flipped[1] = flipped[1] == "w" ? "b" : "w"
        // En passant cannot survive a null move, and leaving it set invents a
        // capture that is not available to the side now "on move".
        if flipped.count >= 4 { flipped[3] = "-" }
        return Position(fen: flipped.joined(separator: " "))
    }

    private static func value(of kind: Piece.Kind) -> Int {
        CalibrationScoring.value(of: kind)
    }

    /// The word a player would use for a piece.
    private static func noun(for kind: Piece.Kind) -> String {
        switch kind {
        case .pawn: "pawn"
        case .knight: "knight"
        case .bishop: "bishop"
        case .rook: "rook"
        case .queen: "queen"
        case .king: "king"
        }
    }
}
