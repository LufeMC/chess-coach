//
//  PipelineTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

/// End-to-end: detectors → cause tagger → moment → selection, on a position
/// every beginner recognises.
@Suite("Analysis pipeline")
struct PipelineTests {

    /// After 1.f3 e5, Black is already threatening Qh4. 2.g4?? allows mate.
    private let foolsMate = "rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2"

    private func context() throws -> MoveContext {
        let position = try Fixture.position(foolsMate)
        let probeFEN = try #require(NullMove.probeFEN(for: position))
        return try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "g2g4",
            best: ["b1c3"],
            bestScore: .centipawns(20),
            second: ["e2e4"],
            secondScore: .centipawns(-10),
            refutation: ["d8h4"],
            refutationScore: .mate(1),
            thinkTimeMs: 1_500,
            timeControl: .blitz5plus0,
            threatProbe: ThreatProbe(
                fen: probeFEN,
                bestMove: "d8h4",
                score: .centipawns(400),
                pv: ["d8h4"]
            ),
            criticality: CriticalityResult(isCritical: true, gap: 0.12, suppressedBy: nil)
        )
    }

    @Test("Fool's mate is diagnosed as a missed threat, not just a blunder")
    func diagnosis() throws {
        let context = try context()
        #expect(context.judgment == .blunder)
        // A slightly better than equal position turned into being mated: the
        // mover loses every one of their expected points and then some.
        #expect(context.deltaEP > 0.5)

        let findings = DetectorSuite.run(context)
        #expect(findings.contains { $0.detector == .ignoredThreat && $0.subtype == .newThreat })
        #expect(findings.contains { $0.detector == .allowedTactic && $0.subtype == .shallow })

        let mistake = CauseTagger.tag(findings: findings, context: context)
        // The threat outranks the tactic it allowed: the lesson is that Black's
        // idea was already on the board before the move was played.
        #expect(mistake.causeTag == .missedNewThreat)
        #expect(mistake.stepTag == .s1WhatChanged)
        #expect(mistake.secondaryTags.contains("allowedTactic.shallow"))
        // S1 is upstream of calculation, so the impulse overlay leaves it alone
        // even though the move was fast and the position critical.
        #expect(mistake.modifiers.isEmpty)
    }

    @Test("The diagnosis becomes a selectable moment")
    func moment() throws {
        let context = try context()
        let findings = DetectorSuite.run(context)
        let mistake = CauseTagger.tag(findings: findings, context: context)
        let moment = MomentBuilder.make(
            context: context,
            findings: findings,
            mistake: mistake,
            policy: MomentPolicy(weeklyFocusTags: [.missedNewThreat])
        )

        #expect(moment.causeTag == .missedNewThreat)
        #expect(moment.playedSAN == "g4")
        #expect(moment.winPctBefore > moment.winPctAfter)
        #expect(moment.winPctAfter == 0)
        #expect(moment.mateAfter == -1)
        #expect(moment.score.severity == 1.0)
        #expect(moment.score.relevance == 2.0)
        #expect(moment.total > 0)

        let selected = MomentSelector.select(candidates: [moment])
        #expect(selected.count == 1)
        #expect(selected.first?.causeTag == .missedNewThreat)
    }

    @Test("The detector suite runs in a stable order")
    func deterministicOrder() throws {
        let context = try context()
        let first = DetectorSuite.run(context).map(\.tagKey)
        let second = DetectorSuite.run(context).map(\.tagKey)
        #expect(first == second)
        #expect(first.first == "ignoredThreat.new")
    }

    @Test("A sound move produces no mistake worth showing")
    func soundMove() throws {
        let context = try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "e2e4",
            best: ["e2e4"],
            bestScore: .centipawns(20),
            refutationScore: .centipawns(-20)
        )
        let findings = DetectorSuite.run(context)
        #expect(findings.isEmpty)
        #expect(CauseTagger.tag(findings: findings, context: context).causeTag == .generic)
    }
}
