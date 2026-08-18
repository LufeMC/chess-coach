//
//  DetectorTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Testing

@testable import AnalysisKit

@Suite("Hanging piece detector")
struct HangingPieceDetectorTests {

    @Test("A piece moved onto an attacked square is `.moved`")
    func movedPieceHangs() throws {
        // Ra1-a5?? walks into the b6 pawn.
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(500)
        )
        let findings = HangingPieceDetector().detect(context)
        let finding = try #require(findings.first)
        #expect(finding.subtype == .moved)
        #expect(finding.squares == [.a5])
        #expect(finding.magnitude == Double(PieceValues.rook))
        #expect(finding.flags.contains(.refutationCapturesTarget))
    }

    @Test("A piece left hanging elsewhere is `.left`")
    func otherPieceHangs() throws {
        // The rook on d5 was already attacked by c6; Na3 ignores it.
        let context = try Fixture.context(
            fen: "4k3/8/2p5/3R4/8/8/8/1N2K3 w - - 0 1",
            played: "b1a3",
            refutation: ["c6d5"],
            refutationScore: .centipawns(500)
        )
        let finding = try #require(HangingPieceDetector().detect(context).first)
        #expect(finding.subtype == .left)
        #expect(finding.squares == [.d5])
    }

    /// Offering a pawn is ordinary chess. Without a real cost, it is not a
    /// finding — otherwise every gambit would be reported as a blunder.
    @Test("A pawn only counts once the move actually cost something")
    func pawnGate() throws {
        let gambit = try Fixture.context(
            fen: "4k3/8/8/1p6/8/8/2P5/4K3 w - - 0 1",
            played: "c2c4",
            refutation: ["b5c4"],
            refutationScore: .centipawns(20)
        )
        #expect(gambit.judgment == .ok)
        #expect(HangingPieceDetector().detect(gambit).isEmpty)

        let costly = try Fixture.context(
            fen: "4k3/8/8/1p6/8/8/2P5/4K3 w - - 0 1",
            played: "c2c4",
            refutation: ["b5c4"],
            refutationScore: .centipawns(300)
        )
        #expect(costly.judgment >= .inaccuracy)
        #expect(HangingPieceDetector().detect(costly).isEmpty == false)
    }

    @Test("Nothing hanging, nothing reported")
    func clean() throws {
        let context = try Fixture.context(
            fen: "4k3/8/8/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutation: ["e8e7"],
            refutationScore: .centipawns(0)
        )
        #expect(HangingPieceDetector().detect(context).isEmpty)
    }
}

@Suite("Ignored threat detector")
struct IgnoredThreatDetectorTests {

    /// Fool's mate: after 1.f3 e5 Black is already threatening Qh4, and 2.g4??
    /// walks into it.
    private let foolsMate = "rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2"

    private func probe(_ fen: String, move: String?, cp: Int) throws -> ThreatProbe {
        let position = try Fixture.position(fen)
        let probeFEN = try #require(NullMove.probeFEN(for: position))
        return ThreatProbe(fen: probeFEN, bestMove: move, score: .centipawns(cp), pv: [move].compactMap { $0 })
    }

    @Test("A threat the opponent then executes is reported as new")
    func newThreat() throws {
        let context = try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "g2g4",
            refutation: ["d8h4"],
            refutationScore: .mate(1),
            threatProbe: try probe(foolsMate, move: "d8h4", cp: 400)
        )
        let finding = try #require(IgnoredThreatDetector().detect(context).first)
        #expect(finding.subtype == .newThreat)
        #expect(finding.squares == [.h4])
    }

    @Test("A threat that was already there one move ago is standing")
    func standingThreat() throws {
        let context = try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "g2g4",
            refutation: ["d8h4"],
            refutationScore: .mate(1),
            threatProbe: try probe(foolsMate, move: "d8h4", cp: 400),
            previousThreatProbe: try probe(foolsMate, move: "d8h4", cp: 380)
        )
        let finding = try #require(IgnoredThreatDetector().detect(context).first)
        #expect(finding.subtype == .standingThreat)
    }

    /// A threat the opponent did not actually play was not the reason the move
    /// failed.
    @Test("The opponent has to play the threatened move")
    func replyMustMatch() throws {
        let context = try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "g2g4",
            refutation: ["b8c6"],
            refutationScore: .centipawns(40),
            threatProbe: try probe(foolsMate, move: "d8h4", cp: 400)
        )
        #expect(IgnoredThreatDetector().detect(context).isEmpty)
    }

    @Test("A free move worth nothing is no threat")
    func probeMustBeWorthSomething() throws {
        let context = try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "g2g4",
            refutation: ["d8h4"],
            refutationScore: .mate(1),
            threatProbe: try probe(foolsMate, move: "d8h4", cp: 10)
        )
        #expect(IgnoredThreatDetector().detect(context).isEmpty)
    }

    @Test("No probe, no finding")
    func requiresProbe() throws {
        let context = try Fixture.context(
            fen: foolsMate,
            ply: 3,
            played: "g2g4",
            refutation: ["d8h4"],
            refutationScore: .mate(1)
        )
        #expect(IgnoredThreatDetector().detect(context).isEmpty)
    }
}

@Suite("Missed and allowed tactic detectors")
struct TacticDetectorTests {

    /// Nb5-c7+ forks the king and the a8 rook; Ke2 misses it.
    private let forkAvailable = "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1"

    @Test("A missed fork is reported with its theme")
    func missedTactic() throws {
        let context = try Fixture.context(
            fen: forkAvailable,
            played: "e1e2",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(30)
        )
        #expect(context.judgment >= .inaccuracy)
        let finding = try #require(MissedTacticDetector().detect(context).first)
        #expect(finding.subtype == .playedQuiet)
        #expect(finding.themes == [.fork])
        #expect(finding.magnitude == Double(PieceValues.rook))
    }

    @Test("A quiet best line is not a missed tactic")
    func nonTacticalLine() throws {
        let context = try Fixture.context(
            fen: forkAvailable,
            played: "e1e2",
            best: ["b5d4", "e8e7", "e1d2"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(30)
        )
        #expect(MissedTacticDetector().detect(context).isEmpty)
    }

    @Test("A good move is never a missed tactic")
    func requiresJudgment() throws {
        let context = try Fixture.context(
            fen: forkAvailable,
            played: "e1e2",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(-390)
        )
        #expect(context.judgment == .ok)
        #expect(MissedTacticDetector().detect(context).isEmpty)
    }

    @Test("A one-ply punish is a shallow allowed tactic")
    func allowedShallow() throws {
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(500)
        )
        let finding = try #require(AllowedTacticDetector().detect(context).first)
        #expect(finding.subtype == .shallow)
        #expect(finding.flags.contains(.refutationIsForcing))
    }

    @Test("A three-ply combination is a deep allowed tactic")
    func allowedDeep() throws {
        // 1...Bxc3 2.bxc3 Rxd1+ only nets material on the third ply.
        let context = try Fixture.context(
            fen: "3r2k1/8/8/8/1b6/2N5/1P6/3R2K1 w - - 0 1",
            played: "g1h1",
            refutation: ["b4c3", "b2c3", "d8d1"],
            refutationScore: .centipawns(500)
        )
        let finding = try #require(AllowedTacticDetector().detect(context).first)
        #expect(finding.subtype == .deep)
    }

    @Test("A small evaluation drop is not an allowed tactic")
    func allowedNeedsSize() throws {
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(40)
        )
        #expect(AllowedTacticDetector().detect(context).isEmpty)
    }
}

@Suite("Wrong trade detector")
struct WrongTradeDetectorTests {

    @Test("A capture with negative SEE loses material")
    func losesMaterial() throws {
        let context = try Fixture.context(
            fen: "4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1",
            played: "d1d5",
            best: ["d1d2"],
            refutation: ["c6d5"],
            refutationScore: .centipawns(400)
        )
        let finding = try #require(WrongTradeDetector().detect(context).first)
        #expect(finding.subtype == .losesMaterial)
        #expect(finding.magnitude == 400)
    }

    @Test("An even trade while worse is a planless simplification")
    func badSimplification() throws {
        // Nxc6 bxc6 swaps knights when White is already worse and had a quiet
        // alternative.
        let context = try Fixture.context(
            fen: "4k3/1p6/2n5/8/3N4/8/8/4K3 w - - 0 1",
            played: "d4c6",
            best: ["e1e2"],
            bestScore: .centipawns(-100),
            refutation: ["b7c6"],
            refutationScore: .centipawns(220)
        )
        #expect(context.judgment >= .inaccuracy)
        let finding = try #require(WrongTradeDetector().detect(context).first)
        #expect(finding.subtype == .badSimplification)
    }

    @Test("An even trade from a good position is not flagged")
    func equalPositionTrade() throws {
        let context = try Fixture.context(
            fen: "4k3/1p6/2n5/8/3N4/8/8/4K3 w - - 0 1",
            played: "d4c6",
            best: ["e1e2"],
            bestScore: .centipawns(120),
            refutation: ["b7c6"],
            refutationScore: .centipawns(20)
        )
        #expect(WrongTradeDetector().detect(context).isEmpty)
    }

    @Test("Quiet moves are not trades")
    func onlyCaptures() throws {
        let context = try Fixture.context(
            fen: "4k3/1p6/2n5/8/3N4/8/8/4K3 w - - 0 1",
            played: "e1e2",
            best: ["d4c6"],
            bestScore: .centipawns(-100),
            refutationScore: .centipawns(220)
        )
        #expect(WrongTradeDetector().detect(context).isEmpty)
    }
}

@Suite("King weakening detector")
struct KingWeakeningDetectorTests {

    /// White is castled on h1 with the f2/g2/h2 shelter intact; g2-g4 opens the
    /// long diagonal to the king.
    private let shelter = "1nbq1rk1/p4ppp/8/8/8/8/P4PPP/RNB4K w - - 0 15"

    @Test("A punished loosening move is `.tacticalPunish`")
    func punished() throws {
        let context = try Fixture.context(
            fen: shelter,
            ply: 29,
            played: "g2g4",
            refutation: ["d8d5"],
            refutationScore: .centipawns(300)
        )
        #expect(context.phase == .middlegame)
        let finding = try #require(KingWeakeningPawnMoveDetector().detect(context).first)
        #expect(finding.subtype == .tacticalPunish)
    }

    @Test("An unpunished loosening move is `.positional`")
    func positional() throws {
        let context = try Fixture.context(
            fen: shelter,
            ply: 29,
            played: "g2g4",
            refutation: ["b8c6"],
            refutationScore: .centipawns(300)
        )
        let finding = try #require(KingWeakeningPawnMoveDetector().detect(context).first)
        #expect(finding.subtype == .positional)
    }

    @Test("A pawn move away from the king is not a weakening")
    func farFromKing() throws {
        let context = try Fixture.context(
            fen: shelter,
            ply: 29,
            played: "a2a4",
            refutation: ["d8d5"],
            refutationScore: .centipawns(300)
        )
        #expect(KingWeakeningPawnMoveDetector().detect(context).isEmpty)
    }

    @Test("Without a queen the shelter matters far less")
    func needsAttackers() throws {
        let context = try Fixture.context(
            fen: "1nb2rk1/p4ppp/8/8/8/8/P4PPP/RNB4K w - - 0 15",
            ply: 29,
            played: "g2g4",
            refutation: ["b8c6"],
            refutationScore: .centipawns(300)
        )
        #expect(KingWeakeningPawnMoveDetector().detect(context).isEmpty)
    }
}

@Suite("Missed quiet move detector")
struct MissedQuietMoveDetectorTests {

    /// The rook on d5 is attacked by the c6 pawn. Rd8+ is a forcing move that
    /// achieves nothing; stepping away was right.
    private let loudOrQuiet = "4k3/8/2p5/3R4/8/8/8/4K3 w - - 0 1"

    private func threat() throws -> ThreatProbe {
        let position = try Fixture.position(loudOrQuiet)
        let fen = try #require(NullMove.probeFEN(for: position))
        return ThreatProbe(fen: fen, bestMove: "c6d5", score: .centipawns(450), pv: ["c6d5"])
    }

    @Test("A backwards best move is a retreat")
    func retreat() throws {
        let context = try Fixture.context(
            fen: loudOrQuiet,
            played: "d5d8",
            best: ["d5d1"],
            bestScore: .centipawns(50),
            refutationScore: .centipawns(200)
        )
        #expect(context.playedMoveIsForcing)
        #expect(context.bestMoveIsQuiet)
        let finding = try #require(MissedQuietMoveDetector().detect(context).first)
        #expect(finding.subtype == .retreat)
    }

    @Test("A sideways move that defuses the threat is prophylactic")
    func prophylactic() throws {
        let context = try Fixture.context(
            fen: loudOrQuiet,
            played: "d5d8",
            best: ["d5f5"],
            bestScore: .centipawns(50),
            refutationScore: .centipawns(200),
            threatProbe: try threat()
        )
        let finding = try #require(MissedQuietMoveDetector().detect(context).first)
        #expect(finding.subtype == .prophylactic)
    }

    @Test("Otherwise a quiet best move is an improvement")
    func improvement() throws {
        let context = try Fixture.context(
            fen: loudOrQuiet,
            played: "d5d8",
            best: ["d5f5"],
            bestScore: .centipawns(50),
            refutationScore: .centipawns(200)
        )
        let finding = try #require(MissedQuietMoveDetector().detect(context).first)
        #expect(finding.subtype == .improvement)
    }

    @Test("A quiet move played is not forcing bias")
    func requiresForcingPlay() throws {
        let context = try Fixture.context(
            fen: loudOrQuiet,
            played: "d5d4",
            best: ["d5f5"],
            bestScore: .centipawns(50),
            refutationScore: .centipawns(200)
        )
        #expect(MissedQuietMoveDetector().detect(context).isEmpty)
    }
}

@Suite("Opening principle detector")
struct OpeningPrincipleDetectorTests {

    @Test("The queen out before the minors is flagged")
    func earlyQueen() throws {
        let context = try Fixture.context(
            fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            ply: 3,
            played: "d1h5",
            bestScore: .centipawns(20),
            refutationScore: .centipawns(120)
        )
        let findings = OpeningPrincipleDetector().detect(context)
        #expect(findings.map(\.subtype) == [.earlyQueen])
    }

    @Test("Moving the same piece twice in the opening is flagged")
    func repeatedPiece() throws {
        let earlier = try Fixture.move(
            "g1f3",
            in: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        )
        let context = try Fixture.context(
            fen: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 4 3",
            ply: 5,
            played: "f3g5",
            bestScore: .centipawns(20),
            refutationScore: .centipawns(150),
            priorMoves: [earlier]
        )
        let findings = OpeningPrincipleDetector().detect(context)
        #expect(findings.map(\.subtype) == [.repeatedPieceMove])
    }

    @Test("A king still in the middle on move 15 with an open e-file is flagged")
    func delayedCastling() throws {
        let context = try Fixture.context(
            fen: "r2q1rk1/ppp2ppp/2n5/3p4/3P4/2N5/PPP2PPP/R2QK2R w KQ - 0 15",
            ply: 29,
            played: "a2a3",
            bestScore: .centipawns(-30),
            refutationScore: .centipawns(30)
        )
        let findings = OpeningPrincipleDetector().detect(context)
        #expect(findings.map(\.subtype) == [.delayedCastling])
    }

    @Test("Good moves break no principles")
    func cleanOpening() throws {
        let context = try Fixture.context(
            fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            ply: 3,
            played: "g1f3",
            bestScore: .centipawns(20),
            refutationScore: .centipawns(-20)
        )
        #expect(OpeningPrincipleDetector().detect(context).isEmpty)
    }
}

@Suite("Endgame technique detector")
struct EndgameTechniqueDetectorTests {

    /// The single most instructive KPK error: 1.Kg6! wins, 1.g6?? draws. The
    /// engine's centipawn score barely moves, so only the bitbase catches it.
    @Test("A KPK win thrown away is caught exactly")
    func kpkRegression() throws {
        let context = try Fixture.context(
            fen: "6k1/8/5K2/6P1/8/8/8/8 w - - 0 1",
            ply: 61,
            played: "g5g6",
            best: ["f6g6"],
            bestScore: .centipawns(120),
            refutationScore: .centipawns(-120)
        )
        #expect(context.phase == .endgame)
        #expect(context.judgment == .ok)

        let finding = try #require(EndgameTechniqueDetector().detect(context).first)
        #expect(finding.subtype == .kpk)
        #expect(finding.flags.contains(.exactBitbase))
        #expect(finding.flags.contains(.resultClassFlip))
    }

    @Test("Playing the winning move produces no finding")
    func kpkCorrect() throws {
        let context = try Fixture.context(
            fen: "6k1/8/5K2/6P1/8/8/8/8 w - - 0 1",
            ply: 61,
            played: "f6g6",
            best: ["f6g6"],
            bestScore: .centipawns(120),
            refutationScore: .centipawns(-120)
        )
        #expect(EndgameTechniqueDetector().detect(context).isEmpty)
    }

    @Test("A rook endgame mistake is labelled as one")
    func rookEndgame() throws {
        let context = try Fixture.context(
            fen: "8/4k3/r7/4K3/4P3/8/8/R7 w - - 0 1",
            ply: 61,
            played: "a1a6",
            best: ["e5d5"],
            bestScore: .centipawns(150),
            refutationScore: .centipawns(200)
        )
        #expect(context.judgment >= .mistake)
        let finding = try #require(EndgameTechniqueDetector().detect(context).first)
        #expect(finding.subtype == .rookEndgame)
        #expect(finding.flags.contains(.philidorAvailable))
    }

    @Test("Middlegame moves are out of scope")
    func middlegameIgnored() throws {
        let context = try Fixture.context(
            fen: "1nbq1rk1/p4ppp/8/8/8/8/P4PPP/RNB4K w - - 0 15",
            ply: 29,
            played: "g2g4",
            refutationScore: .centipawns(400)
        )
        #expect(EndgameTechniqueDetector().detect(context).isEmpty)
    }
}

@Suite("Endgame classifier")
struct EndgameClassifierTests {

    @Test("Endgame types are recognised")
    func types() throws {
        #expect(EndgameClassifier.classify(try Fixture.position("8/8/8/4k3/8/4P3/4K3/8 w - - 0 1")) == .kpk)
        #expect(EndgameClassifier.classify(try Fixture.position("8/8/8/4k3/8/8/4K3/4Q3 w - - 0 1")) == .basicMate)
        #expect(EndgameClassifier.classify(try Fixture.position("8/8/8/4k3/8/8/4K3/4R3 w - - 0 1")) == .basicMate)
        #expect(
            EndgameClassifier.classify(try Fixture.position("8/5pk1/8/8/8/8/5PK1/8 w - - 0 1")) == .pawnEndgame
        )
        #expect(
            EndgameClassifier.classify(try Fixture.position("8/5pk1/8/8/8/8/5PK1/2R1r3 w - - 0 1"))
                == .rookEndgame
        )
        #expect(
            EndgameClassifier.classify(try Fixture.position("8/5pk1/8/8/8/8/5PK1/2B1n3 w - - 0 1")) == .other
        )
    }

    @Test("The Lucena picture is recognised")
    func lucena() throws {
        // King on the queening square, pawn on the seventh, defender cut off.
        let position = try Fixture.position("2K5/k1P5/8/8/8/8/7r/3R4 w - - 0 1")
        #expect(EndgameClassifier.lucenaSignature(position))
        #expect(EndgameClassifier.philidorSignature(position) == false)
    }

    @Test("The Philidor picture is recognised")
    func philidor() throws {
        // Defending king in front of the pawn, defending rook on its third rank.
        let position = try Fixture.position("8/4k3/r7/4K3/4P3/8/8/R7 w - - 0 1")
        #expect(EndgameClassifier.philidorSignature(position))
        #expect(EndgameClassifier.lucenaSignature(position) == false)
    }
}

@Suite("Time error detector")
struct TimeErrorDetectorTests {

    private let critical = CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)

    @Test("A snap move in a critical position is an impulse")
    func impulse() throws {
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(500),
            thinkTimeMs: 800,
            timeControl: .blitz5plus0,
            criticality: critical
        )
        let subtypes = TimeErrorDetector().detect(context).map(\.subtype)
        #expect(subtypes.contains(.impulseAtCritical))
    }

    @Test("A blunder after a long think is its own error")
    func longThink() throws {
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(500),
            thinkTimeMs: 120_000,
            timeControl: .blitz5plus0
        )
        let subtypes = TimeErrorDetector().detect(context).map(\.subtype)
        #expect(subtypes.contains(.blunderAfterLongThink))
        #expect(subtypes.contains(.impulseAtCritical) == false)
    }

    @Test("Clock pressure and flagging are reported on their own")
    func pressureAndFlag() throws {
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a5",
            refutationScore: .centipawns(500),
            clockPressure: true,
            didFlag: true
        )
        let subtypes = Set(TimeErrorDetector().detect(context).map(\.subtype))
        #expect(subtypes.contains(.clockPressure))
        #expect(subtypes.contains(.flagged))
    }

    @Test("A normal think on a sound move reports nothing")
    func quiet() throws {
        let context = try Fixture.context(
            fen: "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1",
            played: "a1a4",
            thinkTimeMs: 10_000,
            timeControl: .blitz5plus0
        )
        #expect(TimeErrorDetector().detect(context).isEmpty)
    }
}
