//
//  Fixture.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit

@testable import AnalysisKit

enum FixtureError: Error {
    case invalidFEN(String)
    case illegalMove(String)
}

/// Builds ``MoveContext`` values from FENs and canned engine output.
///
/// The whole point of AnalysisKit taking value types in and out is that a
/// detector can be exercised without an engine; this is the helper that makes
/// that ergonomic.
enum Fixture {

    static func position(_ fen: String) throws -> Position {
        guard let position = Position(fen: fen) else { throw FixtureError.invalidFEN(fen) }
        return position
    }

    static func move(_ uci: String, in fen: String) throws -> Move {
        let position = try position(fen)
        guard let applied = LineReplay.apply(uci: uci, to: position) else {
            throw FixtureError.illegalMove(uci)
        }
        return applied.move
    }

    /// - parameter refutationScore: The engine's score for the position *after*
    ///   the played move, as reported — i.e. from the opponent's point of view.
    ///   Positive means the opponent is better, which is what makes the move bad.
    static func context(
        fen: String,
        ply: Int = 21,
        played: String,
        best: [String] = [],
        bestScore: UCIScore = .centipawns(0),
        second: [String]? = nil,
        secondScore: UCIScore = .centipawns(0),
        refutation: [String] = [],
        refutationScore: UCIScore? = nil,
        thinkTimeMs: Int? = nil,
        timeControl: TimeControl? = nil,
        clockPressure: Bool = false,
        didFlag: Bool = false,
        threatProbe: ThreatProbe? = nil,
        previousThreatProbe: ThreatProbe? = nil,
        criticality: CriticalityResult? = nil,
        priorMoves: [Move] = [],
        lastCaptureSquare: Square? = nil,
        guidedPromptShown: Bool = false
    ) throws -> MoveContext {
        let position = try position(fen)
        let bestLine = UCIInfo(multipv: 1, depth: 20, score: bestScore, pv: best)
        let secondLine = second.map { UCIInfo(multipv: 2, depth: 20, score: secondScore, pv: $0) }
        let refutationLine = refutation.isEmpty && refutationScore == nil
            ? nil
            : UCIInfo(multipv: 1, depth: 20, score: refutationScore ?? bestScore.negated, pv: refutation)

        guard let context = MoveContext(
            ply: ply,
            positionBefore: position,
            playedUCI: played,
            bestLine: bestLine,
            secondLine: secondLine,
            refutationLine: refutationLine,
            evalBefore: bestScore,
            evalAfterEngine: refutationScore,
            thinkTimeMs: thinkTimeMs,
            timeControl: timeControl,
            clockPressure: clockPressure,
            didFlag: didFlag,
            threatProbe: threatProbe,
            previousThreatProbe: previousThreatProbe,
            criticality: criticality,
            priorMoves: priorMoves,
            lastCaptureSquare: lastCaptureSquare,
            guidedPromptShown: guidedPromptShown
        ) else {
            throw FixtureError.illegalMove(played)
        }
        return context
    }

    /// A moment with only the fields the selector reads, so selection tests do
    /// not have to invent an engine result.
    static func moment(
        ply: Int,
        causeTag: CauseTag,
        total: Double,
        kind: MomentKind = .mistake
    ) -> Moment {
        // `total` is severity × learnability × relevance; keep the other two at 1
        // so the caller controls the product directly.
        Moment(
            ply: ply,
            phase: .middlegame,
            fenBefore: Position.standard.fen,
            sideToMove: .white,
            playedSAN: "e4",
            playedUCI: "e2e4",
            bestSAN: "d4",
            bestUCI: "d2d4",
            cpBefore: 0,
            cpAfter: -100,
            winPctBefore: 50,
            winPctAfter: 40,
            deltaEP: 0.1,
            judgment: .inaccuracy,
            criticalityGap: 0.15,
            detector: nil,
            causeTag: causeTag,
            stepTag: .s3Candidates,
            score: MomentScore(severity: total, learnability: 1, relevance: 1),
            kind: kind,
            srsEligible: true
        )
    }
}
