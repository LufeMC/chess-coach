//
//  SEETests.swift
//  AnalysisKitTests
//

import ChessKit
import Testing

@testable import AnalysisKit

@Suite("Static exchange evaluation")
struct SEETests {

    /// Builds a position and the `Move` for a UCI capture in it.
    private func setup(_ fen: String, _ uci: String) throws -> (Position, Move) {
        let position = try #require(Position(fen: fen))
        let applied = try #require(LineReplay.apply(uci: uci, to: position))
        return (position, applied.move)
    }

    @Test("A rook taking a pawn defended by a pawn loses material")
    func defendedPawnCapture() throws {
        // Black pawn d5 is guarded by the c6 pawn; Rxd5 cxd5 costs 400.
        let (position, move) = try setup("4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1", "d1d5")
        #expect(SEE.seeOfCapture(position: position, move: move) == -400)
    }

    @Test("A free piece is worth its full value")
    func hangingPiece() throws {
        let fen = "4k3/8/8/3n4/8/8/8/3RK3 w - - 0 1"
        let (position, move) = try setup(fen, "d1d5")
        #expect(SEE.seeOfCapture(position: position, move: move) == PieceValues.knight)

        let board = Board(position: position)
        #expect(SEE.see(board: board, target: .d5, side: .white) == PieceValues.knight)
    }

    @Test("An equal exchange nets nothing")
    func equalTrade() throws {
        // exd5 cxd5: a pawn for a pawn.
        let (position, move) = try setup("4k3/8/2p5/3p4/4P3/8/8/4K3 w - - 0 1", "e4d5")
        #expect(SEE.seeOfCapture(position: position, move: move) == 0)
    }

    /// The case that separates a real SEE from a one-ply guess: the rook behind
    /// the rook only enters the exchange once the front rook has moved, so the
    /// attacker set has to be recomputed against each intermediate occupancy.
    @Test("An x-ray battery flips the sign of the same capture")
    func batteryXRay() throws {
        let single = "3rk3/8/8/3p4/8/8/3R4/4K3 w - - 0 1"
        let (singlePosition, singleMove) = try setup(single, "d2d5")
        #expect(SEE.seeOfCapture(position: singlePosition, move: singleMove) == -400)

        // Same position plus a second rook on d1, x-raying through d2.
        let doubled = "3rk3/8/8/3p4/8/8/3R4/3RK3 w - - 0 1"
        let (doubledPosition, doubledMove) = try setup(doubled, "d2d5")
        #expect(SEE.seeOfCapture(position: doubledPosition, move: doubledMove) == 100)
    }

    @Test("The swap value is never negative — a side can always decline")
    func swapNeverNegative() throws {
        let position = try #require(Position(fen: "4k3/8/2p5/3p4/8/8/8/3RK3 w - - 0 1"))
        #expect(SEE.see(position: position, target: .d5, side: .white) == 0)
    }

    @Test("An unattacked square is worth nothing")
    func noAttackers() throws {
        let position = try #require(Position(fen: "4k3/8/8/3n4/8/8/8/4K3 w - - 0 1"))
        #expect(SEE.see(position: position, target: .d5, side: .white) == 0)
    }

    @Test("A quiet move onto a defended square scores its own loss")
    func quietMoveExchange() throws {
        // Rd1-d5 lands next to the c6 pawn with nothing to capture.
        let position = try #require(Position(fen: "4k3/8/2p5/8/8/8/8/3RK3 w - - 0 1"))
        let applied = try #require(LineReplay.apply(uci: "d1d5", to: position))
        #expect(SEE.staticExchange(position: position, move: applied.move) == -PieceValues.rook)
        #expect(SEE.seeOfCapture(position: position, move: applied.move) == nil)
    }

    @Test("En passant removes the pawn from its real square")
    func enPassant() throws {
        // White d5 pawn takes the black e-pawn that has just run past it.
        let position = try #require(Position(fen: "4k3/8/8/3Pp3/8/8/8/4K3 w - e6 0 1"))
        let applied = try #require(LineReplay.apply(uci: "d5e6", to: position))
        #expect(SEE.seeOfCapture(position: position, move: applied.move) == PieceValues.pawn)
    }

    @Test("Capture-promotions count the new queen")
    func promotionCapture() throws {
        // b7xa8=Q takes a rook and promotes; nothing recaptures.
        let position = try #require(Position(fen: "r3k3/1P6/8/8/8/8/8/4K3 w - - 0 1"))
        let applied = try #require(LineReplay.apply(uci: "b7a8q", to: position))
        let value = try #require(SEE.seeOfCapture(position: position, move: applied.move))
        #expect(value == PieceValues.rook + PieceValues.queen - PieceValues.pawn)
    }

    @Test("A king cannot start an exchange it would not survive")
    func kingCannotCaptureDefendedPiece() throws {
        // The knight on d2 is defended by the b4 bishop, so Kxd2 is not on.
        let position = try #require(Position(fen: "4k3/8/8/8/1b6/8/3n4/3K4 w - - 0 1"))
        #expect(SEE.see(position: position, target: .d2, side: .white) == 0)
    }

    @Test("Winning capture targets list every profitable capture")
    func winningTargets() throws {
        let position = try #require(Position(fen: "4k3/8/8/3n4/8/8/8/3RK3 w - - 0 1"))
        #expect(SEE.winningCaptureTargets(position: position, by: .white) == [.d5])
        #expect(SEE.hasWinningCapture(position: position, by: .black) == false)
    }
}

@Suite("Occupancy parity with ChessKit")
struct OccupancyParityTests {

    static let positions = [
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        "8/8/8/4k3/8/4P3/4K3/8 w - - 0 1"
    ]

    /// AnalysisKit re-implements attack generation so it can mutate occupancy
    /// mid-exchange. This test is the contract that keeps the two definitions
    /// identical — if the fork's semantics ever change, this fails first.
    @Test("Attacker sets match Board.attackers on every square", arguments: OccupancyParityTests.positions)
    func attackersMatch(fen: String) throws {
        let position = try #require(Position(fen: fen))
        let board = Board(position: position)
        let occupancy = Occupancy(position)

        for square in Square.allCases {
            for color in [Piece.Color.white, .black] {
                let expected = Set(board.attackers(of: square, by: color))
                let actual = Set(occupancy.attackers(of: square, by: color))
                #expect(expected == actual, "mismatch on \(square.notation) by \(color) in \(fen)")
            }
        }
    }

    @Test("Least valuable attacker agrees", arguments: OccupancyParityTests.positions)
    func leastValuableAttackerMatches(fen: String) throws {
        let position = try #require(Position(fen: fen))
        let board = Board(position: position)
        let occupancy = Occupancy(position)

        for square in Square.allCases {
            for color in [Piece.Color.white, .black] {
                let expected = board.leastValuableAttacker(of: square, by: color)?.kind
                let actual = occupancy.leastValuableAttacker(of: square, by: color)?.kind
                #expect(expected == actual, "mismatch on \(square.notation) by \(color) in \(fen)")
            }
        }
    }

    @Test("Square arithmetic refuses to wrap around the board")
    func squareOffsets() {
        #expect(Square.offset(.a1, files: -1, ranks: 0) == nil)
        #expect(Square.offset(.h8, files: 1, ranks: 0) == nil)
        #expect(Square.offset(.a1, files: 1, ranks: 1) == .b2)
        #expect(Square.e4.fileIndex == 4)
        #expect(Square.e4.rankIndex == 3)
        #expect(Square.e2.relativeRank(for: .white) == 2)
        #expect(Square.e7.relativeRank(for: .black) == 2)
    }
}
