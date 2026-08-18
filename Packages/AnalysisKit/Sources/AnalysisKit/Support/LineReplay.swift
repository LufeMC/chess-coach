//
//  LineReplay.swift
//  AnalysisKit
//

import ChessKit

/// One ply of a replayed variation, with everything the detectors ask about it.
public struct ReplayStep: Sendable, Equatable {
    public let ply: Int
    public let move: Move
    public let uci: String
    public let positionBefore: Position
    public let positionAfter: Position
    /// Material the mover won on this ply, in centipawns (0 for a quiet move).
    public let capturedValue: Int
    public let givesCheck: Bool
    public let isCapture: Bool
    public let isPromotion: Bool

    /// A check, a capture or a promotion — the standard "forcing" test.
    public var isForcing: Bool { givesCheck || isCapture || isPromotion }
    public var mover: Piece.Color { move.piece.color }
}

/// Replays engine principal variations (UCI long algebraic) onto real positions.
///
/// Engine PVs arrive as bare strings; almost every detector needs to know
/// whether ply *n* was a check, what it captured, and what the position looked
/// like afterwards. Doing that once, here, keeps the detectors declarative.
public enum LineReplay {

    /// Applies one UCI move, returning the resulting move object and position.
    ///
    /// - returns: `nil` when the move is not legal in `position` — engine lines
    ///   are trusted but a truncated or mismatched PV must not crash analysis.
    public static func apply(uci: String, to position: Position) -> (move: Move, position: Position)? {
        guard uci.count >= 4 else { return nil }
        let characters = Array(uci)
        let start = Square(String(characters[0...1]))
        let end = Square(String(characters[2...3]))

        var board = Board(position: position)
        guard var move = board.move(pieceAt: start, to: end) else { return nil }

        if characters.count == 5, let kind = promotionKind(characters[4]) {
            move = board.completePromotion(of: move, to: kind)
        } else if case .promotion(let pending) = board.state, pending.end == end {
            // An engine may omit the suffix only for illegal input, but a pawn
            // landing on the last rank leaves the board mid-promotion; default to
            // a queen so the board is never left in a half-applied state.
            move = board.completePromotion(of: move, to: .queen)
        }

        return (move, board.position)
    }

    /// Replays up to `maxPlies` of a variation from `position`.
    ///
    /// Stops early (rather than failing) at the first move that does not apply.
    public static func replay(uci line: [String], from position: Position, maxPlies: Int = 10) -> [ReplayStep] {
        var steps: [ReplayStep] = []
        var current = position

        for (index, uci) in line.prefix(maxPlies).enumerated() {
            guard let (move, next) = apply(uci: uci, to: current) else { break }

            let capturedValue: Int
            if case .capture(let piece) = move.result {
                capturedValue = PieceValues.value(of: piece)
            } else {
                capturedValue = 0
            }

            steps.append(
                ReplayStep(
                    ply: index,
                    move: move,
                    uci: uci,
                    positionBefore: current,
                    positionAfter: next,
                    capturedValue: capturedValue,
                    givesCheck: move.checkState == .check || move.checkState == .checkmate,
                    isCapture: capturedValue > 0,
                    isPromotion: move.promotedPiece != nil
                )
            )
            current = next
        }

        return steps
    }

    /// Net material swing over a replayed line, from `mover`'s point of view.
    ///
    /// Positive means `mover` came out ahead. Used as the "does this line
    /// actually win something" test that separates a real tactic from a
    /// forcing-looking shuffle.
    public static func materialSwing(_ steps: [ReplayStep], for mover: Piece.Color) -> Int {
        steps.reduce(0) { total, step in
            step.mover == mover ? total + step.capturedValue : total - step.capturedValue
        }
    }

    /// The first ply index at which `mover`'s running material gain reaches its
    /// final value — i.e. when the tactic has "resolved".
    ///
    /// - returns: A 1-based ply count, or `nil` if the line never wins material.
    public static func resolutionPly(_ steps: [ReplayStep], for mover: Piece.Color) -> Int? {
        let finalSwing = materialSwing(steps, for: mover)
        guard finalSwing > 0 else { return nil }

        var running = 0
        for (index, step) in steps.enumerated() {
            running += step.mover == mover ? step.capturedValue : -step.capturedValue
            if running >= finalSwing { return index + 1 }
        }
        return steps.count
    }

    static func promotionKind(_ character: Character) -> Piece.Kind? {
        switch character.lowercased() {
        case "q": .queen
        case "r": .rook
        case "b": .bishop
        case "n": .knight
        default: nil
        }
    }
}
