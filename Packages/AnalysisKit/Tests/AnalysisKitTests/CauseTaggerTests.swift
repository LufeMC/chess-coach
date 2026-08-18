//
//  CauseTaggerTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Cause tagger decision table")
struct CauseTaggerTests {

    /// The rook on d5 is attacked; Rd8+ is the forcing move, Rd1 the quiet one.
    /// Both variants of the fallback row can be produced from this one position.
    private static let fen = "4k3/8/2p5/3R4/8/8/8/4K3 w - - 0 1"

    /// A context with a real, meaningfully bad move, used for every row that does
    /// not care about the position itself.
    private func context(
        best: [String] = ["d5d1"],
        played: String = "d5d8",
        thinkTimeMs: Int? = nil,
        critical: Bool = false,
        clockPressure: Bool = false,
        didFlag: Bool = false
    ) throws -> MoveContext {
        try Fixture.context(
            fen: Self.fen,
            played: played,
            best: best,
            bestScore: .centipawns(50),
            refutationScore: .centipawns(250),
            thinkTimeMs: thinkTimeMs,
            timeControl: .blitz5plus0,
            clockPressure: clockPressure,
            didFlag: didFlag,
            criticality: CriticalityResult(isCritical: critical, gap: 0.2, suppressedBy: nil)
        )
    }

    private func finding(
        _ detector: DetectorID,
        _ subtype: FindingSubtype,
        flags: Set<FindingFlag> = []
    ) -> Finding {
        Finding(detector: detector, subtype: subtype, flags: flags)
    }

    // MARK: One test per row

    @Test("Row: ignoredThreat(.new) → missedNewThreat / S1")
    func rowNewThreat() throws {
        let mistake = CauseTagger.tag(findings: [finding(.ignoredThreat, .newThreat)], context: try context())
        #expect(mistake.causeTag == .missedNewThreat)
        #expect(mistake.stepTag == .s1WhatChanged)
    }

    @Test("Row: ignoredThreat(.standing) → ignoredStandingThreat / S2")
    func rowStandingThreat() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.ignoredThreat, .standingThreat)],
            context: try context()
        )
        #expect(mistake.causeTag == .ignoredStandingThreat)
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
    }

    @Test("Row: hangingPiece(.moved) with a capturing refutation → hungMovedPiece / S5")
    func rowHungMovedPiece() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.hangingPiece, .moved, flags: [.refutationCapturesTarget])],
            context: try context()
        )
        #expect(mistake.causeTag == .hungMovedPiece)
        #expect(mistake.stepTag == .s5BlunderCheck)
    }

    @Test("Row: hangingPiece(.left) → hungLeftPiece / S5")
    func rowHungLeftPiece() throws {
        let mistake = CauseTagger.tag(findings: [finding(.hangingPiece, .left)], context: try context())
        #expect(mistake.causeTag == .hungLeftPiece)
        #expect(mistake.stepTag == .s5BlunderCheck)
    }

    @Test("Row: allowedTactic(.shallow) with a forcing refutation → allowedShallowTactic / S5")
    func rowAllowedShallow() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.allowedTactic, .shallow, flags: [.refutationIsForcing])],
            context: try context()
        )
        #expect(mistake.causeTag == .allowedShallowTactic)
        #expect(mistake.stepTag == .s5BlunderCheck)
    }

    @Test("Row: allowedTactic(.deep) → allowedDeepTactic / S4")
    func rowAllowedDeep() throws {
        let mistake = CauseTagger.tag(findings: [finding(.allowedTactic, .deep)], context: try context())
        #expect(mistake.causeTag == .allowedDeepTactic)
        #expect(mistake.stepTag == .s4Calculate)
    }

    @Test("Row: missedTactic after a forcing move → miscalculatedTactic / S4")
    func rowMiscalculatedTactic() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.missedTactic, .playedForcing)],
            context: try context()
        )
        #expect(mistake.causeTag == .miscalculatedTactic)
        #expect(mistake.stepTag == .s4Calculate)
    }

    @Test("Row: missedTactic after a quiet move → missedForcingIdea / S2")
    func rowMissedForcingIdea() throws {
        let mistake = CauseTagger.tag(findings: [finding(.missedTactic, .playedQuiet)], context: try context())
        #expect(mistake.causeTag == .missedForcingIdea)
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
    }

    @Test("Row: missedQuietMove → forcingBias / S3")
    func rowForcingBias() throws {
        let mistake = CauseTagger.tag(findings: [finding(.missedQuietMove, .retreat)], context: try context())
        #expect(mistake.causeTag == .forcingBias)
        #expect(mistake.stepTag == .s3Candidates)
    }

    @Test("Row: wrongTrade(.losesMaterial) → miscountedExchange / S4")
    func rowMiscountedExchange() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.wrongTrade, .losesMaterial)],
            context: try context()
        )
        #expect(mistake.causeTag == .miscountedExchange)
        #expect(mistake.stepTag == .s4Calculate)
    }

    @Test("Row: wrongTrade(.badSimplification) → planlessTrade / S3")
    func rowPlanlessTrade() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.wrongTrade, .badSimplification)],
            context: try context()
        )
        #expect(mistake.causeTag == .planlessTrade)
        #expect(mistake.stepTag == .s3Candidates)
    }

    @Test("Row: kingWeakening(.tacticalPunish) → kingExposure / S2")
    func rowKingExposureTactical() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.kingWeakeningPawnMove, .tacticalPunish)],
            context: try context()
        )
        #expect(mistake.causeTag == .kingExposure)
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
    }

    @Test("Row: kingWeakening(.positional) → kingExposure / S3")
    func rowKingExposurePositional() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.kingWeakeningPawnMove, .positional)],
            context: try context()
        )
        #expect(mistake.causeTag == .kingExposure)
        #expect(mistake.stepTag == .s3Candidates)
    }

    @Test("Row: endgameTechnique → endgameTechnique / K")
    func rowEndgame() throws {
        let mistake = CauseTagger.tag(findings: [finding(.endgameTechnique, .kpk)], context: try context())
        #expect(mistake.causeTag == .endgameTechnique)
        #expect(mistake.stepTag == .kKnowledge)
    }

    @Test("Row: openingPrinciple → openingPrinciple / K")
    func rowOpening() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.openingPrinciple, .earlyQueen)],
            context: try context()
        )
        #expect(mistake.causeTag == .openingPrinciple)
        #expect(mistake.stepTag == .kKnowledge)
    }

    @Test("Row: nothing fired and the best move was quiet → positionalDrift / S3")
    func rowPositionalDrift() throws {
        let context = try context(best: ["d5d1"])
        #expect(context.judgment >= .inaccuracy)
        #expect(context.bestMoveIsQuiet)
        let mistake = CauseTagger.tag(findings: [], context: context)
        #expect(mistake.causeTag == .positionalDrift)
        #expect(mistake.stepTag == .s3Candidates)
    }

    @Test("Row: nothing fired and the best move was forcing → missedForcingIdea / S2")
    func rowFallbackForcing() throws {
        let context = try context(best: ["d5d8"], played: "d5d4")
        #expect(context.judgment >= .inaccuracy)
        #expect(context.bestMoveIsQuiet == false)
        let mistake = CauseTagger.tag(findings: [], context: context)
        #expect(mistake.causeTag == .missedForcingIdea)
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
    }

    @Test("A sound move with no findings is generic")
    func generic() throws {
        let context = try Fixture.context(
            fen: Self.fen,
            played: "d5d1",
            best: ["d5d1"],
            bestScore: .centipawns(50),
            refutationScore: .centipawns(-50)
        )
        #expect(context.judgment == .ok)
        let mistake = CauseTagger.tag(findings: [], context: context)
        #expect(mistake.causeTag == .generic)
    }

    // MARK: Priority

    @Test("Hanging the piece you just moved outranks everything else")
    func priority() throws {
        let findings = [
            finding(.openingPrinciple, .earlyQueen),
            finding(.missedQuietMove, .retreat),
            finding(.hangingPiece, .moved, flags: [.refutationCapturesTarget]),
            finding(.allowedTactic, .deep)
        ]
        let mistake = CauseTagger.tag(findings: findings, context: try context())
        #expect(mistake.causeTag == .hungMovedPiece)
        #expect(mistake.secondaryTags.contains("allowedTactic.deep"))
        #expect(mistake.secondaryTags.contains("missedQuietMove.retreat"))
        #expect(mistake.secondaryTags.contains("openingPrinciple.earlyQueen"))
        #expect(mistake.secondaryTags.contains("hangingPiece.moved") == false)
    }

    @Test("Time findings never become the primary cause")
    func timeIsNeverPrimary() throws {
        let findings = [
            finding(.timeError, .clockPressure),
            finding(.kingWeakeningPawnMove, .positional)
        ]
        let mistake = CauseTagger.tag(findings: findings, context: try context())
        #expect(mistake.causeTag == .kingExposure)
        #expect(mistake.secondaryTags.contains("timeError.clockPressure"))
    }

    @Test("Severity is the expected-points loss")
    func severity() throws {
        let context = try context()
        let mistake = CauseTagger.tag(findings: [], context: context)
        #expect(mistake.severity == context.deltaEP)
    }

    // MARK: Overlays

    @Test("O1 moves a calculation failure back to S2 when the move was impulsive")
    func overlayImpulseOnS4() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.allowedTactic, .deep)],
            context: try context(thinkTimeMs: 500, critical: true)
        )
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
        #expect(mistake.modifiers.contains(MistakeModifier.impulse.rawValue))
    }

    @Test("O1 also applies to a skipped blunder check")
    func overlayImpulseOnS5() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.hangingPiece, .moved, flags: [.refutationCapturesTarget])],
            context: try context(thinkTimeMs: 500, critical: true)
        )
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
        #expect(mistake.modifiers.contains(MistakeModifier.impulse.rawValue))
    }

    @Test("O1 needs the position to be critical")
    func overlayImpulseNeedsCritical() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.allowedTactic, .deep)],
            context: try context(thinkTimeMs: 500, critical: false)
        )
        #expect(mistake.stepTag == .s4Calculate)
        #expect(mistake.modifiers.isEmpty)
    }

    /// You cannot fail to calculate what you never reached: S1, S3 and K are
    /// upstream of calculation, so the impulse overlay must leave them alone.
    @Test(
        "O1 does not touch S1, S3 or K",
        arguments: [
            (DetectorID.ignoredThreat, FindingSubtype.newThreat, StepTag.s1WhatChanged),
            (DetectorID.missedQuietMove, FindingSubtype.retreat, StepTag.s3Candidates),
            (DetectorID.endgameTechnique, FindingSubtype.kpk, StepTag.kKnowledge),
            (DetectorID.openingPrinciple, FindingSubtype.earlyQueen, StepTag.kKnowledge),
            (DetectorID.wrongTrade, FindingSubtype.badSimplification, StepTag.s3Candidates)
        ]
    )
    func overlayImpulseLeavesOtherStepsAlone(
        detector: DetectorID,
        subtype: FindingSubtype,
        expected: StepTag
    ) throws {
        let mistake = CauseTagger.tag(
            findings: [finding(detector, subtype)],
            context: try context(thinkTimeMs: 500, critical: true)
        )
        #expect(mistake.stepTag == expected)
        #expect(mistake.modifiers.contains(MistakeModifier.impulse.rawValue) == false)
    }

    @Test("O2 turns a long-thought blunder check into a calculation error")
    func overlayDeepMiss() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.hangingPiece, .left)],
            context: try context(thinkTimeMs: 200_000)
        )
        #expect(mistake.stepTag == .s4Calculate)
        #expect(mistake.modifiers.contains(MistakeModifier.deepMiss.rawValue))
    }

    @Test("O2 only applies to S5")
    func overlayDeepMissOnlyS5() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.allowedTactic, .deep)],
            context: try context(thinkTimeMs: 200_000)
        )
        #expect(mistake.stepTag == .s4Calculate)
        #expect(mistake.modifiers.isEmpty)
    }

    @Test("O3 adds a modifier and changes no step")
    func overlayClockPressure() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.hangingPiece, .moved)],
            context: try context(clockPressure: true)
        )
        #expect(mistake.stepTag == .s5BlunderCheck)
        #expect(mistake.modifiers == [MistakeModifier.clockPressure.rawValue])
    }

    @Test("Overlays stack in order: impulse first, then clock pressure")
    func overlayOrder() throws {
        let mistake = CauseTagger.tag(
            findings: [finding(.hangingPiece, .moved)],
            context: try context(thinkTimeMs: 500, critical: true, clockPressure: true, didFlag: true)
        )
        #expect(mistake.stepTag == .s2ChecksCapturesThreats)
        #expect(
            mistake.modifiers == [
                MistakeModifier.impulse.rawValue,
                MistakeModifier.clockPressure.rawValue,
                MistakeModifier.flagged.rawValue
            ]
        )
    }
}
