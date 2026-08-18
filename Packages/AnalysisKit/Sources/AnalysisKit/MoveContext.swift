//
//  MoveContext.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// The result of a null-move threat probe.
///
/// The caller runs the engine on ``fen`` (produced by ``NullMove/probeFEN(for:)``)
/// and hands the answer back. AnalysisKit never touches the engine itself.
public struct ThreatProbe: Sendable, Equatable {
    /// The null-moved position that was searched.
    public let fen: String
    /// The threatening side's best move, in UCI.
    public let bestMove: String?
    /// Score from the **threatening side's** perspective (they are to move in
    /// the probe position).
    public let score: UCIScore
    public let pv: [String]

    public init(fen: String, bestMove: String?, score: UCIScore, pv: [String] = []) {
        self.fen = fen
        self.bestMove = bestMove
        self.score = score
        self.pv = pv
    }

    /// Expected points for the threatening side if they got the free move.
    public var expectedPoints: Double { EvalMath.expectedPoints(score: score) }
}

/// Everything the detectors need about one played move.
///
/// ## Perspective contract
///
/// `evalBefore` and `evalAfter` are both **mover-relative**: positive means good
/// for the player who made the move. The engine's own score for the position
/// after the move belongs to the opponent, so the initialiser negates it for you
/// — pass the raw engine output and do not pre-flip it.
public struct MoveContext: Sendable {

    // MARK: Stored

    /// 1-based half-move number: White's first move is ply 1.
    public let ply: Int
    public let positionBefore: Position
    public let positionAfter: Position
    public let playedMove: Move
    public let playedUCI: String

    /// MultiPV rank 1 for `positionBefore` (mover-relative).
    public let bestLine: UCIInfo
    /// MultiPV rank 2 for `positionBefore`, if searched.
    public let secondLine: UCIInfo?
    /// The opponent's best line in `positionAfter` — the refutation of the move
    /// actually played. Opponent-relative.
    public let refutationLine: UCIInfo?

    /// Mover-relative evaluation before the move.
    public let evalBefore: UCIScore
    /// Mover-relative evaluation after the move.
    public let evalAfter: UCIScore
    /// `EP(before) - EP(after)`, positive when the mover lost ground.
    public let deltaEP: Double

    public let thinkTimeMs: Int?
    public let timeControl: TimeControl?
    public let phase: Phase
    public let clockPressure: Bool
    /// The player ran out of time on this move.
    public let didFlag: Bool

    /// Null-move probe taken in `positionBefore` (what was the opponent
    /// threatening before the move was played).
    public let threatProbe: ThreatProbe?
    /// The same probe taken one opponent move earlier, used to tell a new threat
    /// from a standing one.
    public let previousThreatProbe: ThreatProbe?

    public let criticality: CriticalityResult?
    /// Every move played earlier in the game, both colours, in order.
    public let priorMoves: [Move]
    /// Square the opponent captured on with their previous move, if any.
    public let lastCaptureSquare: Square?
    /// A coaching prompt was shown at this position and the player still erred.
    public let guidedPromptShown: Bool

    /// Replay of `bestLine.pv` from `positionBefore`.
    public let bestLineSteps: [ReplayStep]
    /// Replay of `refutationLine.pv` from `positionAfter`.
    public let refutationSteps: [ReplayStep]

    // MARK: Derived

    public var mover: Piece.Color { playedMove.piece.color }
    public var opponent: Piece.Color { mover.opposite }
    public var judgment: Judgment { EvalMath.judgment(deltaEP: deltaEP) }
    public var boardBefore: Board { Board(position: positionBefore) }
    public var boardAfter: Board { Board(position: positionAfter) }
    public var isCritical: Bool { criticality?.isCritical ?? false }
    public var criticalityGap: Double { criticality?.gap ?? 0 }

    public var thinkBucket: ThinkBucket? {
        thinkTimeMs.map { ThinkBucket.classify(thinkTimeMs: $0, control: timeControl) }
    }

    /// Lichess move accuracy (0...100) for this move.
    ///
    /// Both win percentages come from the mover-relative scores, which is the
    /// only correct way to feed the accuracy curve — hence computing it here
    /// rather than leaving each call site to remember the flip.
    public var accuracy: Double {
        EvalMath.accuracy(
            winPctBefore: EvalMath.winPercent(score: evalBefore),
            winPctAfter: EvalMath.winPercent(score: evalAfter)
        )
    }

    /// Whether the player found the engine's move.
    public var playedBestMove: Bool { bestLine.pv.first == playedUCI }

    /// The engine's best move for `positionBefore`, if it applies legally.
    public var bestMove: Move? { bestLineSteps.first?.move }
    /// The opponent's refutation move, if any.
    public var refutationMove: Move? { refutationSteps.first?.move }

    public var playedMoveIsForcing: Bool {
        let isCapture: Bool = if case .capture = playedMove.result { true } else { false }
        let givesCheck = playedMove.checkState == .check || playedMove.checkState == .checkmate
        return isCapture || givesCheck || playedMove.promotedPiece != nil
    }

    /// Quiet means: no check, no capture, no promotion, and it does not leave a
    /// winning capture on the board. The last clause matters — "Nd5 attacking a
    /// loose rook" is not a quiet move in any coaching sense.
    public var bestMoveIsQuiet: Bool {
        guard let step = bestLineSteps.first else { return false }
        if step.isForcing { return false }
        return !SEE.hasWinningCapture(position: step.positionAfter, by: mover)
    }

    // MARK: Init

    /// Builds a context from raw engine output.
    ///
    /// - parameter evalAfterEngine: The engine's score for the position *after*
    ///   the move, exactly as reported — i.e. from the **opponent's**
    ///   perspective. It is negated here so that everything downstream is
    ///   mover-relative. If a refutation line is supplied and this is omitted,
    ///   the refutation's own score is used.
    /// - returns: `nil` when `playedUCI` is not legal in `positionBefore`.
    public init?(
        ply: Int,
        positionBefore: Position,
        playedUCI: String,
        bestLine: UCIInfo,
        secondLine: UCIInfo? = nil,
        refutationLine: UCIInfo? = nil,
        evalBefore: UCIScore? = nil,
        evalAfterEngine: UCIScore? = nil,
        thinkTimeMs: Int? = nil,
        timeControl: TimeControl? = nil,
        clockPressure: Bool = false,
        didFlag: Bool = false,
        threatProbe: ThreatProbe? = nil,
        previousThreatProbe: ThreatProbe? = nil,
        criticality: CriticalityResult? = nil,
        priorMoves: [Move] = [],
        lastCaptureSquare: Square? = nil,
        guidedPromptShown: Bool = false,
        phase: Phase? = nil
    ) {
        guard let applied = LineReplay.apply(uci: playedUCI, to: positionBefore) else { return nil }

        self.ply = ply
        self.positionBefore = positionBefore
        self.positionAfter = applied.position
        self.playedMove = applied.move
        self.playedUCI = playedUCI
        self.bestLine = bestLine
        self.secondLine = secondLine
        self.refutationLine = refutationLine

        let before = evalBefore ?? bestLine.score
        // The single place the after-move sign flip happens. Everything that
        // reads `evalAfter` can rely on it being mover-relative.
        let rawAfter = evalAfterEngine ?? refutationLine?.score ?? before.negated
        let after = Perspective.moverRelativeAfterMove(rawAfter)

        self.evalBefore = before
        self.evalAfter = after
        self.deltaEP = EvalMath.deltaEP(before: before, after: after)

        self.thinkTimeMs = thinkTimeMs
        self.timeControl = timeControl
        self.phase = phase ?? Phase.classify(position: positionBefore, ply: ply)
        self.clockPressure = clockPressure
        self.didFlag = didFlag
        self.threatProbe = threatProbe
        self.previousThreatProbe = previousThreatProbe
        self.criticality = criticality
        self.priorMoves = priorMoves
        self.lastCaptureSquare = lastCaptureSquare
        self.guidedPromptShown = guidedPromptShown

        self.bestLineSteps = LineReplay.replay(uci: bestLine.pv, from: positionBefore, maxPlies: 10)
        self.refutationSteps = LineReplay.replay(
            uci: refutationLine?.pv ?? [],
            from: applied.position,
            maxPlies: 10
        )
    }
}
