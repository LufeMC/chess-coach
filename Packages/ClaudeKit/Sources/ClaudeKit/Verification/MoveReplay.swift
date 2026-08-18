//
//  MoveReplay.swift
//  ClaudeKit
//

import ChessKit
import Foundation

/// Replays UCI moves on a real board so quoted SAN can be re-derived rather
/// than trusted.
///
/// This is why ClaudeKit depends on ChessKit. A model that writes
/// `{"uci": "g1f3", "san": "Nxe5"}` has produced a line where the UCI is a
/// faithful copy of the PV and the SAN — the part the student actually reads —
/// is fiction. Comparing strings against the PV catches the first half of that;
/// only replaying the position catches the second.
struct MoveReplay {

    /// Why a UCI string could not be applied.
    enum ReplayFailure: Equatable {
        case malformedUCI
        case illegal
        case missingPromotionPiece
    }

    private var board: Board

    /// Fails when the FEN itself is unusable.
    init?(fen: String) {
        guard let position = Position(fen: fen) else { return nil }
        self.board = Board(position: position)
    }

    /// The position as it currently stands.
    var position: Position { board.position }

    /// Applies one UCI move and returns its canonical SAN.
    mutating func apply(uci: String) -> Result<String, ReplayFailure> {
        guard let (start, end, promotion) = Self.parse(uci: uci) else {
            return .failure(.malformedUCI)
        }

        guard board.canMove(pieceAt: start, to: end) else {
            return .failure(.illegal)
        }

        guard var move = board.move(pieceAt: start, to: end) else {
            return .failure(.illegal)
        }

        // A pawn landing on the back rank leaves the board mid-move: ChessKit
        // reports `.promotion` and waits. The engine always spells out the
        // piece, so a missing one means the string is not the engine's.
        if case .promotion = board.state {
            guard let promotion else { return .failure(.missingPromotionPiece) }
            move = board.completePromotion(of: move, to: promotion)
        }

        return .success(move.san)
    }

    /// Whether a SAN string is a legal move in the current position.
    ///
    /// Used by the notation scan, where the question is not "is this a move we
    /// showed" but "is this text a move at all here".
    func isLegalSAN(_ san: String) -> Bool {
        guard let move = SANParser.parse(move: san, in: board.position) else { return false }
        // SANParser builds castling moves without checking whether castling is
        // actually available, so legality is re-checked on the board.
        return board.canMove(pieceAt: move.start, to: move.end)
    }

    /// Splits a UCI string into squares plus an optional promotion piece.
    ///
    /// Hand-validated rather than handed to `Square(_:)`, which silently
    /// substitutes `a1` for anything it doesn't recognise — a malformed string
    /// would otherwise turn into a plausible-looking move.
    static func parse(uci: String) -> (start: Square, end: Square, promotion: Piece.Kind?)? {
        let characters = Array(uci)
        guard characters.count == 4 || characters.count == 5 else { return nil }

        func square(_ file: Character, _ rank: Character) -> Square? {
            guard ("a"..."h").contains(file), ("1"..."8").contains(rank) else { return nil }
            return Square("\(file)\(rank)")
        }

        guard
            let start = square(characters[0], characters[1]),
            let end = square(characters[2], characters[3])
        else { return nil }

        var promotion: Piece.Kind?
        if characters.count == 5 {
            guard let kind = Piece.Kind(rawValue: String(characters[4]).uppercased()),
                  kind != .pawn, kind != .king
            else { return nil }
            promotion = kind
        }

        return (start, end, promotion)
    }

}
