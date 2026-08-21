//
//  Finding.swift
//  AnalysisKit
//

import ChessKit

/// Which detector produced a finding.
public enum DetectorID: String, Sendable, Codable, CaseIterable {
    case hangingPiece
    case ignoredThreat
    case missedTactic
    case allowedTactic
    case wrongTrade
    case kingWeakeningPawnMove
    case missedQuietMove
    case openingPrinciple
    case endgameTechnique
    case timeError
}

/// The flavour of a finding. One flat namespace across detectors keeps `Finding`
/// a plain value type; each case is only ever produced by one detector.
public enum FindingSubtype: String, Sendable, Codable, CaseIterable {
    // hangingPiece
    case moved
    case left
    // ignoredThreat
    case newThreat = "new"
    case standingThreat = "standing"
    // missedTactic
    case playedForcing
    case playedQuiet
    // allowedTactic
    case shallow
    case deep
    // wrongTrade
    case losesMaterial
    case badSimplification
    // kingWeakeningPawnMove
    case tacticalPunish
    case positional
    // missedQuietMove
    case retreat
    case prophylactic
    case improvement
    // openingPrinciple
    case earlyQueen
    case repeatedPieceMove
    case delayedCastling
    case centreNeglect
    case disconnectedRooks
    // endgameTechnique
    case kpk
    case basicMate
    case pawnEndgame
    case rookEndgame
    case otherEndgame
    // timeError
    case impulseAtCritical
    case blunderAfterLongThink
    case clockPressure
    case flagged
}

/// Extra boolean facts a detector observed, which the cause tagger's decision
/// table keys off. Kept as flags rather than more subtypes so a finding can
/// carry several at once.
public enum FindingFlag: String, Sendable, Codable, Hashable, CaseIterable {
    /// The opponent's best reply captures the piece this finding is about.
    case refutationCapturesTarget
    /// The opponent's best reply is a check, capture or promotion.
    case refutationIsForcing
    /// The move the player actually made was a check, capture or promotion.
    case playedMoveForcing
    /// The engine's best move is quiet (no check, capture, promotion, and it
    /// creates no winning capture).
    case bestMoveQuiet
    /// The evaluation crossed a win/draw/loss boundary.
    case resultClassFlip
    /// The rook ending shows the Lucena (winning) building-a-bridge signature.
    case lucenaAvailable
    /// The rook ending shows the Philidor (drawing) third-rank-defence signature.
    case philidorAvailable
    /// An exact KPK bitbase probe was used rather than the engine's evaluation.
    case exactBitbase
}

/// One structured observation about a single move.
public struct Finding: Sendable, Equatable, Hashable, Codable {
    public let detector: DetectorID
    public let subtype: FindingSubtype
    /// Squares the finding is about — the hanging piece, the threatened square,
    /// the trapped piece. Ordered most-relevant first.
    public let squares: [Square]
    /// Tactical themes attached to the line this finding refers to.
    public let themes: [TacticTheme]
    public let flags: Set<FindingFlag>
    /// A detector-specific magnitude, for ranking and explanation: centipawns
    /// for material findings, expected points for evaluation findings.
    public let magnitude: Double
    /// Short human-readable justification, for debugging and coach copy.
    public let detail: String

    public init(
        detector: DetectorID,
        subtype: FindingSubtype,
        squares: [Square] = [],
        themes: [TacticTheme] = [],
        flags: Set<FindingFlag> = [],
        magnitude: Double = 0,
        detail: String = ""
    ) {
        self.detector = detector
        self.subtype = subtype
        self.squares = squares
        self.themes = themes
        self.flags = flags
        self.magnitude = magnitude
        self.detail = detail
    }

    /// Stable identifier used for secondary tags and de-duplication.
    public var tagKey: String { "\(detector.rawValue).\(subtype.rawValue)" }
}

/// A pure function from one move's context to zero or more findings.
///
/// Detectors never share state and never perform I/O: everything they need
/// arrives in the ``MoveContext``, which is what makes the whole layer testable
/// from a FEN plus a canned engine result.
public protocol Detector: Sendable {
    var id: DetectorID { get }
    func detect(_ context: MoveContext) -> [Finding]
}
