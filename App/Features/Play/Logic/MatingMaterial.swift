//
//  MatingMaterial.swift
//  ChessCoach
//

import ChessKit

/// Whether a side still has the material to deliver mate.
///
/// ## Why this is not `Position.hasInsufficientMaterial`
///
/// `ChessKit` already answers a different and narrower question: whether
/// *neither* side can mate, which is the immediate dead-position draw. The
/// timeout rule needs it per side. When a player flags, FIDE 6.9 makes the game
/// a draw rather than a loss if the **opponent** cannot mate — so the losing
/// side's own material is irrelevant, and a shared predicate cannot express it.
///
/// It lives in the app rather than in `ChessKit` because that package is a
/// third-party MIT dependency; forking it for one predicate would make every
/// future update a merge.
///
/// ## The simplification, stated plainly
///
/// FIDE asks whether mate is reachable "by any series of legal moves", which
/// includes moves the flagged player would never choose — a lone king can be
/// helpmated into a corner by a single knight if it cooperates. Deciding that
/// exactly means searching helpmates, which is not something to do inside a
/// clock tick.
///
/// So this asks the practical question every online implementation asks: could
/// this side force mate against a bare king? That draws K, K+B and K+N, and
/// keeps K+N+N a win on time — the same answer Lichess gives, which matters
/// because it is the answer users have been trained to expect.
enum MatingMaterial {

    /// Whether `color` could mate a lone king with what it has on the board.
    static func canMate(_ color: Piece.Color, in position: Position) -> Bool {
        var knights = 0
        var lightBishops = 0
        var darkBishops = 0

        for piece in position.pieces where piece.color == color {
            switch piece.kind {
            // Any one of these mates on its own, so nothing else needs counting.
            case .pawn, .rook, .queen:
                return true
            case .knight:
                knights += 1
            case .bishop:
                if piece.square.color == .light { lightBishops += 1 } else { darkBishops += 1 }
            case .king:
                continue
            }
        }

        let bishops = lightBishops + darkBishops
        // Two knights can mate a cooperating king, and K+B+N is a forced mate.
        if knights >= 2 { return true }
        if knights >= 1 && bishops >= 1 { return true }
        // Bishops confined to one colour can never cover the squares a lone
        // king escapes to, however many of them there are.
        return lightBishops > 0 && darkBishops > 0
    }

    /// The result of `color` running out of time.
    ///
    /// Returns `nil` when the flag is a plain loss, and a draw reason when the
    /// opponent has nothing to mate with.
    static func timeoutIsDraw(flagged color: Piece.Color, position: Position) -> Bool {
        !canMate(color.opposite, in: position)
    }
}
