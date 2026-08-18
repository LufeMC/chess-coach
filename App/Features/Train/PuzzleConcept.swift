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

    /// The banner's single line.
    ///
    /// - Parameters:
    ///   - solved: Which verb the sentence opens with. Nothing else changes.
    ///   - theme: The puzzle's primary theme.
    ///   - answer: The move the user had to find, in UCI. Its destination names
    ///     the file, which is the concrete half of `the pin was on the f-file`.
    static func verdictMessage(solved: Bool, theme: ThemeTag, answer: String?) -> String {
        let verb = solved ? "Solved" : "Missed"

        guard let concept = noun(for: theme) else {
            // No idea worth naming. Fall back to the square rather than to
            // filler: `Missed.` alone is honest, `Missed — nice try` is not.
            guard let square = destination(ofUCI: answer) else { return "\(verb)." }
            return "\(verb) — the move was to \(square.notation)."
        }

        guard let square = destination(ofUCI: answer) else {
            return "\(verb) — the idea was a \(concept)."
        }
        return "\(verb) — the \(concept) was on the \(square.file.rawValue)-file."
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
