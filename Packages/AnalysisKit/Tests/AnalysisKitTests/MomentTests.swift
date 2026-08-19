//
//  MomentTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Moment scoring")
struct MomentBuilderTests {

    private func context() throws -> MoveContext {
        try Fixture.context(
            fen: "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1",
            ply: 21,
            played: "e1e2",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            second: ["e1e2"],
            secondScore: .centipawns(100),
            refutationScore: .centipawns(30),
            thinkTimeMs: 2_000,
            criticality: CriticalityResult(isCritical: true, gap: 0.15, suppressedBy: nil)
        )
    }

    @Test("A moment carries the position, the lines and the diagnosis")
    func fields() throws {
        let context = try context()
        let findings = DetectorSuite.run(context)
        let mistake = CauseTagger.tag(findings: findings, context: context)
        let moment = MomentBuilder.make(context: context, findings: findings, mistake: mistake)

        #expect(moment.ply == 21)
        #expect(moment.fenBefore == context.positionBefore.fen)
        #expect(moment.sideToMove == .white)
        #expect(moment.playedUCI == "e1e2")
        #expect(moment.playedSAN == "Ke2")
        #expect(moment.bestUCI == "b5c7")
        #expect(moment.bestSAN == "Nc7+")
        #expect(moment.cpBefore == 400)
        #expect(moment.pvBest == ["b5c7", "e8e7", "c7a8"])
        #expect(moment.pvAlt == ["e1e2"])
        #expect(moment.themeTags.contains(.fork))
        #expect(moment.kind == .mistake)
        #expect(moment.judgment >= .inaccuracy)
    }

    @Test("Severity saturates at half a point of expected points")
    func severity() throws {
        let context = try context()
        let mistake = CauseTagger.tag(findings: [], context: context)
        let moment = MomentBuilder.make(context: context, findings: [], mistake: mistake)
        #expect(abs(moment.score.severity - min(context.deltaEP, 0.5) / 0.5) < 1e-12)
        #expect(moment.score.severity <= 1.0)
    }

    @Test("Clarity is the criticality gap, floored at 0.3 and capped at 1")
    func clarity() throws {
        // Gap 0.15 saturates clarity; the three-ply solution keeps brevity at 1.
        let context = try context()
        let mistake = CauseTagger.tag(findings: [], context: context)
        let moment = MomentBuilder.make(context: context, findings: [], mistake: mistake)
        #expect(abs(moment.score.learnability - 1.0) < 1e-12)
    }

    @Test("Longer solutions are less learnable")
    func brevity() {
        #expect(MomentBuilder.brevity(1) == 1.0)
        #expect(MomentBuilder.brevity(4) == 1.0)
        #expect(MomentBuilder.brevity(5) == 0.8)
        #expect(MomentBuilder.brevity(6) == 0.8)
        #expect(MomentBuilder.brevity(7) == 0.6)
    }

    /// Relevance takes the maximum of the tiers, not the product — a moment that
    /// is both the weekly focus and a rung skill is relevant once.
    @Test("Relevance takes the highest matching tier")
    func relevance() throws {
        let context = try context()
        let both = MomentPolicy(weeklyFocusTags: [.hungMovedPiece], currentRungTags: [.hungMovedPiece])
        #expect(
            MomentBuilder.relevanceScore(causeTag: .hungMovedPiece, context: context, policy: both) == 2.0
        )

        let rungOnly = MomentPolicy(currentRungTags: [.hungMovedPiece])
        #expect(
            MomentBuilder.relevanceScore(causeTag: .hungMovedPiece, context: context, policy: rungOnly) == 1.5
        )

        #expect(
            MomentBuilder.relevanceScore(causeTag: .hungMovedPiece, context: context, policy: .none) == 1.0
        )
    }

    @Test("Erring after a guided prompt multiplies relevance")
    func guidedPrompt() throws {
        let context = try Fixture.context(
            fen: "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1",
            played: "e1e2",
            best: ["b5c7"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(30),
            guidedPromptShown: true
        )
        let policy = MomentPolicy(weeklyFocusTags: [.hungMovedPiece])
        #expect(
            abs(
                MomentBuilder.relevanceScore(causeTag: .hungMovedPiece, context: context, policy: policy)
                    - 2.5
            ) < 1e-12
        )
        #expect(
            abs(MomentBuilder.relevanceScore(causeTag: .generic, context: context, policy: policy) - 1.25)
                < 1e-12
        )
    }

    @Test("Candidate predicates gate mistakes and praise")
    func candidates() throws {
        let mistake = try context()
        #expect(MomentBuilder.isMistakeCandidate(mistake))
        #expect(MomentBuilder.isReinforcementCandidate(mistake) == false)

        // Same position, but the player found the engine's move in a position
        // that genuinely branched.
        let found = try Fixture.context(
            fen: "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1",
            played: "b5c7",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(-400),
            criticality: CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)
        )
        #expect(found.playedBestMove)
        #expect(MomentBuilder.isReinforcementCandidate(found))
        #expect(MomentBuilder.isMistakeCandidate(found) == false)
    }

    @Test("Move accuracy uses mover-relative win percentages")
    func moveAccuracy() throws {
        let context = try context()
        let expected = EvalMath.accuracy(
            winPctBefore: EvalMath.winPercent(score: context.evalBefore),
            winPctAfter: EvalMath.winPercent(score: context.evalAfter)
        )
        #expect(context.accuracy == expected)
        #expect(context.accuracy < 100)
        #expect(context.accuracy >= 0)
    }

    /// Several detectors can fire on a move the player got *right*: a piece can
    /// sit en prise behind a refutation the opponent never plays, and an exact
    /// endgame result can change under the engine's own first choice. The cause
    /// tagger has no vocabulary for "this was good", so it answers with an error
    /// label — which must not reach a moment the review screen captions as
    /// praise, or the coach that writes the copy from it.
    @Test("A reinforcement never carries a mistake's diagnosis")
    func reinforcementIsNotDiagnosed() throws {
        let context = try Fixture.context(
            fen: "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1",
            played: "b5c7",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(-400),
            thinkTimeMs: 1_000,
            criticality: CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)
        )
        #expect(MomentBuilder.isReinforcementCandidate(context))

        let diagnosis = Mistake(
            causeTag: .hungMovedPiece,
            stepTag: .s5BlunderCheck,
            modifiers: [MistakeModifier.impulse.rawValue, MistakeModifier.clockPressure.rawValue],
            secondaryTags: ["openingPrinciple.delayedCastling"],
            severity: 0.4
        )

        let praise = MomentBuilder.make(
            context: context,
            findings: [],
            mistake: diagnosis,
            kind: .reinforcement
        )
        #expect(praise.causeTag == .generic)
        #expect(praise.stepTag == .s3Candidates)
        #expect(praise.secondaryTags.isEmpty)
        // Finding the move with seconds left is part of the praise. "Impulse" is
        // a verdict on an error and has no business on one.
        #expect(praise.modifiers == [MistakeModifier.clockPressure.rawValue])
        #expect(praise.srsEligible == false)

        // The identical inputs judged as a mistake keep the whole diagnosis.
        let mistake = MomentBuilder.make(
            context: context,
            findings: [],
            mistake: diagnosis,
            kind: .mistake
        )
        #expect(mistake.causeTag == .hungMovedPiece)
        #expect(mistake.stepTag == .s5BlunderCheck)
        #expect(mistake.secondaryTags == ["openingPrinciple.delayedCastling"])
    }

    /// Relevance is scored from the tag the moment actually carries, so praise
    /// cannot borrow the weekly-focus weighting of an error label it does not
    /// have — which would let it outrank the mistakes it is supposed to yield to.
    @Test("A reinforcement does not inherit the focus weighting of a cause it dropped")
    func reinforcementRelevanceIsNeutral() throws {
        let context = try Fixture.context(
            fen: "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1",
            played: "b5c7",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(-400),
            criticality: CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)
        )
        let moment = MomentBuilder.make(
            context: context,
            findings: [],
            mistake: Mistake(causeTag: .hungMovedPiece, stepTag: .s5BlunderCheck, severity: 0.4),
            policy: MomentPolicy(weeklyFocusTags: [.hungMovedPiece]),
            kind: .reinforcement
        )
        #expect(moment.score.relevance == 1.0)
    }

    @Test("Knowledge-shaped and vague causes do not become flashcards")
    func srsEligibility() {
        let drillable = Mistake(causeTag: .hungMovedPiece, stepTag: .s5BlunderCheck, severity: 0.3)
        #expect(MomentBuilder.isSRSEligible(kind: .mistake, mistake: drillable, solutionPlies: 3, gap: 0.2))
        #expect(
            MomentBuilder.isSRSEligible(kind: .reinforcement, mistake: drillable, solutionPlies: 3, gap: 0.2)
                == false
        )
        #expect(
            MomentBuilder.isSRSEligible(kind: .mistake, mistake: drillable, solutionPlies: 9, gap: 0.2) == false
        )

        let knowledge = Mistake(causeTag: .openingPrinciple, stepTag: .kKnowledge, severity: 0.3)
        #expect(
            MomentBuilder.isSRSEligible(kind: .mistake, mistake: knowledge, solutionPlies: 3, gap: 0.2) == false
        )
    }
}

@Suite("Moment selector")
struct MomentSelectorTests {

    @Test("At most three moments come back")
    func cap() {
        let candidates = (0..<8).map {
            Fixture.moment(ply: $0 * 10, causeTag: CauseTag.allCases[$0], total: Double(10 - $0))
        }
        #expect(MomentSelector.select(candidates: candidates).count == 3)
    }

    @Test("Ordering is by total score")
    func ordering() {
        let candidates = [
            Fixture.moment(ply: 10, causeTag: .hungLeftPiece, total: 1.0),
            Fixture.moment(ply: 20, causeTag: .forcingBias, total: 3.0),
            Fixture.moment(ply: 30, causeTag: .kingExposure, total: 2.0)
        ]
        #expect(MomentSelector.select(candidates: candidates).map(\.causeTag) == [
            .forcingBias, .kingExposure, .hungLeftPiece
        ])
    }

    /// Showing the same lesson twice teaches it once. The second instance is
    /// dropped in favour of a different cause.
    @Test("One moment per cause tag")
    func dedupeByCause() {
        let candidates = [
            Fixture.moment(ply: 10, causeTag: .hungMovedPiece, total: 3.0),
            Fixture.moment(ply: 20, causeTag: .hungMovedPiece, total: 2.9),
            Fixture.moment(ply: 30, causeTag: .kingExposure, total: 1.0)
        ]
        let selected = MomentSelector.select(candidates: candidates)
        #expect(selected.map(\.causeTag) == [.hungMovedPiece, .kingExposure])
        #expect(selected.count == 2)
    }

    @Test("A far more severe repeat still earns its place")
    func dedupeDominanceException() {
        let candidates = [
            Fixture.moment(ply: 10, causeTag: .hungMovedPiece, total: 3.0),
            Fixture.moment(ply: 20, causeTag: .hungMovedPiece, total: 2.9),
            Fixture.moment(ply: 30, causeTag: .kingExposure, total: 0.5)
        ]
        // 2.9 is more than three times the best remaining moment of any other
        // tag (0.5), so the duplicate survives.
        let selected = MomentSelector.select(candidates: candidates)
        #expect(selected.filter { $0.causeTag == .hungMovedPiece }.count == 2)
        #expect(selected.count == 3)
    }

    @Test("Moments closer than five plies together are not both shown")
    func spacing() {
        let candidates = [
            Fixture.moment(ply: 20, causeTag: .hungMovedPiece, total: 3.0),
            Fixture.moment(ply: 23, causeTag: .kingExposure, total: 2.5),
            Fixture.moment(ply: 40, causeTag: .forcingBias, total: 1.0)
        ]
        let selected = MomentSelector.select(candidates: candidates)
        #expect(selected.map(\.ply) == [20, 40])
    }

    @Test("Exactly five plies apart is allowed")
    func spacingBoundary() {
        let candidates = [
            Fixture.moment(ply: 20, causeTag: .hungMovedPiece, total: 3.0),
            Fixture.moment(ply: 25, causeTag: .kingExposure, total: 2.5)
        ]
        #expect(MomentSelector.select(candidates: candidates).count == 2)
    }

    @Test("A positive moment fills a spare slot")
    func positiveMomentFillsSlot() {
        let candidates = [
            Fixture.moment(ply: 10, causeTag: .hungMovedPiece, total: 3.0),
            Fixture.moment(ply: 30, causeTag: .generic, total: 0.4, kind: .reinforcement)
        ]
        let selected = MomentSelector.select(candidates: candidates)
        #expect(selected.count == 2)
        #expect(selected.contains { $0.kind == .reinforcement })
    }

    @Test("A full slate of mistakes leaves no room for praise")
    func positiveMomentCrowdedOut() {
        let candidates = [
            Fixture.moment(ply: 10, causeTag: .hungMovedPiece, total: 3.0),
            Fixture.moment(ply: 20, causeTag: .kingExposure, total: 2.0),
            Fixture.moment(ply: 30, causeTag: .forcingBias, total: 1.0),
            Fixture.moment(ply: 40, causeTag: .generic, total: 5.0, kind: .reinforcement)
        ]
        let selected = MomentSelector.select(candidates: candidates)
        #expect(selected.count == 3)
        #expect(selected.contains { $0.kind == .reinforcement } == false)
    }

    @Test("Only one positive moment is ever shown")
    func onlyOnePositive() {
        let candidates = [
            Fixture.moment(ply: 10, causeTag: .generic, total: 1.0, kind: .reinforcement),
            Fixture.moment(ply: 30, causeTag: .generic, total: 0.9, kind: .reinforcement),
            Fixture.moment(ply: 50, causeTag: .generic, total: 0.8, kind: .reinforcement)
        ]
        #expect(MomentSelector.select(candidates: candidates).count == 1)
    }

    @Test("No candidates, no moments")
    func empty() {
        #expect(MomentSelector.select(candidates: []).isEmpty)
    }
}
