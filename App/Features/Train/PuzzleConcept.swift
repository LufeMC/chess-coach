//
//  PuzzleConcept.swift
//  ChessCoach
//

import ChessKit
import Foundation
import TrainingCore

/// Turns a puzzle's theme into words a person would use, and builds the result
/// banner's one line of copy.
///
/// ## Why the two verdicts share this function
///
/// Success and failure produce the *same sentence shape* — verb, em dash, the
/// concept, the square it happened on — and differ only in the verb. That is
/// deliberate and it is the whole point of the component (see ``ResultBanner``):
/// the moment failure gets its own longer, softer sentence, the banner grows,
/// the button moves, and the app has announced that failing is a special event.
/// Keeping one builder makes it structurally hard to reintroduce that.
enum PuzzleConcept {

    /// The noun for a theme, or `nil` when the theme is metadata rather than an
    /// idea (`short`, `crushing`, `master`) and naming it would be noise.
    static func noun(for theme: ThemeTag) -> String? {
        switch theme.rawValue {
        case "fork": "fork"
        case "pin": "pin"
        case "skewer": "skewer"
        case "discoveredAttack": "discovered attack"
        case "doubleCheck": "double check"
        case "deflection": "deflection"
        case "capturingDefender": "capture of the defender"
        case "interference": "interference"
        case "clearance": "clearance"
        case "attraction": "attraction"
        case "intermezzo": "in-between move"
        case "xRayAttack": "x-ray"
        case "trappedPiece": "trapped piece"
        case "hangingPiece": "hanging piece"
        case "backRankMate": "back-rank mate"
        case "smotheredMate": "smothered mate"
        case "anastasiaMate": "Anastasia's mate"
        case "arabianMate": "Arabian mate"
        case "bodenMate": "Boden's mate"
        case "doubleBishopMate": "double-bishop mate"
        case "dovetailMate": "dovetail mate"
        case "hookMate": "hook mate"
        case "killBoxMate": "kill-box mate"
        case "vukovicMate": "Vukovic mate"
        case "promotion": "promotion"
        case "underPromotion": "underpromotion"
        case "enPassant": "en passant capture"
        case "zugzwang": "zugzwang"
        case "quietMove": "quiet move"
        case "defensiveMove": "defensive move"
        case "sacrifice": "sacrifice"
        case "advancedPawn": "passed pawn"
        case "exposedKing": "exposed king"
        case "kingsideAttack": "kingside attack"
        case "queensideAttack": "queenside attack"
        case "attackingF2F7": "attack on f7"
        case "castling": "castling resource"
        case "mateIn1": "mate in one"
        case "mateIn2": "mate in two"
        case "mateIn3": "mate in three"
        case "mateIn4": "mate in four"
        case "mateIn5": "mate in five"
        case "rookEndgame": "rook endgame"
        case "pawnEndgame": "pawn endgame"
        case "queenEndgame": "queen endgame"
        case "knightEndgame": "knight endgame"
        case "bishopEndgame": "bishop endgame"
        case "queenRookEndgame": "queen-and-rook endgame"
        default: nil
        }
    }

    /// The indefinite article for a word, so the banner stops saying
    /// `a en passant capture`.
    static func article(for concept: String) -> String {
        "aeiou".contains(concept.lowercased().first ?? "x") ? "an" : "a"
    }

    /// A one-clause definition of a theme, so naming a pattern always teaches
    /// it in the same breath.
    ///
    /// ``PuzzleReason`` has held that rule since it was written — *naming a
    /// pattern is not explaining it* — but only for the clauses it builds
    /// itself. Where the position proved nothing, the banner fell through to
    /// the theme noun and printed `a pin.` at a reader who is here precisely
    /// because they do not yet know what a pin is. On a corpus sample that was
    /// the entire explanation on about one puzzle in twenty.
    ///
    /// Nil for labels that describe a *kind of position* rather than an idea:
    /// `rook endgame` needs no gloss and inventing one would be filler.
    static func definition(for concept: String) -> String? {
        switch concept {
        case "fork": "one piece attacking two at once"
        case "pin": "the piece cannot move without exposing the one behind it"
        case "skewer": "the valuable piece has to move, and the one behind it falls"
        case "discovered attack": "moving one piece uncovers an attack from another"
        case "double check": "two pieces check at once, so only the king can move"
        case "deflection": "a defender is forced away from what it was holding"
        case "capture of the defender": "take the piece that was holding it together"
        case "interference": "a defender's line is cut by a piece put in the way"
        case "clearance": "a square or line is vacated for another piece"
        case "attraction": "the king is pulled onto a square where it can be hit"
        case "in-between move": "a threat slipped in before the expected reply"
        case "x-ray": "an attack straight through a piece to what stands behind it"
        case "trapped piece": "it has no safe square left to go to"
        case "hanging piece": "it is sitting there with nothing defending it"
        case "back-rank mate": "the king is boxed in by its own pawns"
        case "smothered mate": "the king is hemmed in by its own pieces"
        case "promotion": "the pawn reaches the last rank and becomes a queen"
        case "underpromotion": "promoting to a knight or rook, because a queen does not work"
        case "en passant capture": "a pawn takes one that has just passed it"
        case "zugzwang": "every move they have makes their position worse"
        case "quiet move": "no check, no capture — the threat is what makes it work"
        case "defensive move": "it holds the position rather than attacking"
        case "sacrifice": "material given up for something worth more"
        case "passed pawn": "no enemy pawn can stop it from queening"
        case "exposed king": "the king has lost the shelter around it"
        case "attack on f7": "the square only the king defends"
        case "castling resource": "castling is the move that saves it"
        default: nil
        }
    }

    /// The theme named, and defined when it is an idea rather than a label.
    private static func named(_ concept: String) -> String {
        guard let definition = definition(for: concept) else {
            return "\(article(for: concept)) \(concept)"
        }
        return "\(article(for: concept)) \(concept) — \(definition)"
    }

    /// The banner's single line.
    ///
    /// - Parameters:
    ///   - solved: Which verb the sentence opens with. Nothing else changes.
    ///   - theme: The puzzle's primary theme.
    ///   - answer: The move the user had to find, in UCI. Its destination names
    ///     the file, which is the concrete half of `the pin was on the f-file`.
    /// - Parameter position: the position the answer is played from, used to
    ///   explain *why* the move works. Optional so the copy still builds
    ///   without it, which is what the pure tests and the summary rows rely on.
    /// - Parameters:
    ///   - position: the position the answer is played from, used to explain
    ///     *why* the move works. Optional so the copy still builds without it.
    ///   - mistake: what was wrong with the move the user actually played, when
    ///     something certain can be said about it. Passed in rather than derived
    ///     here because it has two sources — the board immediately, and the
    ///     engine a moment later — and this is a formatter, not a judge.
    ///   - continuation: what follows the answer, the opponent's reply first.
    ///     The rest of a stored puzzle line on a miss, the engine's principal
    ///     variation on a solve, and empty when neither is to hand. It is what
    ///     lets the clause answer "can they not just take it back?".
    static func verdictMessage(
        solved: Bool,
        theme: ThemeTag,
        answer: String?,
        position: Position? = nil,
        mistake: String? = nil,
        continuation: [String] = []
    ) -> String {
        let verb = solved ? "Solved" : "Missed"
        // Read off the board, never from the theme tag. When the position can
        // say why, that is worth more than any label — it is the pattern the
        // user takes to the next puzzle, and it is phrased so that a reader who
        // has never heard the word still learns something.
        let reason = PuzzleReason.clause(forAnswer: answer, in: position, continuation: continuation)
        // Never on a solve: the move that worked has nothing wrong with it.
        let mistake = solved ? nil : mistake

        // The move in words rather than in notation, when the position is on
        // hand to name the pieces.
        let move = PuzzleReason.description(ofMove: answer, in: position)

        let sentence: String
        if let square = destination(ofUCI: answer) {
            if let reason {
                // The explanation supersedes the theme's noun. `the fork was on
                // the f-file` names a pattern at someone; this describes it.
                sentence = "\(verb) — \(move ?? square.notation): \(reason)."
            } else if let move, let concept = noun(for: theme) {
                // Nothing provable from the position, but the theme still names
                // the idea — worth keeping, since the vocabulary is half of what
                // the user is here for. The move goes first so the sentence
                // still opens with something they can act on.
                sentence = "\(verb) — \(move): \(named(concept))."
            } else if let move {
                sentence = "\(verb) — \(move)."
            } else if let concept = noun(for: theme) {
                sentence = "\(verb) — the \(concept) was on the \(square.file.rawValue)-file."
            } else {
                // Fall back to the square rather than to filler: `Missed.` alone
                // is honest, `Missed — nice try` is not.
                sentence = "\(verb) — the move was to \(square.notation)."
            }
        } else if let concept = noun(for: theme) {
            sentence = "\(verb) — the idea was \(named(concept))."
        } else {
            sentence = "\(verb)."
        }

        guard let mistake else { return sentence }
        return "\(sentence) But \(mistake)."
    }

    /// The banner for the set's concept exercise.
    ///
    /// Ends on the concept's own cue rather than on a generic sentence. The
    /// user was taught that line two screens ago, and repeating it here is what
    /// connects "I played the right move" to "I know what to look for" — which
    /// is the only part that survives to the next game.
    static func conceptMessage(
        solved: Bool,
        concept: TrainingConcept,
        answer: String?,
        position: Position?
    ) -> String {
        let verb = solved ? "Solved" : "Missed"
        let move = PuzzleReason.description(ofMove: answer, in: position)
        let reason = PuzzleReason.clause(forAnswer: answer, in: position)

        let opening: String
        if let move, let reason {
            opening = "\(verb) — \(move): \(reason)."
        } else if let move {
            opening = "\(verb) — \(move)."
        } else {
            opening = "\(verb) — \(concept.title)."
        }
        return "\(opening) \(concept.teaching.lookFor)"
    }

    /// The destination square of a UCI move.
    static func destination(ofUCI uci: String?) -> Square? {
        guard let uci, uci.count == 4 || uci.count == 5 else { return nil }
        let characters = Array(uci)
        return Square(String(characters[2...3]))
    }

    /// The origin square of a UCI move.
    static func origin(ofUCI uci: String?) -> Square? {
        guard let uci, uci.count == 4 || uci.count == 5 else { return nil }
        let characters = Array(uci)
        return Square(String(characters[0...1]))
    }

    /// The chip label for a missed item, which is the concept alone.
    static func chipLabel(theme: ThemeTag, answer: String?) -> String {
        if let concept = noun(for: theme) { return concept }
        if let square = destination(ofUCI: answer) { return square.notation }
        return "position"
    }
}
