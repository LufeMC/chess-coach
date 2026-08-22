//
//  MomentExplainerTests.swift
//  AnalysisKitTests
//

import ChessKit
import EngineKit
import Foundation
import Testing

@testable import AnalysisKit

/// Every position here is one of the detectors' own fixtures.
///
/// The note is only worth anything if it is true of the board, and the way to
/// keep it true is to write it against positions whose findings are already
/// asserted a file away rather than against a position invented to make a
/// sentence come out well.
private enum Sample {

    /// Ra1-a5?? walks into the b6 pawn.
    static let hangsMovedPiece = "4k3/8/1p6/8/8/8/8/R3K3 w - - 0 1"
    /// The rook on d5 is attacked by c6; the knight on b1 never defended it.
    static let hangsOtherPiece = "4k3/8/2p5/3R4/8/8/8/1N2K3 w - - 0 1"
    /// The same rook, but this time the knight on c3 is what was holding it.
    static let hangsAbandonedPiece = "4k3/8/2p5/3R4/8/2N5/8/4K3 w - - 0 1"
    /// After 1.f3 e5, Black is already threatening Qh4.
    static let foolsMate = "rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR w KQkq - 0 2"
    /// 1...Bxc3 2.bxc3 Rxd1+ only nets material on the third ply.
    static let deepCombination = "3r2k1/8/8/8/1b6/2N5/1P6/3R2K1 w - - 0 1"
    /// Nb5-c7+ forks the king on e8 and the rook on a8.
    static let forkAvailable = "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1"
    /// The rook on d5 is attacked by c6; Rd8+ is loud and pointless.
    static let loudOrQuiet = "4k3/8/2p5/3R4/8/8/8/4K3 w - - 0 1"
    /// Rxd5 walks into cxd5.
    static let losingCapture = "4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1"
    /// Nxc6 bxc6 swaps knights when White is already worse.
    static let poorTrade = "4k3/1p6/2n5/8/3N4/8/8/4K3 w - - 0 1"
    /// White is castled on h1 with the shelter intact; g2-g4 opens the diagonal.
    static let shelter = "1nbq1rk1/p4ppp/8/8/8/8/P4PPP/RNB4K w - - 0 15"
    /// 1.Kg6! wins, 1.g6?? draws.
    static let kpkWin = "6k1/8/5K2/6P1/8/8/8/8 w - - 0 1"
    /// Black holds with 1...Kd5; 1...Kb4 loses.
    static let kpkDefence = "8/8/8/2k5/3P4/8/3K4/8 b - - 0 60"
    /// Philidor: defending king in front of the pawn, rook on its third rank.
    static let philidor = "8/4k3/r7/4K3/4P3/8/8/R7 w - - 0 1"
    static let openingCentre = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    static let uncastled = "r2q1rk1/ppp2ppp/2n5/3p4/3P4/2N5/PPP2PPP/R2QK2R w KQ - 0 15"
    /// Nothing hangs, nothing is threatened, the rook simply goes to a worse square.
    static let drifting = "4k3/8/8/8/8/8/8/R3K3 w - - 0 1"

    static func probe(_ fen: String, move: String, cp: Int) throws -> ThreatProbe {
        let probeFEN = try #require(NullMove.probeFEN(for: try Fixture.position(fen)))
        return ThreatProbe(fen: probeFEN, bestMove: move, score: .centipawns(cp), pv: [move])
    }

    /// Runs the real pipeline: detectors, tagger, moment.
    ///
    /// - parameter detectors: Restricted where the cause under test would
    ///   otherwise lose the tagger's priority contest to a detector that also
    ///   fires on the same position — the findings are still the real detector's
    ///   output on a real board.
    static func moment(
        _ context: MoveContext,
        detectors: [any Detector]? = nil,
        kind: MomentKind = .mistake
    ) -> Moment {
        let findings = detectors.map { DetectorSuite.run(context, detectors: $0) } ?? DetectorSuite.run(context)
        let mistake = CauseTagger.tag(findings: findings, context: context)
        return MomentBuilder.make(context: context, findings: findings, mistake: mistake, kind: kind)
    }

    static func note(
        _ context: MoveContext,
        detectors: [any Detector]? = nil,
        kind: MomentKind = .mistake
    ) throws -> String {
        try #require(moment(context, detectors: detectors, kind: kind).coachText)
    }

    /// One context per shape of note the explainer can write.
    ///
    /// Used by the tests that assert something about *every* note — the copy
    /// budget, the vocabulary — where a claim proved on one clause is worth very
    /// little. Each entry is a detector fixture, so the sentences under test are
    /// written about positions whose findings are asserted elsewhere.
    static func everyShape() throws -> [MoveContext] {
        [
            try Fixture.context(
                fen: hangsMovedPiece, played: "a1a5",
                refutation: ["b6a5"], refutationScore: .centipawns(500)
            ),
            try Fixture.context(
                fen: hangsOtherPiece, played: "b1a3",
                refutation: ["e8e7"], refutationScore: .centipawns(400)
            ),
            try Fixture.context(
                fen: foolsMate, ply: 3, played: "g2g4", best: ["b1c3"],
                bestScore: .centipawns(20), refutation: ["d8h4"], refutationScore: .mate(1),
                threatProbe: try probe(foolsMate, move: "d8h4", cp: 400)
            ),
            try Fixture.context(
                fen: deepCombination, played: "g1h1", best: ["d1d8"],
                refutation: ["b4c3", "b2c3", "d8d1"], refutationScore: .centipawns(500)
            ),
            try Fixture.context(
                fen: forkAvailable, played: "e1e2", best: ["b5c7", "e8e7", "c7a8"],
                bestScore: .centipawns(400), refutationScore: .centipawns(30)
            ),
            try Fixture.context(
                fen: loudOrQuiet, played: "d5d8", best: ["d5d1"],
                bestScore: .centipawns(50), refutationScore: .centipawns(200)
            ),
            try Fixture.context(
                fen: losingCapture, played: "d1d5", best: ["d1d2"],
                refutation: ["c6d5"], refutationScore: .centipawns(400)
            ),
            try Fixture.context(
                fen: poorTrade, played: "d4c6", best: ["e1e2"],
                bestScore: .centipawns(-100), refutation: ["b7c6"], refutationScore: .centipawns(220)
            ),
            try Fixture.context(
                fen: shelter, ply: 29, played: "g2g4", best: ["h1g1"],
                refutation: ["d8d5"], refutationScore: .centipawns(300)
            ),
            try Fixture.context(
                fen: kpkWin, ply: 61, played: "g5g6", best: ["f6g6"],
                bestScore: .centipawns(120), refutationScore: .centipawns(-120)
            ),
            try Fixture.context(
                fen: philidor, ply: 61, played: "a1a6", best: ["e5d5"],
                bestScore: .centipawns(150), refutationScore: .centipawns(200)
            ),
            try Fixture.context(
                fen: openingCentre, ply: 3, played: "d1h5", best: ["g1f3"],
                bestScore: .centipawns(20), refutationScore: .centipawns(120)
            ),
            try Fixture.context(
                fen: drifting, played: "a1a4", best: ["a1d1"],
                bestScore: .centipawns(60), refutationScore: .centipawns(80)
            )
        ]
    }
}

@Suite("Moment explainer")
struct MomentExplainerTests {

    // MARK: The eight-plus cause tags, each naming its own facts

    @Test("Hanging the piece you moved names the square, the capture and the size")
    func hungMovedPiece() throws {
        let context = try Fixture.context(
            fen: Sample.hangsMovedPiece,
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(500)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .hungMovedPiece)
        #expect(note.contains("Ra5"))
        // The move that actually punished it. No model was ever allowed to name
        // this one — it is outside every line the prompt supplied.
        #expect(note.contains("bxa5"))
        #expect(note.contains("a5"))
        // A rook, not "500cp": the note prices material in the words the player
        // counts in, and the figure stays on the move list.
        #expect(note.contains("a rook"))
        #expect(note.contains("no defenders"))
        #expect(note.contains("blunder check"))
    }

    @Test("Hanging a piece elsewhere names that piece, not the one that moved")
    func hungLeftPiece() throws {
        let context = try Fixture.context(
            fen: Sample.hangsOtherPiece,
            played: "b1a3",
            refutation: ["c6d5"],
            refutationScore: .centipawns(500)
        )
        let moment = Sample.moment(context, detectors: [HangingPieceDetector()])
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .hungLeftPiece)
        #expect(note.contains("rook on d5"))
        #expect(note.contains("cxd5"))
        #expect(note.contains("a rook"))
    }

    /// The detector fires on the static exchange count alone whenever the move
    /// also cost an inaccuracy's worth of ground, and that count is blind to
    /// pins, checks and desperados. On a move the engine answered some other way
    /// the note therefore says what was counted — and names the answer the
    /// engine actually chose, which is the move that was really missed.
    @Test("A loose piece the engine's own reply declines is counted, not condemned")
    func hangingWithoutAnEngineCapture() throws {
        let taken = try Fixture.context(
            fen: Sample.hangsOtherPiece,
            played: "b1a3",
            refutation: ["c6d5"],
            refutationScore: .centipawns(500)
        )
        // The same loose rook, but their best reply is a king move: static
        // exchange still says d5 is winnable and the engine declined to prove it.
        let declined = try Fixture.context(
            fen: Sample.hangsOtherPiece,
            played: "b1a3",
            refutation: ["e8e7"],
            refutationScore: .centipawns(400)
        )

        let confirmed = Sample.moment(taken, detectors: [HangingPieceDetector()])
        let unconfirmed = Sample.moment(declined, detectors: [HangingPieceDetector()])
        let confirmedNote = try #require(confirmed.coachText)
        let unconfirmedNote = try #require(unconfirmed.coachText)

        // Same finding, same square, same cause: only the strength of the claim
        // is allowed to differ.
        #expect(confirmed.causeTag == unconfirmed.causeTag)
        #expect(unconfirmed.evidence?.squares == [Square.d5])
        #expect(unconfirmed.evidence?.flags.contains(.refutationCapturesTarget) == false)

        #expect(confirmedNote.contains("can just be taken"))
        #expect(confirmedNote.contains("which is a rook"))

        #expect(unconfirmedNote.contains("can just be taken") == false)
        #expect(unconfirmedNote.contains("hanging") == false)
        // What was actually computed: the count, and their real answer.
        #expect(unconfirmedNote.contains("the count is one attacker to no defenders"))
        #expect(unconfirmedNote.contains("Ke7"))
        // And no price on the piece, because nothing showed it coming off.
        #expect(unconfirmedNote.contains("which is a rook") == false)
    }

    @Test("A missed new threat names the square and what they actually played")
    func missedNewThreat() throws {
        let context = try Fixture.context(
            fen: Sample.foolsMate,
            ply: 3,
            played: "g2g4",
            best: ["b1c3"],
            bestScore: .centipawns(20),
            refutation: ["d8h4"],
            refutationScore: .mate(1),
            threatProbe: try Sample.probe(Sample.foolsMate, move: "d8h4", cp: 400)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .missedNewThreat)
        #expect(note.contains("h4"))
        #expect(note.contains("Qh4#"))
        // The square, not the size. The threat's magnitude is a half-budget
        // probe score minus a full-budget one, which is fit to rank findings and
        // unfit to quote.
        #expect(note.contains("h4 was the square to be looking at"))
        #expect(MomentExplainer.stepPhrasings(.s1WhatChanged).contains { note.contains($0) })
    }

    @Test("A standing threat says it had been there, and still names the move")
    func ignoredStandingThreat() throws {
        let context = try Fixture.context(
            fen: Sample.foolsMate,
            ply: 3,
            played: "g2g4",
            best: ["b1c3"],
            bestScore: .centipawns(20),
            refutation: ["d8h4"],
            refutationScore: .mate(1),
            threatProbe: try Sample.probe(Sample.foolsMate, move: "d8h4", cp: 400),
            previousThreatProbe: try Sample.probe(Sample.foolsMate, move: "d8h4", cp: 380)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .ignoredStandingThreat)
        #expect(note.contains("for a move already"))
        #expect(note.contains("Qh4#"))
    }

    @Test("An allowed one-move tactic names the refutation and its motif")
    func allowedShallowTactic() throws {
        let context = try Fixture.context(
            fen: Sample.foolsMate,
            ply: 3,
            played: "g2g4",
            best: ["b1c3"],
            bestScore: .centipawns(20),
            refutation: ["d8h4"],
            refutationScore: .mate(1)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .allowedShallowTactic)
        #expect(note.contains("Qh4#"))
        #expect(note.contains("mate"))
    }

    @Test("An allowed combination names its first move and how long it takes")
    func allowedDeepTactic() throws {
        let context = try Fixture.context(
            fen: Sample.deepCombination,
            played: "g1h1",
            best: ["d1d8"],
            refutation: ["b4c3", "b2c3", "d8d1"],
            refutationScore: .centipawns(500)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .allowedDeepTactic)
        #expect(note.contains("Bxc3"))
        // Three plies is two moves as the player who has to find them counts.
        #expect(note.contains("two moves"))
        #expect(note.contains("d1"))
    }

    @Test("A missed tactic names both forked pieces")
    func missedForcingIdea() throws {
        let context = try Fixture.context(
            fen: Sample.forkAvailable,
            played: "e1e2",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(30)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .missedForcingIdea)
        #expect(note.contains("Nc7+"))
        // The whole reason `classifyDetailed` exists: naming which two pieces.
        #expect(note.contains("king on e8"))
        #expect(note.contains("rook on a8"))
        #expect(note.contains("worth a rook"))
    }

    @Test("A miscalculated tactic contrasts the move played with the one that worked")
    func miscalculatedTactic() throws {
        let context = try Fixture.context(
            fen: Sample.forkAvailable,
            played: "b5d6",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutation: ["e8d8"],
            refutationScore: .centipawns(30)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .miscalculatedTactic)
        #expect(note.contains("Nd6+"))
        #expect(note.contains("Nc7+"))
        #expect(note.contains("fork"))
    }

    /// `CauseTag` folds retreat, prophylaxis and improvement into one tag. The
    /// subtype carried on the moment is what lets three different sentences come
    /// out of it, which is the point of carrying it.
    @Test("Forcing bias reads differently for a retreat, a prophylactic move and an improvement")
    func forcingBias() throws {
        let retreat = try Sample.note(
            Fixture.context(
                fen: Sample.loudOrQuiet,
                played: "d5d8",
                best: ["d5d1"],
                bestScore: .centipawns(50),
                refutationScore: .centipawns(200)
            ),
            detectors: [MissedQuietMoveDetector()]
        )
        let prophylactic = try Sample.note(
            Fixture.context(
                fen: Sample.loudOrQuiet,
                played: "d5d8",
                best: ["d5f5"],
                bestScore: .centipawns(50),
                refutationScore: .centipawns(200),
                threatProbe: try Sample.probe(Sample.loudOrQuiet, move: "c6d5", cp: 450)
            ),
            detectors: [MissedQuietMoveDetector()]
        )
        let improvement = try Sample.note(
            Fixture.context(
                fen: Sample.loudOrQuiet,
                played: "d5d8",
                best: ["d5f5"],
                bestScore: .centipawns(50),
                refutationScore: .centipawns(200)
            ),
            detectors: [MissedQuietMoveDetector()]
        )

        #expect(retreat.contains("Rd1"))
        #expect(retreat.contains("back"))
        #expect(prophylactic.contains("prophylactic"))
        // The threat the quiet move answers, named.
        #expect(prophylactic.contains("cxd5"))
        #expect(improvement.contains("quiet improvement"))
        #expect(Set([retreat, prophylactic, improvement]).count == 3)
    }

    @Test("A miscounted exchange counts the recaptures and states the shortfall")
    func miscountedExchange() throws {
        let context = try Fixture.context(
            fen: Sample.losingCapture,
            played: "d1d5",
            best: ["d1d2"],
            refutation: ["c6d5"],
            refutationScore: .centipawns(400)
        )
        let moment = Sample.moment(context, detectors: [WrongTradeDetector()])
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .miscountedExchange)
        #expect(note.contains("d5"))
        #expect(note.contains("one recapture"))
        // 400 is not any one piece, so it is counted in pawns rather than given
        // the name of the nearest one.
        #expect(note.contains("about four pawns"))
    }

    @Test("A planless trade names what trading does rather than quoting the evaluation")
    func planlessTrade() throws {
        let context = try Fixture.context(
            fen: Sample.poorTrade,
            played: "d4c6",
            best: ["e1e2"],
            bestScore: .centipawns(-100),
            refutation: ["b7c6"],
            refutationScore: .centipawns(220)
        )
        let moment = Sample.moment(context, detectors: [WrongTradeDetector()])
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .planlessTrade)
        #expect(note.contains("Nxc6"))
        #expect(note.contains("c6"))
        #expect(note.contains("fewer pieces suits whoever is ahead"))
    }

    @Test("King exposure names the king's square and what stopped covering what")
    func kingExposure() throws {
        let context = try Fixture.context(
            fen: Sample.shelter,
            ply: 29,
            played: "g2g4",
            best: ["h1g1"],
            refutation: ["d8d5"],
            refutationScore: .centipawns(300)
        )
        let moment = Sample.moment(context, detectors: [KingWeakeningPawnMoveDetector()])
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .kingExposure)
        #expect(note.contains("king is on h1"))
        #expect(note.contains("h3"))
        #expect(note.contains("Qd5+"))
    }

    /// The bitbase verdict is the strongest fact in the whole analysis and the
    /// one a model could never be trusted with: the engine's score barely moves
    /// across this move.
    @Test("A KPK error quotes the exact bitbase verdict on both sides of the move")
    func endgameTechniqueKPK() throws {
        let context = try Fixture.context(
            fen: Sample.kpkWin,
            ply: 61,
            played: "g5g6",
            best: ["f6g6"],
            bestScore: .centipawns(120),
            refutationScore: .centipawns(-120)
        )
        let moment = Sample.moment(context)
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .endgameTechnique)
        #expect(moment.evidence?.subtype == .kpk)
        // "Bitbase" is the engine's word for it; the claim it licenses — that
        // this ending has an exact answer — is the part the player needs.
        #expect(note.contains("known exactly"))
        #expect(note.contains("a win for the pawn before g6"))
        #expect(note.contains("a draw after it"))
        #expect(note.contains("Kg6"))
    }

    @Test("The defending side of the same ending is described from its own side")
    func endgameTechniqueDefender() throws {
        let note = try Sample.note(
            Fixture.context(
                fen: Sample.kpkDefence,
                ply: 120,
                played: "c5b4",
                best: ["c5d5"],
                bestScore: .centipawns(-20),
                refutationScore: .centipawns(20)
            )
        )
        #expect(note.contains("a draw before Kb4"))
        #expect(note.contains("Kd5"))
    }

    @Test("A rook ending names the technique that was available")
    func endgameTechniqueRook() throws {
        let moment = Sample.moment(
            try Fixture.context(
                fen: Sample.philidor,
                ply: 61,
                played: "a1a6",
                best: ["e5d5"],
                bestScore: .centipawns(150),
                refutationScore: .centipawns(200)
            )
        )
        let note = try #require(moment.coachText)
        #expect(moment.evidence?.subtype == .rookEndgame)
        #expect(note.contains("rook ending"))
        #expect(note.contains("Philidor"))
    }

    @Test("An opening principle counts the pieces still at home")
    func openingPrinciple() throws {
        let note = try Sample.note(
            Fixture.context(
                fen: Sample.openingCentre,
                ply: 3,
                played: "d1h5",
                best: ["g1f3"],
                bestScore: .centipawns(20),
                refutationScore: .centipawns(120)
            )
        )
        #expect(note.contains("Qh5"))
        #expect(note.contains("four minor pieces"))
        #expect(note.contains("Nf3"))

        let castling = try Sample.note(
            Fixture.context(
                fen: Sample.uncastled,
                ply: 29,
                played: "a2a3",
                best: ["e1g1"],
                bestScore: .centipawns(-30),
                refutationScore: .centipawns(200)
            )
        )
        #expect(castling.contains("king is still on e1"))
        #expect(castling.contains("move 15"))
    }

    // MARK: The honest limits

    /// Nothing hung and nothing was threatened. There is no honest specific
    /// sentence available, so the note sets a task instead of inventing a plan.
    @Test("Positional drift sets a task rather than inventing a plan")
    func positionalDrift() throws {
        let moment = Sample.moment(
            try Fixture.context(
                fen: Sample.drifting,
                played: "a1a4",
                best: ["a1d1"],
                bestScore: .centipawns(60),
                refutationScore: .centipawns(80)
            )
        )
        let note = try #require(moment.coachText)

        #expect(moment.causeTag == .positionalDrift)
        #expect(moment.evidence == nil)
        #expect(note.contains("side by side"))
        #expect(note.contains("name what changed"))
        // No motif, no refuting move, no invented plan.
        #expect(note.contains("fork") == false)
        #expect(note.contains("threat") == false)
    }

    /// The probe is skipped for a side that was in check, for a ply outside the
    /// enrichment window and for a probe search that was cut short — and on all
    /// three the app never looked at what the opponent was threatening. A note
    /// that reports the negative anyway is inventing the one fact it is least
    /// entitled to, so the claim is made only where the probe ran.
    @Test("\"Nothing was threatened\" is only said when the threat probe actually ran")
    func driftOnlyClaimsWhatWasProbed() throws {
        let unprobed = try Fixture.context(
            fen: Sample.drifting,
            played: "a1a4",
            best: ["a1d1"],
            bestScore: .centipawns(60),
            refutationScore: .centipawns(80)
        )
        // The same position with a probe taken. The threat detector still cannot
        // fire — it needs the opponent to play the probe's move for real, and no
        // reply was searched here — so the only thing that changes is what the
        // note is entitled to say.
        let probed = try Fixture.context(
            fen: Sample.drifting,
            played: "a1a4",
            best: ["a1d1"],
            bestScore: .centipawns(60),
            refutationScore: .centipawns(80),
            threatProbe: try Sample.probe(Sample.drifting, move: "e8d7", cp: 10)
        )

        let withoutProbe = try Sample.note(unprobed)
        let withProbe = try Sample.note(probed)

        #expect(Sample.moment(probed).causeTag == .positionalDrift)
        #expect(withoutProbe.contains("Nothing hung here"))
        #expect(withoutProbe.contains("nothing was threatened") == false)
        #expect(withProbe.contains("Nothing hung and nothing was threatened"))
    }

    /// The shipped bank had no `generic` entry, so praise moments were handed the
    /// default question — "what did this move allow in return?" — on the one
    /// moment in a review that exists to say the player got it right.
    @Test("Praise is never accusatory and is never asked a question")
    func praiseIsNotAccused() throws {
        let context = try Fixture.context(
            fen: Sample.forkAvailable,
            played: "b5c7",
            best: ["b5c7", "e8e7", "c7a8"],
            bestScore: .centipawns(400),
            refutationScore: .centipawns(-400),
            criticality: CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)
        )
        #expect(MomentBuilder.isReinforcementCandidate(context))

        let moment = Sample.moment(context, kind: .reinforcement)
        let note = try #require(moment.coachText)

        #expect(moment.kind == .reinforcement)
        #expect(note.contains("Nc7+"))
        #expect(note.contains("?") == false)
        for accusation in ["allowed", "cost", "walked into", "hanging", "blunder", "missed", "wrong"] {
            #expect(note.contains(accusation) == false, "praise note contains \"\(accusation)\": \(note)")
        }
        #expect(CoachingQuestions.question(for: moment, context: context) == nil)
    }

    /// `.left` means only "something other than the piece you moved is hanging".
    /// Asking which piece the moved one was defending has no answer when it never
    /// defended anything, and a question with no answer teaches the student to
    /// stop trusting the coaching.
    @Test("The loose-piece question splits on whether the moved piece was the defender")
    func looseQuestionSplits() throws {
        let neverDefended = try Fixture.context(
            fen: Sample.hangsOtherPiece,
            played: "b1a3",
            refutation: ["c6d5"],
            refutationScore: .centipawns(500)
        )
        let abandoned = try Fixture.context(
            fen: Sample.hangsAbandonedPiece,
            played: "c3a4",
            refutation: ["c6d5"],
            refutationScore: .centipawns(500)
        )

        let first = Sample.moment(neverDefended, detectors: [HangingPieceDetector()])
        let second = Sample.moment(abandoned, detectors: [HangingPieceDetector()])
        #expect(first.causeTag == .hungLeftPiece)
        #expect(second.causeTag == .hungLeftPiece)

        #expect(
            CoachingQuestions.question(for: first, context: neverDefended)
                == CoachingQuestions.alreadyLooseQuestion
        )
        #expect(
            CoachingQuestions.question(for: second, context: abandoned)
                == CoachingQuestions.abandonedDefenderQuestion
        )
    }

    // MARK: Contract

    @Test("The same moment always produces the same note")
    func determinism() throws {
        let context = try Fixture.context(
            fen: Sample.hangsMovedPiece,
            played: "a1a5",
            refutation: ["b6a5"],
            refutationScore: .centipawns(500)
        )
        let notes = (0..<8).map { _ in Sample.moment(context).coachText }
        #expect(Set(notes.compactMap { $0 }).count == 1)
    }

    /// Phrasing varies across a game so three moments of one shape do not read as
    /// one sentence printed three times — while each of them stays fixed.
    @Test("Phrasing varies between positions of the same shape")
    func variation() throws {
        var openings: Set<String> = []
        for ply in 1...24 {
            let note = try Sample.note(
                Fixture.context(
                    fen: Sample.hangsMovedPiece,
                    ply: ply,
                    played: "a1a5",
                    refutation: ["b6a5"],
                    refutationScore: .centipawns(500)
                )
            )
            openings.insert(String(note.prefix(12)))
        }
        #expect(openings.count > 1)
    }

    /// The register the whole app is written in: a note explains a move to a
    /// player around 1200, and an engine unit in it is a word they have to
    /// translate or skip. The numbers are not lost — the move list prints the
    /// evaluation and the chip prints the class — they are simply not what a
    /// sentence about their own game is made of.
    @Test("No note is written in engine units")
    func notesAreInChessEnglish() throws {
        // Word-bounded on purpose: "simply" contains "ply", and banning the
        // substring would ban the sentence.
        let engineVocabulary = [
            "[0-9]+ ?cp\\b",
            "\\bcentipawns?\\b",
            "expected points",
            "\\bpl(y|ies)\\b",
            "\\bmultipv\\b",
            "\\bdepth\\b",
            "[0-9]+\\.[0-9]+"
        ]

        var notes = try Sample.everyShape().map { try Sample.note($0) }
        notes.append(
            try Sample.note(
                Fixture.context(
                    fen: Sample.forkAvailable, played: "b5c7", best: ["b5c7", "e8e7", "c7a8"],
                    bestScore: .centipawns(400), refutationScore: .centipawns(-400),
                    criticality: CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)
                ),
                kind: .reinforcement
            )
        )

        for note in notes {
            for pattern in engineVocabulary {
                #expect(
                    note.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil,
                    "\(pattern) in: \(note)"
                )
            }
        }
    }

    /// The bands are what keep a number from being given the name of the
    /// nearest piece: 400 is a queen for a rook, and printing "a piece" would be
    /// a material claim nothing computed.
    @Test("Material is named only where the figure is that piece")
    func materialIsNamedOnlyWhenItIsThatPiece() {
        #expect(MomentExplainer.material(320) == "a piece")
        #expect(MomentExplainer.material(330) == "a piece")
        #expect(MomentExplainer.material(500) == "a rook")
        #expect(MomentExplainer.material(900) == "a queen")
        #expect(MomentExplainer.material(180) == "the exchange")
        #expect(MomentExplainer.material(400) == "about four pawns")
        #expect(MomentExplainer.material(100) == "about a pawn")
        // Sign is the caller's business: the clause it lands in says who lost it.
        #expect(MomentExplainer.material(-500) == "a rook")
    }

    /// Both sides of this move read the same on the graph, so there is no honest
    /// two-word summary of what it cost — and "from level to level" would be
    /// filler in the clause that is supposed to be the evidence.
    @Test("A move that does not change the standing gets no swing clause")
    func swingNeedsAChangeOfStanding() throws {
        let note = try Sample.note(
            Fixture.context(
                fen: Sample.drifting,
                played: "a1a4",
                best: ["a1d1"],
                bestScore: .centipawns(10),
                refutationScore: .centipawns(20)
            )
        )

        #expect(note.contains("simply let the position get worse"))
        #expect(note.contains("from level to level") == false)
    }

    @Test("Every note fits the copy block")
    func budget() throws {
        let contexts: [MoveContext] = [
            try Fixture.context(
                fen: Sample.hangsMovedPiece, played: "a1a5",
                refutation: ["b6a5"], refutationScore: .centipawns(500)
            ),
            try Fixture.context(
                fen: Sample.foolsMate, ply: 3, played: "g2g4", best: ["b1c3"],
                bestScore: .centipawns(20), refutation: ["d8h4"], refutationScore: .mate(1),
                thinkTimeMs: 800, timeControl: .blitz5plus0, clockPressure: true, didFlag: true,
                threatProbe: try Sample.probe(Sample.foolsMate, move: "d8h4", cp: 400),
                criticality: CriticalityResult(isCritical: true, gap: 0.2, suppressedBy: nil)
            ),
            try Fixture.context(
                fen: Sample.deepCombination, played: "g1h1", best: ["d1d8"],
                refutation: ["b4c3", "b2c3", "d8d1"], refutationScore: .centipawns(500),
                thinkTimeMs: 120_000, timeControl: .blitz5plus0
            ),
            try Fixture.context(
                fen: Sample.drifting, played: "a1a4", best: ["a1d1"],
                bestScore: .centipawns(60), refutationScore: .centipawns(80)
            ),
            try Fixture.context(
                fen: Sample.forkAvailable, played: "e1e2", best: ["b5c7", "e8e7", "c7a8"],
                bestScore: .centipawns(400), refutationScore: .centipawns(30)
            )
        ]

        for context in contexts {
            let note = try Sample.note(context)
            #expect(note.count <= MomentExplainer.characterBudget, "\(note.count): \(note)")
            #expect(note.isEmpty == false)
        }
    }

    /// Clause one and the cause tag are two projections of one row, so a
    /// sentence about hanging the piece you moved can never sit under a label
    /// that says something else.
    @Test("The sentence table and the cause table cannot disagree")
    func tableIsOneTable() {
        for row in DiagnosisTable.rows {
            #expect(row.phrasings.isEmpty == false)
            guard let subtype = row.subtype else { continue }
            let mapped = CauseTagger.baseMapping(for: Finding(detector: row.detector, subtype: subtype))
            #expect(mapped?.cause == row.cause)
            #expect(mapped?.step == row.step)
        }
    }

    /// Every subtype a detector can emit has to reach a row, or the tagger falls
    /// through to the positional-drift fallback for a move it actually explained.
    @Test("Every mapped subtype has a sentence")
    func everySubtypeIsCovered() {
        for detector in DetectorID.allCases where detector != .timeError {
            for subtype in FindingSubtype.allCases {
                let finding = Finding(detector: detector, subtype: subtype)
                guard CauseTagger.baseMapping(for: finding) != nil else { continue }
                #expect(DiagnosisTable.row(for: finding) != nil)
            }
        }
    }

    /// The evidence rides inside the moment's opaque payload blob, which is only
    /// free of migration cost if a payload written without it still decodes.
    @Test("Evidence and note survive a round trip, and a payload without them still loads")
    func payloadRoundTrip() throws {
        let moment = Sample.moment(
            try Fixture.context(
                fen: Sample.hangsMovedPiece, played: "a1a5",
                refutation: ["b6a5"], refutationScore: .centipawns(500)
            )
        )
        let data = try JSONEncoder().encode(moment)
        let restored = try JSONDecoder().decode(Moment.self, from: data)
        #expect(restored.evidence == moment.evidence)
        #expect(restored.coachText == moment.coachText)
        #expect(restored.evidence?.squares == [Square.a5])

        var stripped = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        stripped.removeValue(forKey: "evidence")
        stripped.removeValue(forKey: "coachText")
        let older = try JSONSerialization.data(withJSONObject: stripped)
        let legacy = try JSONDecoder().decode(Moment.self, from: older)
        #expect(legacy.evidence == nil)
        #expect(legacy.coachText == nil)
        #expect(legacy.causeTag == moment.causeTag)
    }
}

@Suite("Tactic theme detail")
struct TacticThemeDetailTests {

    @Test("A fork names its targets, most valuable first")
    func forkTargets() throws {
        let detail = TacticThemeClassifier.classifyDetailed(
            pv: ["b5c7"],
            from: try Fixture.position("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1")
        )
        #expect(detail.theme == .fork)
        #expect(detail.squares == [.e8, .a8])
    }

    @Test("A pin names the piece in front and the piece behind")
    func pinSquares() throws {
        let detail = TacticThemeClassifier.classifyDetailed(
            pv: ["d1a4"],
            from: try Fixture.position("4k3/8/2n5/8/8/8/8/3BK3 w - - 0 1")
        )
        #expect(detail.theme == .pin)
        #expect(detail.squares == [.c6, .e8])
    }

    @Test("A skewer names the piece in front and the piece behind")
    func skewerSquares() throws {
        let detail = TacticThemeClassifier.classifyDetailed(
            pv: ["a1b1"],
            from: try Fixture.position("1r2k3/8/8/8/1q6/8/8/R5K1 w - - 0 1")
        )
        #expect(detail.theme == .skewer)
        #expect(detail.squares == [.b4, .b8])
    }

    @Test("A line with no motif reports no squares")
    func unknown() throws {
        let detail = TacticThemeClassifier.classifyDetailed(
            pv: ["e1e2"],
            from: try Fixture.position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1")
        )
        #expect(detail.theme == .unknownTactic)
        #expect(detail.squares.isEmpty)
    }
}

@Suite("Game summary")
struct GameSummaryTests {

    private func moments(_ tags: [CauseTag]) -> [Moment] {
        tags.enumerated().map { Fixture.moment(ply: $0.offset * 10 + 1, causeTag: $0.element, total: 1) }
    }

    @Test("A loss is reported as a loss, with no consolation")
    func lossIsHonest() {
        let summary = GameSummarizer.summary(
            outcome: .loss,
            accuracy: 71.4,
            moveCount: 38,
            moments: moments([.hungMovedPiece, .kingExposure])
        )
        #expect(summary.headline.contains("decided"))
        #expect(summary.body.contains("71% accuracy over 38 moves"))
        for cheer in ["well played", "great", "unlucky", "close", "nearly"] {
            #expect(summary.body.lowercased().contains(cheer) == false)
            #expect(summary.headline.lowercased().contains(cheer) == false)
        }
    }

    @Test("A win is stated, not congratulated")
    func winIsPlain() {
        let summary = GameSummarizer.summary(
            outcome: .win,
            accuracy: 88,
            moveCount: 41,
            moments: moments([.forcingBias])
        )
        #expect(summary.headline.contains("A win"))
        #expect(summary.headline.contains("!") == false)
        #expect(summary.body.contains("88% accuracy over 41 moves"))
    }

    /// A tag that appeared twice is the only claim about a whole game the data
    /// actually supports.
    @Test("A cause that repeated is named as the pattern")
    func repeatedCause() {
        let summary = GameSummarizer.summary(
            outcome: .draw,
            accuracy: 80,
            moveCount: 50,
            moments: moments([.hungMovedPiece, .hungMovedPiece, .kingExposure])
        )
        #expect(summary.body.contains("twice"))
        #expect(summary.body.contains("that is the pattern"))
    }

    @Test("Praise in the slate is mentioned, and the budgets are respected")
    func praiseAndBudgets() {
        var slate = moments([.hungMovedPiece])
        slate.append(Fixture.moment(ply: 30, causeTag: .generic, total: 1, kind: .reinforcement))
        let summary = GameSummarizer.summary(outcome: .win, accuracy: 90, moveCount: 30, moments: slate)

        #expect(summary.body.contains("you got it right"))
        #expect(summary.headline.count <= GameSummary.headlineBudget)
        #expect(summary.body.count <= GameSummary.bodyBudget)
    }

    /// `Moment.total` is the selection score — severity multiplied by
    /// learnability and by how relevant the lesson is to this player's current
    /// rung — and it decides which three positions are worth showing. Both of
    /// the verdict's claims are claims about size instead, so both are made on
    /// what the move cost. Reading `total` let a teachable opening inaccuracy
    /// outrank the blunder that lost the game, and the headline then named a
    /// phase the graph directly above it contradicted.
    @Test("The verdict follows what the moves cost, not the selection score")
    func verdictFollowsTheCost() {
        let teachable = Fixture.moment(
            ply: 5,
            causeTag: .openingPrinciple,
            total: 6,
            deltaEP: 0.12,
            phase: .opening
        )
        let costliest = Fixture.moment(
            ply: 41,
            causeTag: .kingExposure,
            total: 1,
            deltaEP: 0.55,
            phase: .endgame
        )

        let summary = GameSummarizer.summary(
            outcome: .loss,
            accuracy: 68,
            moveCount: 30,
            moments: [teachable, costliest]
        )

        #expect(summary.headline.contains("endgame"))
        #expect(summary.headline.contains("opening") == false)
        // 41 half-moves in is move 21, and the cause named is that move's cause.
        #expect(summary.body.contains("on move 21"))
        #expect(summary.body.contains(GameSummarizer.causeName(.kingExposure)))
    }

    /// Two moves that cost the same: the verdict names the earlier one, because
    /// the rest of the game followed from it — and it must not depend on the
    /// order the moments happen to arrive in.
    @Test("Equal cost breaks to the earlier move")
    func equalCostPrefersTheEarlierMove() {
        let early = Fixture.moment(ply: 9, causeTag: .hungMovedPiece, total: 1, deltaEP: 0.4)
        let late = Fixture.moment(ply: 33, causeTag: .kingExposure, total: 9, deltaEP: 0.4)

        let summary = GameSummarizer.summary(
            outcome: .loss,
            accuracy: 68,
            moveCount: 30,
            moments: [late, early]
        )

        #expect(summary.body.contains("on move 5"))
    }

    @Test("A game with nothing to review says so")
    func nothingToReview() {
        let summary = GameSummarizer.summary(outcome: .draw, accuracy: 94, moveCount: 22, moments: [])
        #expect(summary.headline.contains("no single moment"))
        #expect(summary.body.contains("crossed the threshold"))
    }
}
