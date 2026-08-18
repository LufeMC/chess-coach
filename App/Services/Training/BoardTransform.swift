//
//  BoardTransform.swift
//  ChessCoach
//

import ChessKit
import Foundation

/// A geometric transform applied to a stored position before it is shown again.
///
/// This is the mechanical half of `CardPolicy`'s anti-memorization ladder. The
/// policy decides *that* a card should be perturbed; this decides *how* the FEN
/// and the solution moves actually change.
///
/// Both transforms are involutions and both are bijections on the 64 squares, so
/// a legal position maps to a legal position and the solution line maps to a
/// solution line of exactly the same length. That property is what lets the
/// solve state machine treat a transformed puzzle as an ordinary one.
enum BoardTransform: String, Sendable, Hashable, CaseIterable, Codable {

    /// Show the position exactly as stored.
    case identity

    /// Vertical flip plus a colour swap: the same pattern seen from the other
    /// side of the board. Castling rights map cleanly (e1↔e8, a1↔a8, h1↔h8), so
    /// this is always available.
    case colorFlipped

    /// Colour flip *and* a left-right file mirror.
    ///
    /// Strictly stronger than ``colorFlipped`` because it also destroys the
    /// verbal handle ("the knight goes to f6") that a pure colour flip leaves
    /// intact. Only legal when the position has no castling rights left — see
    /// ``isLegal(for:)``.
    case mirrored

    /// Whether this transform produces a legal position from `fen`.
    ///
    /// The only transform that can fail is ``mirrored``, and the only reason it
    /// fails is castling. Standard castling is defined in terms of *specific
    /// squares*: the king on e1/e8 and rooks on a1/h1/a8/h8. A file mirror sends
    /// the king to d1 and swaps the rooks, so the rights in the FEN would no
    /// longer describe anything the rules permit. Rather than silently dropping
    /// the rights — which changes the position's evaluation and can change the
    /// puzzle's solution — the mirror is refused and the caller falls back to a
    /// colour flip.
    func isLegal(for fen: String) -> Bool {
        apply(toFEN: fen) != nil
    }

    /// Applies the transform to a FEN, or returns `nil` when it would not be
    /// legal.
    func apply(toFEN fen: String) -> String? {
        guard case .identity = self else {
            guard var fields = FENFields(fen) else { return nil }

            if self == .mirrored {
                // Checked on the *original* fields: a colour flip preserves
                // "are there any castling rights", so checking before or after
                // is equivalent, and before is the one a reader can verify.
                guard fields.castling == "-" else { return nil }
            }

            fields = fields.colorFlipped()
            if self == .mirrored {
                fields = fields.fileMirrored()
            }

            let transformed = fields.joined
            // Parsing back is the cheap end-to-end check that the field surgery
            // above produced something a chess engine will accept.
            guard Position(fen: transformed) != nil else { return nil }
            return transformed
        }
        return Position(fen: fen) == nil ? nil : fen
    }

    /// Applies the transform to a UCI move (`"e2e4"`, `"e7e8q"`).
    ///
    /// The promotion suffix is a piece *kind* and is deliberately untouched: a
    /// colour flip changes whose pawn it is, not what it becomes.
    func apply(toUCI uci: String) -> String? {
        guard case .identity = self else {
            guard uci.count == 4 || uci.count == 5 else { return nil }
            let characters = Array(uci)
            guard
                let from = transform(square: String(characters[0...1])),
                let to = transform(square: String(characters[2...3]))
            else { return nil }
            let promotion = characters.count == 5 ? String(characters[4]) : ""
            return from + to + promotion
        }
        return uci
    }

    /// Applies the transform to every move in a line.
    func apply(toUCILine line: [String]) -> [String]? {
        var result: [String] = []
        result.reserveCapacity(line.count)
        for move in line {
            guard let transformed = apply(toUCI: move) else { return nil }
            result.append(transformed)
        }
        return result
    }

    private func transform(square: String) -> String? {
        switch self {
        case .identity:
            return square
        case .colorFlipped:
            return FENFields.flippedRank(ofSquare: square)
        case .mirrored:
            return FENFields.flippedRank(ofSquare: square).flatMap(FENFields.mirroredFile(ofSquare:))
        }
    }
}

extension BoardTransform {

    /// The transform a ``CardPresentation`` asks for, degraded to something
    /// legal for this position.
    ///
    /// `CardPolicy` already refuses to ask for a mirror unless the card records
    /// `mirrorIsLegal`, but that flag is stored per card and this is the place
    /// that actually has the FEN — so the check is repeated here rather than
    /// trusted. A stale flag degrades to a colour flip instead of producing an
    /// illegal board.
    static func resolved(for presentation: CardPresentation, fen: String) -> BoardTransform {
        switch presentation {
        case .asIs, .retire, .themeSibling:
            // A sibling is a different position entirely; it is shown as-is,
            // because perturbing a position the user has never seen tests
            // nothing.
            return .identity
        case .colorFlipped:
            return BoardTransform.colorFlipped.isLegal(for: fen) ? .colorFlipped : .identity
        case .mirrored:
            if BoardTransform.mirrored.isLegal(for: fen) { return .mirrored }
            return BoardTransform.colorFlipped.isLegal(for: fen) ? .colorFlipped : .identity
        }
    }
}

// MARK: - FEN field surgery

/// A FEN split into its six fields, with the board kept as eight rank strings.
///
/// Working on the *text* rather than on a parsed `Position` is deliberate: a
/// round trip through `Position` would lose the halfmove/fullmove clocks and the
/// exact en-passant encoding, and both transforms are pure relabelings that the
/// text expresses directly.
struct FENFields: Sendable, Hashable {

    /// Rank strings as they appear in the FEN: index 0 is rank 8, index 7 is
    /// rank 1.
    var ranks: [String]
    var sideToMove: String
    var castling: String
    var enPassant: String
    var halfmove: String
    var fullmove: String

    init?(_ fen: String) {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 4 else { return nil }

        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard ranks.count == 8 else { return nil }

        self.ranks = ranks
        self.sideToMove = fields[1]
        self.castling = fields[2]
        self.enPassant = fields[3]
        // Some FEN sources omit the clocks. Defaulting is safer than refusing:
        // a puzzle corpus row without them is still a perfectly good puzzle.
        self.halfmove = fields.count > 4 ? fields[4] : "0"
        self.fullmove = fields.count > 5 ? fields[5] : "1"
    }

    var joined: String {
        [ranks.joined(separator: "/"), sideToMove, castling, enPassant, halfmove, fullmove]
            .joined(separator: " ")
    }

    /// Vertical flip plus colour swap.
    func colorFlipped() -> FENFields {
        var copy = self
        copy.ranks = ranks.reversed().map(FENFields.swappingCase)
        copy.sideToMove = sideToMove == "w" ? "b" : "w"
        copy.castling = FENFields.canonicalCastling(FENFields.swappingCase(castling))
        copy.enPassant = FENFields.flippedRank(ofSquare: enPassant) ?? enPassant
        return copy
    }

    /// Left-right file mirror (a↔h).
    ///
    /// Reversing each rank string works directly on the run-length encoding:
    /// FEN digits are always a single character, so `"4p3"` reverses to `"3p4"`,
    /// which is the same board read the other way round.
    func fileMirrored() -> FENFields {
        var copy = self
        copy.ranks = ranks.map { String($0.reversed()) }
        copy.enPassant = FENFields.mirroredFile(ofSquare: enPassant) ?? enPassant
        return copy
    }

    // MARK: Square helpers

    /// `"e3"` → `"e6"`. Returns `nil` for anything that is not a square, which
    /// includes the `"-"` en-passant placeholder.
    static func flippedRank(ofSquare square: String) -> String? {
        guard square.count == 2 else { return nil }
        let characters = Array(square)
        guard let rank = characters[1].wholeNumberValue, (1...8).contains(rank) else { return nil }
        return String(characters[0]) + String(9 - rank)
    }

    /// `"c3"` → `"f3"`.
    static func mirroredFile(ofSquare square: String) -> String? {
        guard square.count == 2 else { return nil }
        let characters = Array(square)
        guard
            let file = characters[0].asciiValue,
            file >= UInt8(ascii: "a"), file <= UInt8(ascii: "h")
        else { return nil }
        let mirrored = UInt8(ascii: "a") + (UInt8(ascii: "h") - file)
        return String(UnicodeScalar(mirrored)) + String(characters[1])
    }

    private static func swappingCase(_ text: String) -> String {
        String(text.map { character in
            if character.isUppercase { return Character(character.lowercased()) }
            if character.isLowercase { return Character(character.uppercased()) }
            return character
        })
    }

    /// FEN requires castling rights in `KQkq` order. The colour swap above
    /// produces `kqKQ`, which parses on most readers but is not canonical and
    /// would make two identical positions compare unequal as strings.
    private static func canonicalCastling(_ rights: String) -> String {
        guard rights != "-" else { return "-" }
        let order: [Character] = ["K", "Q", "k", "q"]
        let present = Set(rights)
        let sorted = order.filter { present.contains($0) }
        return sorted.isEmpty ? "-" : String(sorted)
    }
}
