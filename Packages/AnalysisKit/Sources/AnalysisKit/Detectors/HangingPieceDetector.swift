//
//  HangingPieceDetector.swift
//  AnalysisKit
//

import ChessKit

/// Finds pieces the played move left en prise.
///
/// Two confirmations keep this honest. A raw "SEE says this is capturable" scan
/// fires constantly on positions where the capture is met by a stronger reply,
/// so a candidate only becomes a finding when the opponent's own best move takes
/// it, or when the evaluation actually dropped. Pawns are held to the higher bar
/// of an inaccuracy or worse, because a deliberately offered pawn is a normal
/// part of chess and a coach flagging every one of them is noise.
///
/// Those two confirmations are not equally strong, and the difference is carried
/// out of here on ``FindingFlag/refutationCapturesTarget``. Only the first says
/// the engine took the piece; the second says the move cost something while a
/// static count — blind to pins, checks and desperados — liked the capture. The
/// copy layer keeps them apart, and a sentence claiming the piece simply falls
/// is written only for the flagged path: see ``MomentFacts/engineTakesTarget``.
public struct HangingPieceDetector: Detector, Sendable {
    public let id = DetectorID.hangingPiece

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        let occupancy = Occupancy(context.positionAfter)
        let refutationTarget = context.refutationMove?.end
        var findings: [Finding] = []

        for piece in occupancy.pieces(of: context.mover) where piece.kind != .king {
            let value = PieceValues.value(of: piece)
            let gain = SEE.see(occupancy, target: piece.square, side: context.opponent)
            guard gain > 0 else { continue }

            let capturedByRefutation = refutationTarget == piece.square
            guard capturedByRefutation || context.deltaEP >= EvalMath.inaccuracyThreshold else { continue }

            // A pawn "hangs" all the time — gambits, pawn races, and any position
            // where recapturing costs a tempo. Only count them once the move
            // demonstrably cost something.
            if value < PieceValues.minorPieceFloor, context.judgment < .inaccuracy { continue }

            let subtype: FindingSubtype = piece.square == context.playedMove.end ? .moved : .left
            var flags: Set<FindingFlag> = []
            if capturedByRefutation { flags.insert(.refutationCapturesTarget) }
            if context.playedMoveIsForcing { flags.insert(.playedMoveForcing) }

            findings.append(
                Finding(
                    detector: id,
                    subtype: subtype,
                    squares: [piece.square],
                    flags: flags,
                    magnitude: Double(gain),
                    detail: "\(piece.kind.description) on \(piece.square.notation) can be won for \(gain)cp"
                )
            )
        }

        // Biggest loss first: if a move hangs two things, the queen is the story.
        return findings.sorted { $0.magnitude > $1.magnitude }
    }
}
