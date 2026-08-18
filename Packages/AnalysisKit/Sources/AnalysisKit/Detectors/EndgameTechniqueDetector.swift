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
/// win thrown away is detected exactly rather than inferred from a score.
public struct EndgameTechniqueDetector: Detector, Sendable {
    public let id = DetectorID.endgameTechnique

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        guard context.phase == .endgame else { return [] }

        let flip = ResultClass.classify(context.evalBefore) != ResultClass.classify(context.evalAfter)
        let bitbaseFlip = kpkRegression(context)
        guard context.judgment >= .mistake || flip || bitbaseFlip else { return [] }

        let type = EndgameClassifier.classify(context.positionBefore)
        var flags: Set<FindingFlag> = []
        if flip || bitbaseFlip { flags.insert(.resultClassFlip) }
        if bitbaseFlip || type == .kpk { flags.insert(.exactBitbase) }
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
                detail: "\(type.rawValue) error\(bitbaseFlip ? " (exact KPK: win thrown away)" : "")"
            )
        ]
    }

    /// A KPK position that was won before the move and drawn after it.
    ///
    /// Both probes are taken from the mover's point of view: `probe` answers "does
    /// the pawn's owner win", which only counts as an error when the mover *is*
    /// the pawn's owner.
    private func kpkRegression(_ context: MoveContext) -> Bool {
        guard let before = KPKBitbase.probe(position: context.positionBefore),
            let after = KPKBitbase.probe(position: context.positionAfter)
        else { return false }
        guard let pawn = context.positionBefore.pieces.first(where: { $0.kind == .pawn }) else { return false }
        guard pawn.color == context.mover else { return false }
        return before == .win && after == .draw
    }
}
