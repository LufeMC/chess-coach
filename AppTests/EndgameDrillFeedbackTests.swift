//
//  EndgameDrillFeedbackTests.swift
//  ChessCoachTests
//

import AnalysisKit
import ChessKit
import Foundation
import Testing

@testable import ChessCoach

// MARK: - Helpers

/// Move generation the drills' own grader can be checked against.
///
/// Every position these tests need is *found* rather than written down. A test
/// that hard-codes "Kc5 holds the draw" is a chess claim of its own, and a wrong
/// one would pin the very kind of confidently-false coaching the drill exists to
/// avoid. Asking the bitbase which moves keep the verdict costs a few
/// milliseconds and cannot be wrong in a way the app is not also wrong in.
enum KPKProbeSupport {

    /// Legal moves for the side to move, in UCI, split by whether they leave the
    /// bitbase verdict where it was.
    ///
    /// Promotions are skipped: the table has no entry for a position with a
    /// queen on it, so neither bucket would be honest.
    static func moves(from position: Position) -> (keeping: [String], changing: [String]) {
        guard let before = KPKBitbase.probe(position: position) else { return ([], []) }
        var keeping: [String] = []
        var changing: [String] = []
        for from in Square.allCases {
            guard let piece = position.piece(at: from), piece.color == position.sideToMove else { continue }
            for to in Square.allCases where to != from {
                var board = Board(position: position)
                guard board.canMove(pieceAt: from, to: to), board.move(pieceAt: from, to: to) != nil else {
                    continue
                }
                if case .promotion = board.state { continue }
                guard let after = KPKBitbase.probe(position: board.position) else { continue }
                let uci = from.notation + to.notation
                if after == before { keeping.append(uci) } else { changing.append(uci) }
            }
        }
        return (keeping, changing)
    }

    /// The same FEN with the other side to move.
    static func flippingSideToMove(_ fen: String) -> String {
        var fields = fen.split(separator: " ").map(String.init)
        guard fields.count >= 2 else { return fen }
        fields[1] = fields[1] == "w" ? "b" : "w"
        return fields.joined(separator: " ")
    }

    /// Every position one legal move away from `position`, plus itself.
    static func neighbourhood(of position: Position) -> [Position] {
        var out = [position]
        for from in Square.allCases {
            guard let piece = position.piece(at: from), piece.color == position.sideToMove else { continue }
            for to in Square.allCases where to != from {
                var board = Board(position: position)
                guard board.canMove(pieceAt: from, to: to), board.move(pieceAt: from, to: to) != nil else {
                    continue
                }
                if case .promotion = board.state { continue }
                out.append(board.position)
            }
        }
        return out
    }

    /// A position in which the **bare** king is to move, the pawn's owner is
    /// winning, and the pawn's owner has a move that throws the win away.
    ///
    /// Searched for rather than written down. The catalogue deliberately ships
    /// no drill of this shape — `KPKDrillCatalogueTests` fails one — so a test
    /// about it has to build its own, and building one by hand would mean
    /// claiming a position is won and a move loses it on nothing but assertion.
    /// The search covers each catalogue position with either side to move, and
    /// everything one legal move from those.
    static func engineBlunderScenario() -> (start: Position, userMove: String, blunder: String)? {
        var seeds: [Position] = []
        for drill in EndgameDrill.kpkSet {
            for fen in [drill.fen, flippingSideToMove(drill.fen)] {
                guard let position = Position(fen: fen) else { continue }
                seeds.append(contentsOf: neighbourhood(of: position))
            }
        }

        for candidate in seeds {
            guard
                let pawn = candidate.pieces.first(where: { $0.kind == .pawn }),
                candidate.sideToMove != pawn.color,
                KPKBitbase.probe(position: candidate) == .win
            else { continue }
            for userMove in moves(from: candidate).keeping {
                var board = Board(position: candidate)
                guard PuzzleSolveMachine.apply(uci: userMove, to: &board) else { continue }
                guard let blunder = moves(from: board.position).changing.first else { continue }
                return (candidate, userMove, blunder)
            }
        }
        return nil
    }
}

// MARK: - The diagnosis

/// The drill is the one flow in the app where "the move that lost it" is not an
/// opinion: for king and pawn the bitbase knows it exactly. These pin that the
/// run keeps what it knew, and charges it to the right person.
@Suite("Endgame drill diagnosis")
struct EndgameDrillDiagnosisTests {

    /// The bug: a run reported a verdict and threw the diagnosis away, so a user
    /// who lost the opposition on move 3 and played twenty more moves was told
    /// only that the result had changed.
    @Test("A king-and-pawn slip names the move it went on and a move that would have kept it")
    func aSlipIsDiagnosed() throws {
        var diagnosed = 0
        for drill in EndgameDrill.kpkSet {
            let start = try #require(Position(fen: drill.fen))
            let before = try #require(KPKBitbase.probe(position: start))
            // Only the drills that can be lost on the very first move; the rest
            // are covered by the catalogue suite, which walks deeper.
            guard let losing = KPKProbeSupport.moves(from: start).changing.first else { continue }

            var run = try #require(EndgameDrillRun(drill: drill))
            let played = run.play(uci: losing)
            #expect(played, "\(drill.id): \(losing) is legal in the starting position")

            let lapse = try #require(run.lapse, "\(drill.id): the result went and the run did not say where")
            #expect(run.lostTheoreticalResult)
            #expect(lapse.moveNumber == 1)
            #expect(lapse.was == before)
            #expect(!lapse.played.isEmpty)

            let keeps = try #require(
                lapse.keeps,
                "\(drill.id): the run only just had this result, so some move must still hold it"
            )
            #expect(keeps != lapse.played)
            diagnosed += 1
        }
        #expect(diagnosed > 0, "no drill in the set could be lost on move one, so nothing was tested")
    }

    /// The one shape where "compare against the start" and "compare against the
    /// move before" disagree: the user is the bare king in a position the pawn's
    /// owner wins, so the *engine* is the only side that can make the result
    /// better. Against the start, every user move after such a blunder reads as
    /// "the result changed on your move" — for a change they did not make.
    @Test("A change the engine made is not charged to the user")
    func theEnginesOwnBlunderIsNotTheUsersLapse() throws {
        let scenario = try #require(
            KPKProbeSupport.engineBlunderScenario(),
            "no won pawn ending near the catalogue can be thrown away by the side that owns it"
        )
        let drill = EndgameDrill(
            id: "test.kpk.engineBlunder",
            kind: .kpk,
            title: "Bare king against a won pawn ending",
            fen: scenario.start.fen,
            target: .theoreticalResult
        )
        var run = try #require(EndgameDrillRun(drill: drill))

        let firstPlayed = run.play(uci: scenario.userMove)
        #expect(firstPlayed)
        #expect(!run.lostTheoreticalResult)

        let blunderPlayed = run.play(uci: scenario.blunder)
        #expect(blunderPlayed)
        #expect(!run.lostTheoreticalResult, "the engine moved, not the user")

        let userSecond = try #require(KPKProbeSupport.moves(from: run.board.position).keeping.first)
        let secondPlayed = run.play(uci: userSecond)
        #expect(secondPlayed)
        #expect(!run.lostTheoreticalResult, "the user held exactly what the engine left them")
        #expect(run.lapse == nil)
    }
}

// MARK: - How it ended

/// "It ended in a draw" is the outcome; stalemate, a threefold repetition and
/// the fifty-move rule are three different mistakes with three different fixes.
@Suite("Endgame drill draw reasons")
@MainActor
struct EndgameDrillDrawReasonTests {

    /// `kqk.2` starts with the black king on h8, and the queen a knight's move
    /// away from a cornered king is stalemate — which is the pattern the lesson
    /// used to promise "cannot stalemate". The run has to be able to say so.
    @Test("Stalemating a queen ending is reported as stalemate, not as a draw")
    func stalemateIsNamed() throws {
        let drill = try #require(EndgameDrill.basicMates.first { $0.id == "kqk.2" })
        var run = try #require(EndgameDrillRun(drill: drill))

        // Qd5-f7: a knight's move from h8, and every square the king has left.
        let played = run.play(uci: "d5f7")
        #expect(played, "Qd5-f7 is legal from the drill's own starting position")
        #expect(run.board.state == .draw(reason: .stalemate), "the fixture is not the stalemate it claims")
        #expect(run.result == .failed)
        #expect(run.drawReason == .stalemate)

        let model = EndgameDrillModel(kind: .kqk, opponent: NullDrillOpponent())
        let message = model.verdict(for: run).message
        #expect(message.contains("stalemate"), "the banner said only that it was a draw: \(message)")
        // The queen mate carries the longest cue in the catalogue, so this is
        // the worst case for the banner's four lines. `ConceptSchedulerTests`
        // holds the cue itself to 76; this holds what the drill wraps around it.
        #expect(
            message.count <= 116,
            "the banner cuts at four lines and this is \(message.count) characters: \(message)"
        )
    }

    /// The other half of the same bug: the cue quoted into that banner used to
    /// tell the user the move they had just played could not do what it had
    /// just done.
    @Test("The queen-mate cue no longer promises a pattern that cannot stalemate")
    func theQueenCueCarriesItsStopCondition() throws {
        let concept = try #require(TrainingConcept.catalogue.first { $0.id == "endgame.kqk" })
        let lookFor = concept.teaching.lookFor.lowercased()
        #expect(!lookFor.contains("cannot stalemate"))
        #expect(lookFor.contains("stalemate"), "the failure mode the drill punishes has to be named")
        // The banner quotes the first sentence alone, so the stop condition has
        // to survive that cut.
        #expect(concept.teaching.cue.lowercased().contains("edge"))
    }
}

// MARK: - What counts as done

@Suite("Endgame drill pass criteria")
struct EndgameDrillPassCriteriaTests {

    /// Lucena teaches the bridge, and the bridge ends with a queen. Requiring
    /// checkmate meant a user who executed the technique exactly still had to
    /// mate with queen and rook inside the same budget to be told they had.
    @Test("A win drill is passed by queening, not by mating afterwards")
    func queeningPassesTheWinDrill() throws {
        // Black's rook is on the second rank, so the new queen on b8 is out of
        // reach of everything Black has.
        let drill = EndgameDrill(
            id: "test.lucena.queened",
            kind: .lucena,
            title: "Queening with the new queen out of reach",
            fen: "8/1P6/8/4k3/8/8/2r5/K6R w - - 0 1",
            target: .win
        )
        var run = try #require(EndgameDrillRun(drill: drill))
        let queened = run.play(uci: "b7b8q")
        #expect(queened, "the pawn on b7 can queen")
        #expect(run.result == .passed)
        #expect(run.queenedOnMove == 1)
    }

    /// The guard on that rule, and deliberately the weakest one that is still
    /// true: a queen the opponent takes off the board this move has won nothing.
    /// It is not scored against the user either — the run simply carries on.
    @Test("Queening into a capture is not a win, and is not a loss either")
    func aHangingQueenDoesNotPass() throws {
        let drill = EndgameDrill(
            id: "test.lucena.hangingQueen",
            kind: .lucena,
            title: "Queening next to the defending rook",
            fen: "2r5/1P6/8/4k3/8/8/8/K6R w - - 0 1",
            target: .win
        )
        var run = try #require(EndgameDrillRun(drill: drill))
        let queened = run.play(uci: "b7b8q")
        #expect(queened, "the pawn on b7 can queen")
        #expect(run.result == .inProgress)
        #expect(run.queenedOnMove == nil)
    }

    /// Trading the rooks off into a drawn king and pawn ending is a *correct*
    /// way to hold a rook ending, and the one a 1200 is most likely to find.
    /// Counting rooks scored it as a failed hold at the budget — the drill
    /// punished the cleanest draw on the board.
    @Test("A hold that traded into a drawn pawn ending passes")
    func rooksOffIsStillAHold() throws {
        let fen = "8/8/8/8/8/2k5/2P5/2K5 b - - 0 1"
        let start = try #require(Position(fen: fen))
        try #require(KPKBitbase.probe(position: start) == .draw)

        let drill = EndgameDrill(
            id: "test.philidor.rooksOff",
            kind: .philidor,
            title: "Rooks traded, king in front of the pawn",
            fen: fen,
            target: .hold
        )
        // A one-move budget: the interesting part is what the criterion says at
        // the budget, not the twenty-four shuffles in front of it.
        var run = try #require(
            EndgameDrillRun(drill: drill, tuning: EndgameDrillTuning(philidorHoldMoves: 1))
        )
        let holding = try #require(KPKProbeSupport.moves(from: start).keeping.first)
        let held = run.play(uci: holding)
        #expect(held)
        #expect(run.result == .passed, "the draw was held with no rook left to hold it with")
    }
}
