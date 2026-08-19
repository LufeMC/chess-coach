//
//  EndgameTechniqueDetector.swift
//  AnalysisKit
//

import ChessKit

/// Flags endgame errors and names the ending they happened in.
///
/// The bar is higher than elsewhere (a mistake, not an inaccuracy) because
/// endgame evaluations wobble: engines routinely rate a drawn ending at +1.5, so
/// small deltas there are noise. The exception is a **result-class flip** — a win
/// turned into a draw is the endgame error that matters most, and it can happen
/// with a modest expected-points change.
///
/// In KPK the engine is bypassed entirely: ``KPKBitbase`` knows the truth, so a
/// result thrown away is detected exactly rather than inferred from a score —
/// from either side of the board, since a defender who lets a draw become a loss
/// has made the same size of error as an attacker who lets a win become a draw.
public struct EndgameTechniqueDetector: Detector, Sendable {
    public let id = DetectorID.endgameTechnique

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard context.phase == .endgame else { return [] }

        let flip = ResultClass.classify(context.evalBefore) != ResultClass.classify(context.evalAfter)
        let bitbaseFlip = kpkRegression(context)
        guard context.judgment >= .mistake || flip || bitbaseFlip != nil else { return [] }

        let type = EndgameClassifier.classify(context.positionBefore)
        var flags: Set<FindingFlag> = []
        if flip || bitbaseFlip != nil { flags.insert(.resultClassFlip) }
        if bitbaseFlip != nil || type == .kpk { flags.insert(.exactBitbase) }
        if type == .rookEndgame {
            if EndgameClassifier.lucenaSignature(context.positionBefore) { flags.insert(.lucenaAvailable) }
            if EndgameClassifier.philidorSignature(context.positionBefore) { flags.insert(.philidorAvailable) }
        }

        return [
            Finding(
                detector: id,
                subtype: type.subtype,
                squares: [context.playedMove.start, context.playedMove.end],
                flags: flags,
                magnitude: context.deltaEP,
                detail: "\(type.rawValue) error\(bitbaseFlip.map { " (exact KPK: \($0.detail))" } ?? "")"
            )
        ]
    }

    /// The two KPK errors the bitbase can prove, from whichever side made them.
    enum KPKRegression: Sendable {
        /// The pawn's owner was winning and let it slip to a draw.
        case winThrownAway
        /// The defender was holding a draw and walked into a loss.
        case drawLost

        var detail: String {
            switch self {
            case .winThrownAway: "win thrown away"
            case .drawLost: "draw walked into a loss"
            }
        }
    }

    /// A KPK position whose exact result changed across the move.
    ///
    /// ``KPKBitbase/probe(position:)`` always answers "does the pawn's owner
    /// win", so which change counts as an error depends on which side moved:
    /// win → draw is the pawn owner failing to convert, draw → win is the
    /// defender failing to hold.
    ///
    /// The defending half is the more valuable of the two. KPK is precisely where
    /// a depth-limited search reports a large positive score for a dead draw, so
    /// the ±200cp `ResultClass` flip that catches result changes everywhere else
    /// is at its least reliable here — a defender who steps onto the wrong square
    /// and loses the opposition changes the game's result while the engine's
    /// number barely moves. The bitbase is the only thing in the pass that can
    /// see it, which is the reason it exists.
    private func kpkRegression(_ context: MoveContext) -> KPKRegression? {
        guard let before = KPKBitbase.probe(position: context.positionBefore),
            let after = KPKBitbase.probe(position: context.positionAfter)
        else { return nil }
        guard let pawn = context.positionBefore.pieces.first(where: { $0.kind == .pawn }) else { return nil }

        if pawn.color == context.mover {
            return before == .win && after == .draw ? .winThrownAway : nil
        }
        return before == .draw && after == .win ? .drawLost : nil
    }
}
