//
//  TacticThemeClassifier.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// The tactical motif a variation turns on.
public enum TacticTheme: String, Sendable, Codable, Hashable, CaseIterable {
    case mateThreat
    case backRankMate
    case fork
    case discoveredAttack
    case pin
    case skewer
    case removalOfDefender
    case trappedPiece
    /// The line wins material but by none of the recognised motifs.
    case unknownTactic
}

/// Names the motif behind a principal variation.
///
/// Strictly first-match-wins in the order mate → fork → discovered attack →
/// pin/skewer → removal of the defender → trapped piece. The order encodes
/// pedagogy, not geometry: a line that mates is taught as a mate even if a fork
/// appears along the way, and a fork is the more useful label than the pin that
/// happens to also exist on the board.
public enum TacticThemeClassifier {

    /// Number of plies of the variation that are examined.
    public static let defaultHorizon = 6
    /// A piece worth at least this much is "material" for fork/pin purposes.
    public static let materialFloor = PieceValues.minorPieceFloor

    public static func classify(
        pv: [String],
        from position: Position,
        score: UCIScore? = nil,
        maxPlies: Int = defaultHorizon
    ) -> TacticTheme {
        let steps = LineReplay.replay(uci: pv, from: position, maxPlies: maxPlies)
        return classify(steps: steps, from: position, score: score, maxPlies: maxPlies)
    }

    static func classify(
        steps: [ReplayStep],
        from position: Position,
        score: UCIScore?,
        maxPlies: Int = defaultHorizon
    ) -> TacticTheme {
        guard let key = steps.first else { return .unknownTactic }
        let mover = key.mover

        if let mate = mateTheme(steps: steps, score: score, maxPlies: maxPlies, mover: mover) {
            return mate
        }

        let before = Occupancy(key.positionBefore)
        let after = Occupancy(key.positionAfter)

        if isFork(after: after, keyMove: key.move, mover: mover) { return .fork }
        if isDiscoveredAttack(before: before, after: after, keyMove: key.move, mover: mover) {
            return .discoveredAttack
        }
        if let alignment = alignmentTheme(before: before, after: after, mover: mover) { return alignment }
        if isRemovalOfDefender(steps: steps, mover: mover) { return .removalOfDefender }
        if isTrappedPiece(steps: steps, mover: mover) { return .trappedPiece }

        return .unknownTactic
    }

    // MARK: Mate

    private static func mateTheme(
        steps: [ReplayStep],
        score: UCIScore?,
        maxPlies: Int,
        mover: Piece.Color
    ) -> TacticTheme? {
        var matingStep: ReplayStep?

        if let last = steps.last, last.move.checkState == .checkmate, last.mover == mover {
            matingStep = last
        }

        // A truncated PV may not reach the mate; trust the score too. `mate n`
        // means n *moves*, i.e. 2n-1 plies for the side delivering it.
        let scoreSaysMate: Bool
        if case .mate(let n) = score, n > 0, 2 * n - 1 <= maxPlies {
            scoreSaysMate = true
        } else {
            scoreSaysMate = false
        }

        guard matingStep != nil || scoreSaysMate else { return nil }
        guard let mate = matingStep else { return .mateThreat }

        return isBackRankMate(mate, mover: mover) ? .backRankMate : .mateThreat
    }

    /// Back rank: the mate lands on the defender's own first rank and the king's
    /// escape squares are blocked by its own pawns.
    private static func isBackRankMate(_ mate: ReplayStep, mover: Piece.Color) -> Bool {
        let defender = mover.opposite
        let occupancy = Occupancy(mate.positionAfter)
        guard let king = occupancy.kingSquare(of: defender) else { return false }
        guard king.relativeRank(for: defender) == 1 else { return false }
        guard mate.move.end.relativeRank(for: defender) == 1 else { return false }

        let forward = defender == .white ? 1 : -1
        var boxedBy = 0
        for fileDelta in -1...1 {
            guard let escape = Square.offset(king, files: fileDelta, ranks: forward) else { continue }
            if let piece = occupancy[escape], piece.color == defender, piece.kind == .pawn { boxedBy += 1 }
        }
        // Two of the three escape squares walled off by the king's own pawns is
        // the picture every "back rank mate" diagram shows.
        return boxedBy >= 2
    }

    // MARK: Fork

    /// The moved piece now attacks two or more valuable targets, at least one of
    /// which can actually be taken without losing material.
    static func isFork(after: Occupancy, keyMove: Move, mover: Piece.Color) -> Bool {
        let targets = after.attackedSquares(from: keyMove.end)
            .compactMap { square -> Square? in
                guard let piece = after[square], piece.color == mover.opposite else { return nil }
                guard PieceValues.value(of: piece) >= materialFloor || piece.kind == .king else { return nil }
                return square
            }
        guard Set(targets).count >= 2 else { return false }

        return targets.contains { target in
            guard after[target]?.kind != .king else { return true }
            return SEE.exchangeValue(occupancy: after, from: keyMove.end, to: target) >= 0
        }
    }

    // MARK: Discovered attack

    /// The key move vacated a square a friendly slider was firing through.
    static func isDiscoveredAttack(
        before: Occupancy,
        after: Occupancy,
        keyMove: Move,
        mover: Piece.Color
    ) -> Bool {
        let vacated = keyMove.start

        for slider in after.pieces(of: mover) where isSlider(slider.kind) {
            guard slider.square != keyMove.end else { continue }
            guard let direction = after.direction(from: slider.square, to: vacated) else { continue }
            guard after.directions(for: slider.kind).contains(where: { $0 == direction }) else { continue }
            // The vacated square must have been the blocker: nothing else may
            // stand between the slider and it.
            guard before.firstOccupied(from: slider.square, direction: direction)?.0 == vacated else { continue }
            guard let (targetSquare, target) = after.firstOccupied(from: slider.square, direction: direction) else {
                continue
            }
            guard targetSquare != vacated, target.color == mover.opposite else { continue }
            if target.kind == .king || PieceValues.value(of: target) >= materialFloor { return true }
        }

        return false
    }

    // MARK: Pin and skewer

    /// A friendly slider newly lined up through two enemy pieces.
    ///
    /// Pin when the piece behind is worth more (the front piece dare not move),
    /// skewer when the piece in front is worth more (it must move and exposes the
    /// one behind).
    static func alignmentTheme(before: Occupancy, after: Occupancy, mover: Piece.Color) -> TacticTheme? {
        let existing = alignments(in: before, mover: mover)
        for alignment in alignments(in: after, mover: mover) where !existing.contains(alignment) {
            let front = PieceValues.value(of: alignment.front)
            let back = PieceValues.value(of: alignment.back)
            guard max(front, back) >= materialFloor else { continue }
            if back > front { return .pin }
            if front > back { return .skewer }
        }
        return nil
    }

    private struct Alignment: Hashable {
        let slider: Square
        let frontSquare: Square
        let backSquare: Square
        let front: Piece.Kind
        let back: Piece.Kind
    }

    private static func alignments(in occupancy: Occupancy, mover: Piece.Color) -> Set<Alignment> {
        var result: Set<Alignment> = []
        for slider in occupancy.pieces(of: mover) where isSlider(slider.kind) {
            for direction in occupancy.directions(for: slider.kind) {
                guard let (frontSquare, front) = occupancy.firstOccupied(from: slider.square, direction: direction),
                    front.color == mover.opposite
                else { continue }
                guard let (backSquare, back) = occupancy.firstOccupied(from: frontSquare, direction: direction),
                    back.color == mover.opposite
                else { continue }
                result.insert(
                    Alignment(
                        slider: slider.square,
                        frontSquare: frontSquare,
                        backSquare: backSquare,
                        front: front.kind,
                        back: back.kind
                    )
                )
            }
        }
        return result
    }

    // MARK: Removal of the defender

    /// The key move captures a defender, and once the dust settles the piece it
    /// was protecting can be taken for profit.
    static func isRemovalOfDefender(steps: [ReplayStep], mover: Piece.Color) -> Bool {
        guard let key = steps.first, case .capture(let defender) = key.move.result else { return false }

        let before = Occupancy(key.positionBefore)
        let guarded = before.attackedSquares(from: defender.square).filter { square in
            guard let piece = before[square] else { return false }
            return piece.color == defender.color && PieceValues.value(of: piece) >= PieceValues.pawn
        }
        guard !guarded.isEmpty else { return false }

        // Look at the position after the opponent has had their reply; a defender
        // removal that the opponent simply repairs is not the theme.
        let settled = steps.count >= 2 ? steps[1].positionAfter : key.positionAfter
        let occupancy = Occupancy(settled)

        return guarded.contains { square in
            guard let piece = occupancy[square], piece.color == mover.opposite else { return false }
            return SEE.see(occupancy, target: square, side: mover) > 0
        }
    }

    // MARK: Trapped piece

    /// An enemy piece is attacked and every square it can run to loses material.
    static func isTrappedPiece(steps: [ReplayStep], mover: Piece.Color) -> Bool {
        guard let key = steps.first else { return false }
        let position = key.positionAfter
        let occupancy = Occupancy(position)
        let board = Board(position: position)

        for target in occupancy.pieces(of: mover.opposite)
        where target.kind != .king && PieceValues.value(of: target) >= materialFloor {
            guard occupancy.isAttacked(target.square, by: mover) else { continue }
            guard SEE.see(occupancy, target: target.square, side: mover) > 0 else { continue }

            let escapes = board.legalMoves(forPieceAt: target.square)
            let allEscapesLose = escapes.allSatisfy {
                SEE.exchangeValue(occupancy: occupancy, from: target.square, to: $0) < 0
            }
            if allEscapesLose { return true }
        }

        return false
    }

    // MARK: Helpers

    static func isSlider(_ kind: Piece.Kind) -> Bool {
        kind == .bishop || kind == .rook || kind == .queen
    }
}
