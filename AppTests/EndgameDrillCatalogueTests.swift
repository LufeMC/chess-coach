//
//  EndgameDrillCatalogueTests.swift
//  ChessCoachTests
//

import AnalysisKit
import ChessKit
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

// MARK: - KPK catalogue

/// Guards the property that makes a KPK drill worth playing: the user must be
/// able to both pass it and fail it.
///
/// `EndgameDrillRun` grades KPK by comparing the bitbase verdict after each user
/// move against the verdict at the start, so only two shapes actually test
/// anything — attacking a won position, or defending a drawn one. A user
/// *attacking a drawn* position cannot lose the draw against correct defence and
/// cannot be mated by a lone king, so no path through `evaluate()` fails. A user
/// *defending a won* position is lost by force, so no path passes.
///
/// The first shipped set had three of the former and one of the latter: four of
/// six drills graded nothing at all, while the catalogue comment claimed the mix
/// was the lesson. These tests walk the exact bitbase the app grades against, so
/// a future edit that reintroduces such a position fails here rather than
/// shipping a drill nobody can lose.
@Suite("KPK drill catalogue")
struct KPKDrillCatalogueTests {

    /// How far to look for a losing move.
    ///
    /// Every drill in the shipping set can be lost by ply 3 — an attacker on the
    /// first move, a defender when the attacking king steps up — so 8 is
    /// generous. It is also deliberately not larger: the search only runs to
    /// exhaustion when a drill *cannot* be lost, which is the failing case, and
    /// at 14 plies that took six minutes to report. A bad drill should fail this
    /// suite in seconds, in a suite the project expects to run constantly.
    static let horizon = 8

    /// Ceiling on positions carried between plies, so a pathological catalogue
    /// entry cannot turn this into an exhaustive KPK walk.
    static let frontierLimit = 3_000

    /// Every legal move for the side to move, with the position it produces.
    static func successors(of position: Position) -> [Position] {
        var out: [Position] = []
        for from in Square.allCases {
            guard let piece = position.piece(at: from), piece.color == position.sideToMove else { continue }
            for to in Square.allCases where to != from {
                var board = Board(position: position)
                guard board.move(pieceAt: from, to: to) != nil else { continue }
                out.append(board.position)
            }
        }
        return out
    }

    /// Whether `position` still holds `expected` for the pawn's owner.
    ///
    /// A position that has left KPK — the pawn was captured or promoted — has no
    /// bitbase entry. Bare kings keep a draw and throw away a win, which is the
    /// honest reading of "the pawn is gone".
    static func keeps(_ expected: KPKOutcome, in position: Position) -> Bool {
        guard let now = KPKBitbase.probe(position: position) else { return expected == .draw }
        return now == expected
    }

    /// The first ply at which the user has a move that throws the theoretical
    /// result away, searching only lines where they have held it so far.
    static func firstLosablePly(from start: Position, expected: KPKOutcome) -> Int? {
        let user = start.sideToMove
        var frontier = [start]
        var seen: Set<String> = [start.fen]

        for ply in 0..<horizon {
            var next: [Position] = []
            for position in frontier {
                let isUserToMove = position.sideToMove == user
                for after in successors(of: position) {
                    if isUserToMove, !keeps(expected, in: after) { return ply + 1 }
                    guard keeps(expected, in: after),
                        KPKBitbase.probe(position: after) != nil,
                        !seen.contains(after.fen)
                    else { continue }
                    seen.insert(after.fen)
                    next.append(after)
                }
            }
            if next.isEmpty { return nil }
            frontier = next.count > frontierLimit ? Array(next.prefix(frontierLimit)) : next
        }
        return nil
    }

    @Test("Every KPK drill position parses and is a genuine three-piece KPK position")
    func positionsAreKPK() throws {
        for drill in EndgameDrill.kpkSet {
            let position = try #require(Position(fen: drill.fen), "\(drill.id) has an unparseable FEN")
            #expect(position.pieces.count == 3, "\(drill.id) is not a three-piece position")
            #expect(
                KPKBitbase.probe(position: position) != nil,
                "\(drill.id) is not a position the bitbase can rule on"
            )
        }
    }

    /// The bug this suite exists for.
    @Test("Every KPK drill can be failed — no drill passes by shuffling")
    func everyDrillIsLosable() throws {
        for drill in EndgameDrill.kpkSet {
            let position = try #require(Position(fen: drill.fen))
            let expected = try #require(KPKBitbase.probe(position: position))
            let ply = Self.firstLosablePly(from: position, expected: expected)
            #expect(
                ply != nil,
                """
                \(drill.id) "\(drill.title)" cannot be failed: no move within \(Self.horizon) plies \
                changes the theoretical result, so EndgameDrillRun passes it for any play at all.
                """
            )
        }
    }

    /// The mirror of the above, and the shape `kpk.4` used to be: a defender in a
    /// position the attacker wins by force has no move that passes.
    @Test("No KPK drill asks the user to hold a position that is lost by force")
    func noDrillIsUnpassable() throws {
        for drill in EndgameDrill.kpkSet {
            let position = try #require(Position(fen: drill.fen))
            let expected = try #require(KPKBitbase.probe(position: position))
            let pawn = try #require(position.pieces.first { $0.kind == .pawn })
            let userIsAttacker = position.sideToMove == pawn.color
            #expect(
                !(expected == .win && !userIsAttacker),
                """
                \(drill.id) "\(drill.title)" puts the user on the bare-king side of a position the \
                pawn's owner wins by force. Every terminal path in EndgameDrillRun.evaluate() \
                returns .failed, and a lone king cannot deliver the mate that would pass it.
                """
            )
            #expect(
                !(expected == .draw && userIsAttacker),
                """
                \(drill.id) "\(drill.title)" puts the user on the pawn side of a drawn position. \
                Correct defence keeps the draw whatever they play and a lone king cannot mate \
                them, so the drill cannot be failed.
                """
            )
        }
    }

    /// The catalogue comment promises a mix, and the promise is load-bearing:
    /// a set that is all one shape lets the user pass by always pushing or
    /// always shuffling.
    @Test("The set mixes positions to convert with positions to hold")
    func setIsMixed() throws {
        var toConvert = 0
        var toHold = 0
        for drill in EndgameDrill.kpkSet {
            let position = try #require(Position(fen: drill.fen))
            let expected = try #require(KPKBitbase.probe(position: position))
            let pawn = try #require(position.pieces.first { $0.kind == .pawn })
            if position.sideToMove == pawn.color, expected == .win { toConvert += 1 }
            if position.sideToMove != pawn.color, expected == .draw { toHold += 1 }
        }
        #expect(toConvert >= 2, "the set needs positions the user has to convert")
        #expect(toHold >= 2, "the set needs positions the user has to hold")
        #expect(toConvert + toHold == EndgameDrill.kpkSet.count)
    }
}

// MARK: - Rook endings

/// Guards the two properties that make the rook-ending drills worth playing:
/// each position is actually the technique it is named after, and a family holds
/// more than one of them.
///
/// The set that shipped first held one Lucena and one "Philidor" whose defending
/// king stood on b5, whose rook sat on White's second rank and whose pawn was
/// three ranks from the sixth. It was drawn — for reasons that have nothing to
/// do with the third-rank defence the paired lesson teaches — so twenty-five
/// moves of anything at all passed it, and `r3.rookEndings` was cleared by a
/// technique that was never once performed. These tests read the geometry the
/// techniques are defined by, so a position that merely evaluates well cannot
/// stand in for one that teaches the method.
@Suite("Rook ending catalogue")
struct RookEndingCatalogueTests {

    /// The rank a defender's "third rank" is, counted from their own side.
    static func thirdRank(for color: Piece.Color) -> Int { color == .white ? 3 : 6 }

    /// The rank a pawn's fifth is, counted from its owner's side.
    static func fifthRank(for color: Piece.Color) -> Int { color == .white ? 5 : 4 }

    /// The rank a pawn's seventh is, counted from its owner's side.
    static func seventhRank(for color: Piece.Color) -> Int { color == .white ? 7 : 2 }

    /// The rank a pawn promotes on.
    static func promotionRank(for color: Piece.Color) -> Int { color == .white ? 8 : 1 }

    @Test("Every rook-ending drill is king, rook and pawn against king and rook")
    func materialIsARookEnding() throws {
        for drill in EndgameDrill.rookEndings {
            let position = try #require(Position(fen: drill.fen), "\(drill.id) has an unparseable FEN")
            let pieces = position.pieces
            #expect(pieces.count == 5, "\(drill.id) is not a five-piece rook ending")
            #expect(pieces.filter { $0.kind == .pawn }.count == 1, "\(drill.id) needs exactly one pawn")
            #expect(pieces.filter { $0.kind == .rook }.count == 2, "\(drill.id) needs a rook each")
            let pawn = try #require(pieces.first { $0.kind == .pawn })
            #expect(
                pieces.contains { $0.color == pawn.color && $0.kind == .rook },
                "\(drill.id): the attacker has no rook"
            )
            #expect(
                pieces.contains { $0.color != pawn.color && $0.kind == .rook },
                "\(drill.id): the defender has no rook"
            )
        }
    }

    /// The drill always puts the user on move, so which side of the technique
    /// they are practising is decided by the FEN and nothing else.
    @Test("The user attacks in Lucena and defends in Philidor")
    func theUserIsOnTheRightSide() throws {
        for drill in EndgameDrill.rookEndings {
            let position = try #require(Position(fen: drill.fen))
            let pawn = try #require(position.pieces.first { $0.kind == .pawn })
            switch drill.kind {
            case .lucena:
                #expect(
                    position.sideToMove == pawn.color,
                    "\(drill.id): Lucena is the attacker's technique, so the user must own the pawn"
                )
                #expect(drill.target == .win, "\(drill.id): a Lucena is won, not held")
            case .philidor:
                #expect(
                    position.sideToMove != pawn.color,
                    "\(drill.id): Philidor is the defender's technique, so the user must not own the pawn"
                )
                #expect(drill.target == .hold, "\(drill.id): a Philidor is held, not won")
            default:
                Issue.record("\(drill.id) is not a rook ending")
            }
        }
    }

    /// The bug this suite exists for.
    ///
    /// A Philidor is a *geometry*: the defending king in front of the pawn, the
    /// defending rook on its own third rank, and the pawn still on the fifth so
    /// that the third rank is what stops the attacking king coming to the sixth.
    /// Take any one of those away and the position may still be drawn, but it is
    /// no longer the position the lesson describes.
    @Test("Every Philidor is a third-rank defence")
    func philidorGeometry() throws {
        let drills = EndgameDrill.drills(kind: .philidor)
        #expect(!drills.isEmpty)
        for drill in drills {
            let position = try #require(Position(fen: drill.fen))
            let pieces = position.pieces
            let pawn = try #require(pieces.first { $0.kind == .pawn })
            let defender = position.sideToMove
            let defendingKing = try #require(pieces.first { $0.color == defender && $0.kind == .king })
            let defendingRook = try #require(pieces.first { $0.color == defender && $0.kind == .rook })

            #expect(
                defendingKing.square.file == pawn.square.file,
                """
                \(drill.id): the defending king is on \(defendingKing.square.notation), not in front of \
                the pawn on \(pawn.square.notation). Philidor starts with the king on the queening file.
                """
            )
            #expect(
                defendingRook.square.rank.value == Self.thirdRank(for: defender),
                """
                \(drill.id): the defending rook starts on \(defendingRook.square.notation), not on its \
                own third rank. The third rank is the whole technique.
                """
            )
            #expect(
                pawn.square.rank.value == Self.fifthRank(for: pawn.color),
                """
                \(drill.id): the pawn starts on \(pawn.square.notation). Philidor is the defence \
                *before* the pawn reaches the sixth — once it is there the rook belongs behind it.
                """
            )
        }
    }

    /// A Lucena is the mirror geometry: the pawn one step from queening, the
    /// attacking king on the square it wants to vacate, and a rook cutting the
    /// defending king off on another file. Without the cut there is no bridge to
    /// build.
    @Test("Every Lucena has the pawn on the seventh and the king in its way")
    func lucenaGeometry() throws {
        let drills = EndgameDrill.drills(kind: .lucena)
        #expect(!drills.isEmpty)
        for drill in drills {
            let position = try #require(Position(fen: drill.fen))
            let pieces = position.pieces
            let pawn = try #require(pieces.first { $0.kind == .pawn })
            let attackingKing = try #require(pieces.first { $0.color == pawn.color && $0.kind == .king })
            let attackingRook = try #require(pieces.first { $0.color == pawn.color && $0.kind == .rook })

            #expect(
                pawn.square.rank.value == Self.seventhRank(for: pawn.color),
                "\(drill.id): the pawn is on \(pawn.square.notation), not one square from queening"
            )
            #expect(
                attackingKing.square.file == pawn.square.file
                    && attackingKing.square.rank.value == Self.promotionRank(for: pawn.color),
                """
                \(drill.id): the attacking king is on \(attackingKing.square.notation), not on the \
                queening square. Lucena is the problem of getting it out of the pawn's way.
                """
            )
            #expect(
                attackingRook.square.file != pawn.square.file,
                "\(drill.id): the attacking rook shares the pawn's file, so it cuts nothing off"
            )
        }
    }

    /// What `drillCleanStreakRequired` is supposed to mean.
    ///
    /// The gate asks for a streak of clean runs. With one position per family
    /// that is the same diagram reproduced twice, which is memory of a picture —
    /// the failure mode `CardPolicy` spends sixty lines keeping out of the puzzle
    /// deck. The streak is only evidence of a method if the pictures differ.
    @Test("A clean streak spans more than one position")
    func familiesHoldEnoughPositions() {
        let required = DomainTuning.default.curriculum.drillCleanStreakRequired
        for kind in [EndgameDrillKind.lucena, .philidor] {
            let drills = EndgameDrill.drills(kind: kind)
            #expect(
                drills.count >= required,
                """
                \(kind.rawValue) ships \(drills.count) position(s) and the curriculum asks for \
                \(required) clean runs, so the streak is the same position repeated.
                """
            )
            #expect(
                Set(drills.map(\.fen)).count == drills.count,
                "\(kind.rawValue) ships the same position twice"
            )
        }
    }

    @Test("No two drills anywhere in the catalogue are the same position")
    func catalogueHasNoDuplicates() {
        let fens = EndgameDrill.catalogue.map(\.fen)
        #expect(Set(fens).count == fens.count, "the catalogue repeats a position")
        let ids = EndgameDrill.catalogue.map(\.id)
        #expect(Set(ids).count == ids.count, "the catalogue repeats an id")
    }
}

// MARK: - Hold pass criteria

/// A hold ends when the attacker gets a new piece off the pawn, whatever piece
/// it is.
///
/// The budget check counted enemy *queens*, so an under-promotion to a rook —
/// rook and rook against rook, which wins as comfortably as queen against rook —
/// read as a successful hold. Both are now failed at the moment they happen
/// rather than at the end of the budget, because seventeen further moves spent
/// defending a position that is already lost teach nothing about the move that
/// lost it.
@Suite("Hold pass criteria")
struct HoldPassCriteriaTests {

    /// King, rook and pawn against king and rook, with the pawn one move from
    /// queening out of the defending rook's reach. Black — the user — is to
    /// move, so the promotion lands on the engine's move, which is where a hold
    /// actually loses.
    static let aboutToQueen = EndgameDrill(
        id: "test.philidor.aboutToQueen",
        kind: .philidor,
        title: "About to queen",
        fen: "8/1P6/8/8/3k4/8/6r1/K6R b - - 0 1",
        target: .hold
    )

    private func runAfterPromotion(to suffix: String) throws -> EndgameDrillRun {
        var run = try #require(EndgameDrillRun(drill: Self.aboutToQueen))
        // `play` mutates, and `#expect` captures its argument in an escaping
        // closure where `run` is immutable — so the call has to land first.
        let waited = run.play(uci: "d4d5")
        #expect(waited, "the user's waiting move should be legal")
        #expect(run.result == .inProgress, "one waiting move cannot end the drill")
        let promoted = run.play(uci: "b7b8" + suffix)
        #expect(promoted, "the promotion should be legal")
        return run
    }

    @Test("A queen the defender cannot take ends the hold at once")
    func queeningEndsTheHold() throws {
        let run = try runAfterPromotion(to: "q")
        #expect(run.result == .failed)
        #expect(run.userMoveCount == 1, "the run should end on the move that lost it, not at the budget")
    }

    @Test("An under-promotion to a rook ends the hold too")
    func underPromotionEndsTheHold() throws {
        let run = try runAfterPromotion(to: "r")
        #expect(
            run.result == .failed,
            "rook and rook against rook is not a hold, whatever the piece is called"
        )
    }

    /// Surviving the budget with the material still on the board is what a
    /// textbook Philidor and a collapsed defence look like to a piece count.
    /// The run therefore passes *provisionally* and says so, and the screen puts
    /// the position to the engine before the streak is written.
    private func runAtTheBudget() throws -> EndgameDrillRun {
        var run = try #require(
            EndgameDrillRun(drill: Self.aboutToQueen, tuning: EndgameDrillTuning(philidorHoldMoves: 1))
        )
        let waited = run.play(uci: "d4d5")
        #expect(waited, "the user's waiting move should be legal")
        #expect(run.result == .passed, "the budget is used, and nothing on the board disproves the hold")
        #expect(run.needsHoldRuling, "material cannot prove a rook ending is drawn")
        return run
    }

    @Test("A hold the board cannot prove is put to the engine")
    func unprovenHoldAsksForARuling() throws {
        var run = try runAtTheBudget()
        // White — the attacking side — is to move, so a large positive score is
        // a large negative one for the user.
        run.applyHoldRuling(centipawns: 600)
        #expect(run.result == .failed, "a lost position is not a hold, however many moves it lasted")
        #expect(run.holdRuledLost, "the banner has to be able to say why")
    }

    @Test("A level ruling leaves the hold standing")
    func drawnRulingKeepsThePass() throws {
        var run = try runAtTheBudget()
        run.applyHoldRuling(centipawns: 20)
        #expect(run.result == .passed)
        #expect(!run.holdRuledLost)
    }

    /// The one error this must not make. A search that never happened — the
    /// engine busy, the lease preempted, no engine at all in a test — must not
    /// cost a user a draw they held.
    @Test("No ruling leaves the hold standing")
    func silenceKeepsThePass() throws {
        var run = try runAtTheBudget()
        run.applyHoldRuling(centipawns: nil)
        #expect(run.result == .passed)
        #expect(!run.needsHoldRuling, "the question has been asked and answered, even if the answer was nothing")
    }
}

// MARK: - The call

/// The KPK set is there to teach one thing — telling the won pawn endings from
/// the drawn ones *before* you trade into them — and moves alone cannot measure
/// it. A drawn position held for sixty moves of shuffling passes whether or not
/// the user ever knew it was drawn.
///
/// `EndgameDrillRun` therefore takes a verdict before the first move and refuses
/// to call the run clean when it was wrong. These pin that contract; the screen
/// that asks the question is the other half of it.
@Suite("The pre-game call")
struct DrillCallTests {

    /// A rook pawn with the bare king in the corner in front of it: drawn, and
    /// stalemate is one white move away, so the whole run fits in a test.
    static let drawnForTheAttacker = EndgameDrill(
        id: "test.kpk.rookPawnDraw",
        kind: .kpk,
        title: "Rook pawn: the corner draws",
        fen: "k7/P7/K7/8/8/8/8/8 w - - 0 1",
        target: .theoreticalResult
    )

    @Test("The call is phrased from the user's side of the board")
    func theCallIsTheUsers() throws {
        let run = try #require(EndgameDrillRun(drill: Self.drawnForTheAttacker))
        #expect(run.startingCallForUser == .draw)
        #expect(run.callWasCorrect == nil, "a run nobody asked is not a run they got wrong")

        for drill in EndgameDrill.kpkSet {
            let kpk = try #require(EndgameDrillRun(drill: drill))
            #expect(kpk.startingCallForUser != nil, "\(drill.id) is scored on a call it cannot ask for")
        }
        for drill in EndgameDrill.basicMates + EndgameDrill.rookEndings {
            let other = try #require(EndgameDrillRun(drill: drill))
            #expect(
                other.startingCallForUser == nil,
                "\(drill.id) is not a set-scored family and must not be asked to call a verdict"
            )
        }
    }

    @Test("Holding the draw after calling it right passes")
    func rightCallPasses() throws {
        var run = try #require(EndgameDrillRun(drill: Self.drawnForTheAttacker))
        run.recordCall(.draw)
        #expect(run.callWasCorrect == true)
        let held = run.play(uci: "a6b6")
        #expect(held, "Kb6 is legal and stalemates")
        #expect(run.drawReason == .stalemate)
        #expect(run.result == .passed)
        #expect(run.isClean)
    }

    /// The finding this exists for: the same sixty moves, the same result, and a
    /// user who did not know which one they were holding.
    @Test("The same play fails when the position was called wrong")
    func wrongCallFails() throws {
        var run = try #require(EndgameDrillRun(drill: Self.drawnForTheAttacker))
        run.recordCall(.win)
        #expect(run.callWasCorrect == false)
        #expect(run.misjudgedStart)
        let held = run.play(uci: "a6b6")
        #expect(held)
        #expect(run.result == .failed, "a draw held by someone who thought it was won proves nothing")
        #expect(run.isClean == false)
        #expect(run.drawReason == .stalemate, "the run still says how it ended")
    }

    @Test("The call cannot be revised once the position is under way")
    func theCallIsFinal() throws {
        var run = try #require(EndgameDrillRun(drill: Self.drawnForTheAttacker))
        run.recordCall(.win)
        run.recordCall(.draw)
        #expect(run.recordedCall == .win, "a second call would let the board answer the question")
    }
}
