//
//  PuzzleReason.swift
//  ChessCoach
//

import AnalysisKit
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
    /// ## A capture is not a win
    ///
    /// This once printed `it wins the knight` for *any* capture. That sentence
    /// is true only where the square cannot be defended profitably, and across
    /// the bundled corpus it was false or misleading on roughly one puzzle in
    /// six: a quarter of every capture answer is an outright sacrifice, and
    /// announcing a queen sacrifice as `it wins the pawn` teaches the exact
    /// opposite of the idea the puzzle exists to teach.
    ///
    /// The material claim is now checked by static exchange evaluation and made
    /// only where it holds. A capture that does not statically win is explained
    /// by what happens *next* — which is the entire content of a sacrifice —
    /// and where the continuation is unknown the clause says something weaker
    /// and true rather than something strong and wrong.
    ///
    /// - Parameters:
    ///   - uci: the answer move.
    ///   - position: the position the move is played *from*.
    ///   - continuation: what follows the answer, the opponent's reply first. A
    ///     stored puzzle line where there is one, the engine's principal
    ///     variation otherwise, and empty when nothing is known.
    static func clause(
        forAnswer uci: String?,
        in position: Position?,
        continuation: [String] = []
    ) -> String? {
        guard let uci, let position else { return nil }

        var board = Board(position: position)
        let captured = capturedPiece(playing: uci, in: position)
        guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { return nil }

        // Mate ends the conversation; nothing else about the move matters.
        if move.checkState == .checkmate { return "that is checkmate" }

        let mover = position.piece(at: PuzzleConcept.origin(ofUCI: uci) ?? .a1)
        let hit = attackedPieces(after: uci, board: board, mover: mover)
        let isCheck = move.checkState == .check
        let line = read(continuation: continuation, after: uci, board: board)

        // A line that ends in mate has only one thing worth saying about it.
        // Material, forks and checks are all beside the point once the king is
        // not getting out.
        if line.endsInMate { return "it forces mate" }

        // The fork is the most useful thing to name, because it is the pattern
        // that repeats. Named and defined in one breath.
        if hit.count >= 2 {
            let names = hit.prefix(2).map(noun(for:))
            return "it forks the \(names[0]) and \(names[1]) — both attacked, and only one can move away"
        }

        if let captured, let mover, let destination = PuzzleConcept.destination(ofUCI: uci) {
            let exchange = SEE.seeOfCapture(position: position, move: move) ?? 0

            // Nothing takes back for enough — the only case in which a claim
            // about material is a fact rather than a hope.
            //
            // It is also the case where saying so is nearly worthless. The
            // move description already reads `the pawn takes the pawn`, so
            // `it wins the pawn` spends the one line on screen saying the same
            // thing a third time. What the reader cannot see is *why* the
            // capture is safe — which is the habit the puzzle is trying to
            // build — and what the piece threatens from where it landed.
            if exchange > 0 {
                var parts = [
                    enemyPiecesAttacking(destination, in: board.position, mover: mover).isEmpty
                        ? "nothing defends it"
                        : "the exchange still comes out ahead"
                ]

                // A capture is rarely the whole move. Where the piece lands is
                // usually why this was the answer and not merely playable, and
                // that clause already existed — the material claim above simply
                // returned before anything could reach it.
                if let target = hit.first, target != .king,
                    value(of: target) > value(of: captured.kind)
                {
                    parts.append("it now attacks the \(noun(for: target))")
                }

                let phrase = parts.joined(separator: ", and ")
                return isCheck ? phrase + ", with check" : phrase
            }

            // It can be taken back — which is precisely the objection the reader
            // is about to raise. Answer it with the line rather than writing a
            // sentence that pretends the recapture is not on the board.
            if let mechanism = refutation(from: line, mover: mover) { return mechanism }

            // An even exchange is worth naming as one. Calling it a win was the
            // quieter half of the same untruth.
            if exchange == 0 {
                // "it trades the rook for the rook" is how a machine says it.
                let phrase =
                    mover.kind == captured.kind
                    ? "it trades \(noun(for: mover.kind))s"
                    : "it trades the \(noun(for: mover.kind)) for the \(noun(for: captured.kind))"
                return isCheck ? phrase + ", with check" : phrase
            }

            // A sacrifice whose point cannot be shown falls through to the
            // clauses below: the check or the attack is still true, and saying
            // less is better than inventing the part we cannot see.
        }

        // What the move actually produces. This sits above the two clauses
        // below because both of those describe something already drawn on the
        // board — the reader can see the check and see the attacked piece. What
        // they cannot see is what it forces.
        if let gain = outcome(from: line, isCheck: isCheck) { return gain }

        // "attacks the king, with check" says the same thing twice. Attacking
        // the king *is* check, so the single-target phrasing skips it.
        if let target = hit.first, target != .king {
            let phrase = "it attacks the \(noun(for: target))"
            return isCheck ? phrase + ", with check" : phrase
        }

        return isCheck ? "it puts the king in check" : nil
    }

    /// Whether a search would tell the reader anything this position does not
    /// already say.
    ///
    /// True only for a capture whose material claim static exchange cannot
    /// support — the one shape ``refutation(ofRecaptureAfter:board:continuation:mover:)``
    /// can turn into a mechanism once it has the line. Mate and forks explain
    /// themselves; a capture that statically wins already says so; and a quiet
    /// move has no recapture to answer for, so a search would buy a sentence
    /// identical to the one on screen. Narrow on purpose: this is the gate on
    /// whether the app spends an engine search at all.
    static func needsTheLine(answer uci: String?, in position: Position?) -> Bool {
        guard let uci, let position,
            capturedPiece(playing: uci, in: position) != nil
        else { return false }

        var board = Board(position: position)
        guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { return false }

        if move.checkState == .checkmate { return false }

        let mover = position.piece(at: PuzzleConcept.origin(ofUCI: uci) ?? .a1)
        if attackedPieces(after: uci, board: board, mover: mover).count >= 2 { return false }

        return (SEE.seeOfCapture(position: position, move: move) ?? 0) <= 0
    }

    /// One reading of the moves that follow the answer.
    ///
    /// Walked once and shared. Three clauses need overlapping facts about the
    /// same line, and replaying it once per question is how a set of sentences
    /// ends up quietly disagreeing with each other.
    private struct Line {
        /// The opponent's reply, as a clause.
        var replyDescription: String?
        /// Whether that reply takes back on the square the answer landed on.
        var isRecapture = false
        /// The solver's move after that reply, as a clause.
        var punishDescription: String?
        var punishCaptured: Piece.Kind?
        var punishGivesCheck = false
        /// The most valuable piece the solver captures anywhere in the line.
        var won: Piece.Kind?
        /// A pawn of the solver's promotes before the line is out.
        var promotes = false
        /// A move *of the solver's* ends the game.
        var endsInMate = false
    }

    /// Replays the continuation from the position after the answer.
    ///
    /// - Parameters:
    ///   - continuation: the opponent's reply first, then alternating.
    ///   - board: the position *after* the answer has been played.
    private static func read(continuation: [String], after uci: String, board: Board) -> Line {
        var line = Line()
        guard let destination = PuzzleConcept.destination(ofUCI: uci) else { return line }

        var probe = board
        for (index, step) in continuation.enumerated() {
            let before = probe.position
            // `continuation[0]` is the opponent's, so the solver has the odd
            // indices. Getting this backwards would credit the user with the
            // pieces their opponent took off them.
            let isSolvers = index % 2 == 1

            if index == 0 {
                line.isRecapture = PuzzleConcept.destination(ofUCI: step) == destination
                // "their" rather than "the": the reply belongs to the opponent,
                // and a sentence that reads `after the king goes to e7 you win
                // the knight` leaves the reader working out whose king moved.
                line.replyDescription = sentence(forMove: step, in: before)
                    .map { $0.hasPrefix("the ") ? "their " + $0.dropFirst(4) : $0 }
            }
            if index == 1 {
                line.punishDescription = sentence(forMove: step, in: before)
                line.punishCaptured = capturedPiece(playing: step, in: before)?.kind
            }
            if isSolvers, let taken = capturedPiece(playing: step, in: before) {
                if let best = line.won {
                    if value(of: taken.kind) > value(of: best) { line.won = taken.kind }
                } else {
                    line.won = taken.kind
                }
            }

            if isSolvers, step.count == 5 { line.promotes = true }

            guard let played = PuzzleSolveMachine.move(uci: step, on: &probe) else { break }
            if index == 1 { line.punishGivesCheck = played.checkState == .check }
            if played.checkState == .checkmate { line.endsInMate = isSolvers }
        }
        return line
    }

    /// The answer to "but can't they just take it back?".
    ///
    /// The one question a defended capture always raises, and the one the old
    /// wording answered by ignoring. It speaks only when the line contains the
    /// recapture *and* the solver wins something at least as big afterwards;
    /// every other shape returns nil, because a half-remembered mechanism is
    /// worse than a plain description of the move.
    private static func refutation(from line: Line, mover: Piece) -> String? {
        guard line.isRecapture,
            let described = line.punishDescription,
            let won = line.won,
            value(of: won) >= value(of: mover.kind)
        else { return nil }

        let punish = line.punishGivesCheck ? described + " with check" : described

        // When the punishing move *is* the capture that wins the piece, naming
        // the piece again turns the sentence into a stutter — "the queen takes
        // the rook and you win the rook".
        if line.punishCaptured == won { return "if they take back, \(punish)" }
        return "if they take back, \(punish) and you win the \(noun(for: won))"
    }

    /// What the line produces, for the moves the board cannot explain by itself.
    ///
    /// `it puts the king in check` was the single most common sentence this
    /// file produced — about a third of every explanation — and it describes
    /// something already drawn on the board in a colour the user cannot miss. A
    /// check is not why a move is the answer. What the check *forces* is.
    ///
    /// Winning a *pawn* is deliberately not enough on its own: "you win the
    /// pawn" three moves out is rarely the idea, and it would crowd out the
    /// clauses that are. The exception is a pawn that promotes, which is not a
    /// pawn win at all — it is the whole point of every pawn endgame, and the
    /// threshold alone would have said nothing about it.
    private static func outcome(from line: Line, isCheck: Bool) -> String? {
        guard let reply = line.replyDescription else { return nil }

        let gain: String
        if line.promotes {
            gain = "your pawn queens"
        } else if let won = line.won, value(of: won) >= value(of: .knight) {
            gain = "you win the \(noun(for: won))"
        } else {
            return nil
        }

        return isCheck
            ? "it checks, and after \(reply) \(gain)"
            : "after \(reply), \(gain)"
    }

    /// A move as a clause rather than a label — `the rook goes to d1` — so it
    /// can be joined to another clause with "and" without producing the sort of
    /// sentence that reads as though a word were missing.
    ///
    /// ``description(ofMove:in:)`` stays as it is: it names the move at the
    /// head of the banner, where a label is exactly right.
    private static func sentence(forMove uci: String, in position: Position) -> String? {
        guard let destination = PuzzleConcept.destination(ofUCI: uci),
            let origin = PuzzleConcept.origin(ofUCI: uci),
            let mover = position.piece(at: origin)
        else { return nil }

        if let captured = capturedPiece(playing: uci, in: position) {
            return "the \(noun(for: mover.kind)) takes the \(noun(for: captured.kind))"
        }
        return "the \(noun(for: mover.kind)) goes to \(destination.notation)"
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

        // `CalibrationScoring` scores the king 0, which is right for counting
        // material — both sides always have one — and wrong for picking an
        // attacker, because it makes the king the "cheapest" recapture whenever
        // it happens to stand next to the square. The defending pawn is both
        // the likelier recapture and the more useful thing to name, so the king
        // sorts last and is reached only when nothing else attacks at all.
        let attackers = enemyPiecesAttacking(destination, in: board.position, mover: mover)
        let cheapestFirst = attackers.sorted { lhs, rhs in
            if (lhs == .king) != (rhs == .king) { return rhs == .king }
            return value(of: lhs) < value(of: rhs)
        }
        guard let cheapest = cheapestFirst.first,
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
