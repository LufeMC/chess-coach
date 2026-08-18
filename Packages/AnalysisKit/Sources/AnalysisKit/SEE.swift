//
//  SEE.swift
//  AnalysisKit
//

import ChessKit

/// Material values in centipawns.
///
/// These drive SEE, the "is this piece worth caring about" filters in the
/// detectors (`>= 300` means "a real piece, not a pawn"), and the fork/pin
/// classifiers. The knight/bishop split (320/330) is deliberate: it makes
/// bishop-takes-knight a small plus rather than a dead-equal trade, which keeps
/// SEE from reporting 0 on exchanges that a coach would call slightly good.
public enum PieceValues {
    public static let pawn = 100
    public static let knight = 320
    public static let bishop = 330
    public static let rook = 500
    public static let queen = 900
    /// Not a tradeable value — large enough that the king is never chosen as the
    /// least valuable attacker while any other attacker remains.
    public static let king = 20_000

    /// The threshold above which a piece counts as "material", i.e. not a pawn.
    public static let minorPieceFloor = 300

    public static func value(of kind: Piece.Kind) -> Int {
        switch kind {
        case .pawn: pawn
        case .knight: knight
        case .bishop: bishop
        case .rook: rook
        case .queen: queen
        case .king: king
        }
    }

    public static func value(of piece: Piece) -> Int { value(of: piece.kind) }
}

/// Static exchange evaluation: what a capture sequence on one square is worth,
/// assuming both sides always recapture with their least valuable attacker.
///
/// Two entry points with deliberately different sign conventions:
///
/// * ``see(board:target:side:)`` answers "how much can `side` **gain** by
///   starting an exchange here". It is the `max(0, …)` swap formulation, so it
///   is never negative: a side that would lose material simply declines.
/// * ``seeOfCapture(board:move:)`` answers "what does *this specific capture*
///   score". It can be negative, because the capture has already been committed
///   to. This is the one to use when judging a move the player actually made.
public enum SEE {

    // MARK: Public API

    /// The material `side` can win by initiating captures on `target`.
    ///
    /// - returns: Centipawns, never negative (0 means "no profitable capture").
    public static func see(board: Board, target: Square, side: Piece.Color) -> Int {
        see(Occupancy(board.position), target: target, side: side)
    }

    /// The material `side` can win by initiating captures on `target`.
    public static func see(position: Position, target: Square, side: Piece.Color) -> Int {
        see(Occupancy(position), target: target, side: side)
    }

    /// The value of a specific capture: what it wins, minus what the ensuing
    /// exchange on that square wins back.
    ///
    /// Negative means the capture loses material. Handles en passant (the
    /// captured pawn is not on the destination square) and promotion-captures.
    ///
    /// - returns: `nil` if `move` is not a capture.
    public static func seeOfCapture(board: Board, move: Move) -> Int? {
        seeOfCapture(position: board.position, move: move)
    }

    /// See ``seeOfCapture(board:move:)``.
    public static func seeOfCapture(position: Position, move: Move) -> Int? {
        guard case .capture(let captured) = move.result else { return nil }
        return exchangeValue(position: position, move: move, captured: captured)
    }

    /// The static exchange value of *any* move, capture or not.
    ///
    /// A quiet move scores `0 - (what the opponent wins on the destination)`, so
    /// moving a rook onto a square defended by a pawn scores about -500. This is
    /// the "is this move materially non-losing" primitive that the criticality
    /// forced-recapture filter and the trapped-piece theme need.
    public static func staticExchange(position: Position, move: Move) -> Int {
        let captured: Piece? = if case .capture(let piece) = move.result { piece } else { nil }
        return exchangeValue(position: position, move: move, captured: captured)
    }

    /// The static exchange value of a hypothetical move from one square to
    /// another, without needing a legal `Move` object.
    ///
    /// Needed by the theme classifier, which asks questions like "could the
    /// knight take on d5 without losing material" and "does this trapped bishop
    /// have any square that does not drop it" — neither of which corresponds to a
    /// move anybody played.
    ///
    /// - note: En passant is not modelled here (the victim is assumed to stand on
    ///   `to`), which is correct for every caller: en passant only ever comes up
    ///   through ``seeOfCapture(position:move:)``, which has the real move.
    public static func exchangeValue(position: Position, from: Square, to: Square) -> Int {
        exchangeValue(occupancy: Occupancy(position), from: from, to: to)
    }

    static func exchangeValue(occupancy: Occupancy, from: Square, to: Square) -> Int {
        guard let mover = occupancy[from] else { return 0 }

        var next = occupancy
        var gain = 0
        if let victim = next[to], victim.color != mover.color, victim.kind != .king {
            gain = PieceValues.value(of: victim)
        }
        next.remove(at: to)
        next.remove(at: from)

        var landing = mover
        if mover.kind == .pawn, to.relativeRank(for: mover.color) == 8 {
            landing = Piece(.queen, color: mover.color, square: to)
            gain += PieceValues.queen - PieceValues.pawn
        }
        next.place(landing, at: to)

        return gain - see(next, target: to, side: mover.color.opposite)
    }

    /// Whether `side` has any capture on the board worth more than nothing.
    ///
    /// Used by the detectors' "creates an SEE > 0 attack" clauses.
    public static func hasWinningCapture(position: Position, by side: Piece.Color) -> Bool {
        winningCaptureTargets(position: position, by: side).isEmpty == false
    }

    /// Every enemy-occupied square on which `side` wins material.
    public static func winningCaptureTargets(position: Position, by side: Piece.Color) -> [Square] {
        let occupancy = Occupancy(position)
        return occupancy.pieces(of: side.opposite)
            .filter { $0.kind != .king }
            .map(\.square)
            .filter { see(occupancy, target: $0, side: side) > 0 }
    }

    // MARK: Implementation

    /// The recursive swap: take with the cheapest attacker, then subtract what
    /// the opponent wins back by doing the same. `max(0, …)` encodes the option
    /// to stop capturing, which is what makes the sequence rational.
    static func see(_ occupancy: Occupancy, target: Square, side: Piece.Color) -> Int {
        guard let victim = occupancy[target] else { return 0 }
        // The king can never be captured; a "capture" of it means the position
        // was already illegal.
        guard victim.kind != .king else { return 0 }
        guard let attacker = occupancy.leastValuableAttacker(of: target, by: side) else { return 0 }

        var next = occupancy
        next.remove(at: target)
        next.remove(at: attacker.square)

        // A pawn reaching the last rank promotes; ignoring that would undervalue
        // capture-promotions by 800cp, which is enough to flip a detector.
        var gain = PieceValues.value(of: victim)
        var landing = attacker
        if attacker.kind == .pawn, target.relativeRank(for: side) == 8 {
            landing = Piece(.queen, color: side, square: target)
            gain += PieceValues.queen - PieceValues.pawn
        }
        next.place(landing, at: target)

        // A king may only capture into an undefended square. If the square is
        // still attacked after the capture, the king cannot take at all, so the
        // exchange stops here with no gain.
        if attacker.kind == .king, next.isAttacked(target, by: side.opposite) {
            return 0
        }

        return max(0, gain - see(next, target: target, side: side.opposite))
    }

    /// Shared body of ``seeOfCapture(position:move:)`` and
    /// ``staticExchange(position:move:)``.
    private static func exchangeValue(position: Position, move: Move, captured: Piece?) -> Int {
        var occupancy = Occupancy(position)
        let mover = move.piece

        // Remove the victim from wherever it actually stands — for en passant
        // that is *not* the destination square.
        if let captured { occupancy.remove(at: captured.square) }
        occupancy.remove(at: move.start)

        var gain = captured.map { PieceValues.value(of: $0) } ?? 0
        var landing = Piece(mover.kind, color: mover.color, square: move.end)
        if let promoted = move.promotedPiece {
            landing = Piece(promoted.kind, color: mover.color, square: move.end)
            gain += PieceValues.value(of: promoted.kind) - PieceValues.pawn
        } else if mover.kind == .pawn, move.end.relativeRank(for: mover.color) == 8 {
            landing = Piece(.queen, color: mover.color, square: move.end)
            gain += PieceValues.queen - PieceValues.pawn
        }
        occupancy.place(landing, at: move.end)

        return gain - see(occupancy, target: move.end, side: mover.color.opposite)
    }
}
