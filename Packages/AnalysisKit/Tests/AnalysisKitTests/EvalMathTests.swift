//
//  EvalMathTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Eval math")
struct EvalMathTests {

    /// Golden values computed independently from Lichess's published formula
    /// `100 / (1 + exp(-0.00368208 * cp))`. If these drift, every threshold in
    /// the app has silently moved.
    @Test("Win percent matches the published sigmoid")
    func winPercentGoldenValues() {
        #expect(EvalMath.winPercent(cp: 0) == 50.0)
        #expect(abs(EvalMath.winPercent(cp: 50) - 54.589_643_760_299_9) < 1e-9)
        #expect(abs(EvalMath.winPercent(cp: 100) - 59.102_589_719_161_28) < 1e-9)
        #expect(abs(EvalMath.winPercent(cp: 200) - 67.621_163_748_505_4) < 1e-9)
        #expect(abs(EvalMath.winPercent(cp: 300) - 75.112_550_093_834_84) < 1e-9)
        #expect(abs(EvalMath.winPercent(cp: 500) - 86.307_165_996_818_27) < 1e-9)
        #expect(abs(EvalMath.winPercent(cp: 1000) - 97.544_743_634_143_23) < 1e-9)
        #expect(abs(EvalMath.winPercent(cp: -300) - 24.887_449_906_165_16) < 1e-9)
    }

    @Test("Win percent clamps beyond ±1000cp")
    func winPercentClamps() {
        #expect(EvalMath.winPercent(cp: 1500) == EvalMath.winPercent(cp: 1000))
        #expect(EvalMath.winPercent(cp: -5000) == EvalMath.winPercent(cp: -1000))
    }

    @Test("Win percent is symmetric, which is what lets EP be complemented")
    func winPercentIsSymmetric() {
        for cp in stride(from: -1200, through: 1200, by: 37) {
            #expect(abs(EvalMath.winPercent(cp: cp) + EvalMath.winPercent(cp: -cp) - 100) < 1e-9)
        }
    }

    @Test("Mate scores saturate")
    func mateScores() {
        #expect(EvalMath.winPercent(score: .mate(1)) == 100)
        #expect(EvalMath.winPercent(score: .mate(12)) == 100)
        #expect(EvalMath.winPercent(score: .mate(-1)) == 0)
        // `mate 0` is a position that is already checkmate for the side to move.
        #expect(EvalMath.winPercent(score: .mate(0)) == 0)
    }

    @Test("Expected points is win percent over 100")
    func expectedPoints() {
        #expect(EvalMath.expectedPoints(50) == 0.5)
        #expect(EvalMath.expectedPoints(score: .centipawns(0)) == 0.5)
        #expect(EvalMath.expectedPoints(score: .mate(3)) == 1.0)
        #expect(abs(EvalMath.complement(ep: 0.7) - 0.3) < 1e-12)
    }

    /// Golden values from `103.1668 * exp(-0.04354 * loss) - 3.1669`.
    @Test("Accuracy matches the published exponential")
    func accuracyGoldenValues() {
        #expect(abs(EvalMath.accuracy(winPctBefore: 50, winPctAfter: 50) - 99.9999) < 1e-9)
        #expect(abs(EvalMath.accuracy(winPctBefore: 50, winPctAfter: 49) - 95.604_401_890_298_25) < 1e-9)
        #expect(abs(EvalMath.accuracy(winPctBefore: 50, winPctAfter: 45) - 79.817_040_063_440_74) < 1e-9)
        #expect(abs(EvalMath.accuracy(winPctBefore: 50, winPctAfter: 40) - 63.582_619_307_109_724) < 1e-9)
        #expect(abs(EvalMath.accuracy(winPctBefore: 50, winPctAfter: 30) - 40.020_427_005_686_074) < 1e-9)
    }

    @Test("Accuracy clamps into 0...100")
    func accuracyClamps() {
        // Improving the position cannot score more than 100.
        #expect(EvalMath.accuracy(winPctBefore: 40, winPctAfter: 90) == 100)
        // A catastrophic loss floors at zero rather than going negative.
        #expect(EvalMath.accuracy(winPctBefore: 100, winPctAfter: 0) == 0)
    }

    @Test("Judgment thresholds fire exactly at their boundaries")
    func judgmentBoundaries() {
        #expect(EvalMath.judgment(deltaEP: 0.0) == .ok)
        #expect(EvalMath.judgment(deltaEP: 0.099_999) == .ok)
        #expect(EvalMath.judgment(deltaEP: 0.10) == .inaccuracy)
        #expect(EvalMath.judgment(deltaEP: 0.199_999) == .inaccuracy)
        #expect(EvalMath.judgment(deltaEP: 0.20) == .mistake)
        #expect(EvalMath.judgment(deltaEP: 0.299_999) == .mistake)
        #expect(EvalMath.judgment(deltaEP: 0.30) == .blunder)
        #expect(EvalMath.judgment(deltaEP: 1.0) == .blunder)
        // A move that improves the position is never a mistake.
        #expect(EvalMath.judgment(deltaEP: -0.4) == .ok)
    }

    @Test("Judgment is ordered so `>= .inaccuracy` gates work")
    func judgmentOrdering() {
        #expect(Judgment.ok < .inaccuracy)
        #expect(Judgment.inaccuracy < .mistake)
        #expect(Judgment.mistake < .blunder)
        #expect(Judgment.blunder >= .inaccuracy)
    }

    @Test("Game accuracy blends the weighted and harmonic means")
    func gameAccuracy() throws {
        // A flat game of perfect moves is 100% accurate.
        let perfect = try #require(
            EvalMath.gameAccuracy(
                moveAccuracies: Array(repeating: 100.0, count: 30),
                winPercents: Array(repeating: 50.0, count: 30)
            )
        )
        #expect(abs(perfect - 100) < 1e-9)

        // One catastrophic move drags the harmonic half down hard, so the game
        // score lands well below the arithmetic mean of 90.5.
        var accuracies = Array(repeating: 100.0, count: 19)
        accuracies.append(9.5)
        var percents = Array(repeating: 50.0, count: 19)
        percents.append(10.0)
        let punished = try #require(
            EvalMath.gameAccuracy(moveAccuracies: accuracies, winPercents: percents)
        )
        #expect(punished < 90.5)
        #expect(punished > 50)

        #expect(EvalMath.gameAccuracy(moveAccuracies: [], winPercents: []) == nil)
    }

    @Test("Delta EP is measured from the mover's side")
    func deltaEP() {
        // +100cp before, -100cp after (already converted to the mover's view).
        let delta = EvalMath.deltaEP(before: .centipawns(100), after: .centipawns(-100))
        #expect(abs(delta - (0.591_025_897_191_612_8 - 0.408_974_102_808_387_1)) < 1e-9)
        #expect(EvalMath.judgment(deltaEP: delta) == .inaccuracy)
    }
}

@Suite("Perspective conversion")
struct PerspectiveTests {

    @Test("White-relative conversion round-trips for both sides")
    func roundTrip() {
        let scores: [UCIScore] = [.centipawns(0), .centipawns(137), .centipawns(-450), .mate(3), .mate(-2)]
        for score in scores {
            for side in [Piece.Color.white, .black] {
                let white = Perspective.whiteRelative(score, sideToMove: side)
                #expect(Perspective.sideToMoveRelative(white, sideToMove: side) == score)
            }
        }
    }

    @Test("White to move leaves the score alone, black flips it")
    func direction() {
        #expect(Perspective.whiteRelative(.centipawns(120), sideToMove: .white) == .centipawns(120))
        #expect(Perspective.whiteRelative(.centipawns(120), sideToMove: .black) == .centipawns(-120))
        #expect(Perspective.whiteRelative(.mate(2), sideToMove: .black) == .mate(-2))
    }

    @Test("A score for a viewer flips only when the viewer is not to move")
    func viewerRelative() {
        #expect(Perspective.relative(.centipawns(80), sideToMove: .white, to: .white) == .centipawns(80))
        #expect(Perspective.relative(.centipawns(80), sideToMove: .white, to: .black) == .centipawns(-80))
    }

    /// The single most dangerous sign in game review: the engine's score for the
    /// position after a move belongs to the opponent.
    @Test("After-move scores are negated into the mover's perspective")
    func afterMove() {
        // Engine says "+300 for the side to move" in the position after White
        // played — that is +300 for Black, i.e. -300 for White.
        #expect(Perspective.moverRelativeAfterMove(.centipawns(300)) == .centipawns(-300))
        #expect(Perspective.moverRelativeAfterMove(.mate(1)) == .mate(-1))
    }

    @Test("Expected points complement equals the negated score's expected points")
    func complementMatchesNegation() {
        for cp in stride(from: -900, through: 900, by: 53) {
            let mine = EvalMath.expectedPoints(score: .centipawns(cp))
            let theirs = EvalMath.expectedPoints(score: UCIScore.centipawns(cp).negated)
            #expect(abs(EvalMath.complement(ep: mine) - theirs) < 1e-12)
        }
    }
}
