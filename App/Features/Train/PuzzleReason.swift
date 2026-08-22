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
    /// `"forks the queen and rook — only one of them can move away"`.
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
        // that repeats. Named and defined in one breath — and only once the
        // forking piece is known to survive the square it landed on.
        //
        // A knight dropped on a pawn-defended square attacking king and rook
        // attacks both of them and forks neither: the answer to "only one of
        // them can move away" is "neither has to, we just take the knight". The
        // clause used to be emitted before any safety check ran, which taught
        // the pattern with the half that makes it work left out.
        var attacksTwo: String?
        if hit.count >= 2 {
            let names = hit.prefix(2).map(noun(for:))
            if !moverIsHanging(after: uci, board: board, from: position) {
                return "it forks the \(names[0]) and \(names[1]) — only one of them can move away"
            }
            attacksTwo = "it attacks the \(names[0]) and the \(names[1])"
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
        if let gain = outcome(
            from: line,
            isCheck: isCheck,
            answerGain: captured.map { value(of: $0.kind) } ?? 0
        ) { return gain }

        // A quiet move whose whole point is that something of yours was
        // hanging. Nothing above this can see it: it captures nothing, forks
        // nothing, checks nothing and attacks nothing bigger than itself, so
        // every clause so far declines and the banner used to fall through to
        // naming the square. "The queen to d6" with no reason is the single
        // least useful thing this file can say, and defence is the most common
        // reason it was saying it.
        if let mover, let destination = PuzzleConcept.destination(ofUCI: uci),
            let held = defence(before: position, after: board, mover: mover, movedTo: destination)
        {
            return isCheck ? held + ", with check" : held
        }

        // The double attack the fork clause declined to claim. Still true, and
        // still the most useful thing on the board — it simply stops short of
        // promising that one of the two pieces has to fall.
        if let attacksTwo { return isCheck ? attacksTwo + ", with check" : attacksTwo }

        // "attacks the king, with check" says the same thing twice. Attacking
        // the king *is* check, so the single-target phrasing skips it.
        if let target = hit.first, target != .king {
            let phrase = "it attacks the \(noun(for: target))"
            return isCheck ? phrase + ", with check" : phrase
        }

        return isCheck ? "it puts the king in check" : nil
    }

    /// A first hint: what *kind* of move the answer is, without naming it.
    ///
    /// ## Why a nudge and not the arrow
    ///
    /// A stuck user had two options, and both ended the attempt: give up, or be
    /// shown the move. Neither exercises the thing that actually moves a player
    /// toward 2000, which is the search itself — checks, captures, loose pieces,
    /// in that order. Naming the *class* of the answer prunes that search
    /// without finishing it: the reader still has to find which check, or what
    /// the threat is, and the finding is the part that gets remembered.
    ///
    /// Every line is read off the board by playing the move, so none of it can
    /// disagree with the position. None of them names a piece, a square or a
    /// target — that is the arrow's job, one rung up.
    static func nudge(forAnswer uci: String?, in position: Position?) -> String? {
        guard let uci, let position else { return nil }

        var board = Board(position: position)
        let takes = capturedPiece(playing: uci, in: position) != nil
        guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { return nil }

        // Mate is the one case where naming the class is nearly the whole
        // instruction, and that is exactly right: the habit a mating puzzle
        // teaches is looking at every check before anything else.
        if move.checkState == .checkmate { return "The move ends the game. Go through every check." }

        switch (move.checkState == .check, takes) {
        case (true, true): return "The move is a check, and it takes something."
        case (true, false): return "The move is a check. Work out what the king can answer with."
        case (false, true): return "The move takes something. Work out what takes back first."
        case (false, false):
            return "No check, no capture — the move makes a threat. Ask what your pieces would hit next."
        }
    }

    /// Whether a search would tell the reader anything this position does not
    /// already say.
    ///
    /// This is the gate on whether the app spends an engine search at all, so
    /// it declines wherever the board can already speak: mate and a *safe* fork
    /// explain themselves, and a capture that statically wins already says so.
    ///
    /// It says yes in two shapes. The first is a capture whose material claim
    /// static exchange cannot support — the sacrifice, which the line turns into
    /// a mechanism. The second is any move for which the board produces no
    /// clause at all: a quiet improving move has no recapture to answer for and
    /// nothing to point at, which is exactly why it ended at `the queen to d6`
    /// with the reason left unsaid. Every position mined from the user's own
    /// game is that shape, and those are the cards that matter most.
    static func needsTheLine(answer uci: String?, in position: Position?) -> Bool {
        guard let uci, let position else { return false }

        var board = Board(position: position)
        guard let move = PuzzleSolveMachine.move(uci: uci, on: &board) else { return false }

        if move.checkState == .checkmate { return false }

        let mover = position.piece(at: PuzzleConcept.origin(ofUCI: uci) ?? .a1)
        if attackedPieces(after: uci, board: board, mover: mover).count >= 2,
            !moverIsHanging(after: uci, board: board, from: position)
        {
            return false
        }

        if capturedPiece(playing: uci, in: position) != nil {
            return (SEE.seeOfCapture(position: position, move: move) ?? 0) <= 0
        }

        return clause(forAnswer: uci, in: position) == nil
    }

    /// Whether the piece that just moved can simply be taken where it landed.
    ///
    /// Read with static exchange, so a defended piece is not "hanging" merely
    /// because something attacks it. Conservative by construction: it is only
    /// ever used to *withhold* a claim, so an over-cautious answer costs a
    /// sentence and a wrong one costs the pattern.
    private static func moverIsHanging(after uci: String, board: Board, from position: Position) -> Bool {
        guard let destination = PuzzleConcept.destination(ofUCI: uci) else { return false }
        return SEE.see(
            position: board.position,
            target: destination,
            side: position.sideToMove.opposite
        ) > 0
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
        /// Material across the whole line, in the solver's favour: what they
        /// take, less what the opponent takes back.
        ///
        /// ``won`` alone is a list of the solver's captures, which is not an
        /// outcome. `Bxh7+ Kxh7 … Nxe6` wins a pawn on that reading and loses a
        /// bishop on the board, and "you win the pawn" is exactly the sort of
        /// confidently wrong material claim this file exists to refuse.
        var net = 0
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
        /// Where the solver's pawn just promoted, until the next ply answers
        /// for it.
        var promotionSquare: Square?
        for (index, step) in continuation.enumerated() {
            let before = probe.position
            // `continuation[0]` is the opponent's, so the solver has the odd
            // indices. Getting this backwards would credit the user with the
            // pieces their opponent took off them.
            let isSolvers = index % 2 == 1

            if index == 0 {
                line.isRecapture = PuzzleConcept.destination(ofUCI: step) == destination
                line.replyDescription = opponentSentence(forMove: step, in: before)
            }
            if index == 1 {
                line.punishDescription = sentence(forMove: step, in: before)
                line.punishCaptured = capturedPiece(playing: step, in: before)?.kind
            }
            if let taken = capturedPiece(playing: step, in: before) {
                if isSolvers {
                    line.net += value(of: taken.kind)
                    if let best = line.won {
                        if value(of: taken.kind) > value(of: best) { line.won = taken.kind }
                    } else {
                        line.won = taken.kind
                    }
                } else {
                    line.net -= value(of: taken.kind)
                }
            }

            // A promotion is only worth announcing if the new queen is still
            // there a move later. The opponent's reply is the only ply that can
            // answer that, so the claim is withdrawn when it takes the square
            // back, and kept when the line ends and nothing contradicts it.
            if isSolvers, step.count == 5 {
                line.promotes = true
                promotionSquare = PuzzleConcept.destination(ofUCI: step)
            } else if let square = promotionSquare {
                if PuzzleConcept.destination(ofUCI: step) == square,
                    capturedPiece(playing: step, in: before) != nil
                {
                    line.promotes = false
                }
                promotionSquare = nil
            }

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
    private static func outcome(from line: Line, isCheck: Bool, answerGain: Int) -> String? {
        // What the line is worth on the board, counting the answer's own
        // capture and every recapture that follows it.
        let net = answerGain + line.net
        let gain: String
        if line.promotes {
            gain = "your pawn queens"
        } else if let won = line.won, value(of: won) >= value(of: .knight), net >= value(of: won) {
            gain = "you win the \(noun(for: won))"
        } else {
            return nil
        }

        // A check does not spell out the reply. Answering a check is forced
        // enough that the reader can see it coming, and naming it was the
        // single commonest way this sentence overran the banner and got its
        // ending cut off — which costs more than the reply was worth.
        //
        // A quiet move is the opposite case: "after what?" is exactly the
        // question it raises, so there the reply is the whole point.
        if isCheck { return "it checks, and \(gain)" }

        guard let reply = line.replyDescription else { return nil }
        return "after \(reply), \(gain)"
    }

    /// A move whose point is that something of yours could simply be taken.
    ///
    /// Read with static exchange rather than "is it attacked": a knight
    /// attacked by a queen and defended by a pawn is not hanging, and telling
    /// the user it was would teach them to fear every attack instead of
    /// counting. Only pieces are considered — announcing the rescue of a pawn
    /// would drown the clause that matters.
    private static func defence(
        before: Position,
        after: Board,
        mover: Piece,
        movedTo: Square
    ) -> String? {
        let enemy = mover.color.opposite

        // The most valuable thing of ours the opponent could actually profit by
        // taking, before the move was made.
        let exposed = before.pieces
            .filter { $0.color == mover.color && $0.kind != .king }
            .filter { SEE.see(position: before, target: $0.square, side: enemy) > 0 }
            .max { value(of: $0.kind) < value(of: $1.kind) }

        guard let exposed, value(of: exposed.kind) >= value(of: .knight) else { return nil }

        // The piece that was hanging is the piece that moved.
        if exposed.square == mover.square {
            guard SEE.see(position: after.position, target: movedTo, side: enemy) <= 0 else { return nil }
            return "it moves the \(noun(for: exposed.kind)) out of the attack"
        }

        // Otherwise the move has to have actually settled it — a "defence" that
        // leaves the piece just as takeable is not one.
        guard SEE.see(position: after.position, target: exposed.square, side: enemy) <= 0 else {
            return nil
        }
        return "it defends the \(noun(for: exposed.kind)), which had nothing guarding it"
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

    /// The same clause from the opponent's side of the board.
    ///
    /// "their" rather than "the": the move belongs to the opponent, and a
    /// sentence that reads `after the king goes to e7 you win the knight`
    /// leaves the reader working out whose king moved.
    private static func opponentSentence(forMove uci: String, in position: Position) -> String? {
        sentence(forMove: uci, in: position)
            .map { $0.hasPrefix("the ") ? "their " + $0.dropFirst(4) : $0 }
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

    /// What the opponent does about the move the user played.
    ///
    /// ## Why a band is not an explanation
    ///
    /// `yours leaves you worse off` is a verdict with the mechanism removed. It
    /// tells the reader that the position got worse and never what made it
    /// worse, so the only thing it can teach is to trust a score — and the
    /// habit that actually moves a 1200 upward is looking at the opponent's
    /// reply *before* committing. The reply is the thing they did not look at,
    /// so the reply is the thing worth showing.
    ///
    /// ## Only a capture or a check
    ///
    /// Those two are concrete: the reader can put the piece on the square and
    /// see it happen, which is the check they failed to make. A quiet reply
    /// amounts to "and now they are simply better" — the positional judgement
    /// the band phrase has already made, restated in a form the reader cannot
    /// verify — so it is left unsaid.
    ///
    /// Nothing here is a material claim. *Their knight takes the rook* is a
    /// description of a move on the board, not an assertion about what the
    /// exchange is worth, and the recapture (if there is one) is still the
    /// reader's to find.
    ///
    /// - Parameters:
    ///   - reply: the opponent's move, in UCI — the first ply of the line the
    ///     engine found after `played`.
    ///   - played: the move the user chose.
    ///   - position: the position `played` was chosen from.
    static func punishment(reply: String, afterPlaying played: String, in position: Position) -> String? {
        var board = Board(position: position)
        guard PuzzleSolveMachine.move(uci: played, on: &board) != nil else { return nil }

        let after = board.position
        guard let described = opponentSentence(forMove: reply, in: after) else { return nil }
        let takesSomething = capturedPiece(playing: reply, in: after) != nil
        guard let move = PuzzleSolveMachine.move(uci: reply, on: &board) else { return nil }

        if move.checkState == .checkmate { return "\(described), and that is mate" }
        let isCheck = move.checkState == .check
        guard takesSomething || isCheck else { return nil }
        return isCheck ? "\(described), with check" : described
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
