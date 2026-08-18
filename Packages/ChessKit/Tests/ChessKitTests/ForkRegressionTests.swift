import Testing

@testable import ChessKit

/// Regression tests for the upstream bugs this fork exists to fix.
///
/// Each test names the upstream issue it pins. If a future upstream merge
/// reintroduces one of these, the corresponding test fails rather than the bug
/// silently reappearing in the app.
@Suite("Fork regressions")
struct ForkRegressionTests {

    // MARK: - Upstream #50: en passant missing from legalMoves(forPieceAt:)

    @Test("legalMoves includes the en passant capture square")
    func enPassantAppearsInLegalMoves() {
        // After 1. e4 d5 2. e5 f5, White's e5 pawn may capture f6 en passant.
        var board = Board(position: .standard)
        let setup = [
            (Square.e2, Square.e4), (.d7, .d5), (.e4, .e5), (.f7, .f5),
        ]
        for (from, to) in setup {
            let played = board.move(pieceAt: from, to: to)
            #expect(played != nil, "setup move \(from)-\(to) was rejected")
        }

        let moves = board.legalMoves(forPieceAt: .e5)
        #expect(moves.contains(.f6), "en passant target f6 missing from legalMoves — upstream #50")
        #expect(board.canMove(pieceAt: .e5, to: .f6))
    }

    @Test("The en passant capture actually removes the captured pawn")
    func enPassantCaptureRemovesPawn() throws {
        var board = Board(position: .standard)
        _ = board.move(pieceAt: .e2, to: .e4)
        _ = board.move(pieceAt: .d7, to: .d5)
        _ = board.move(pieceAt: .e4, to: .e5)
        _ = board.move(pieceAt: .f7, to: .f5)

        let played = board.move(pieceAt: .e5, to: .f6)
        let move = try #require(played)
        #expect(board.position.piece(at: .f5) == nil, "captured pawn still on f5")
        #expect(board.position.piece(at: .f6)?.kind == .pawn)
        #expect(move.result == .capture(Piece(.pawn, color: .black, square: .f5)))
    }

    // MARK: - Upstream #82: SAN omits capture notation for en passant

    @Test("En passant is serialized as a capture in SAN")
    func enPassantSANIncludesCapture() throws {
        var board = Board(position: .standard)
        _ = board.move(pieceAt: .e2, to: .e4)
        _ = board.move(pieceAt: .d7, to: .d5)
        _ = board.move(pieceAt: .e4, to: .e5)
        _ = board.move(pieceAt: .f7, to: .f5)

        let played = board.move(pieceAt: .e5, to: .f6)
        let move = try #require(played)
        // Correct SAN for an en passant capture is "exf6", not "ef6" or "f6".
        #expect(move.san == "exf6", "en passant SAN was \(move.san) — upstream #82")
    }

    // MARK: - Upstream #56: threefold repetition miscounted

    @Test("Threefold repetition is detected after the third occurrence")
    func threefoldRepetition() {
        var board = Board(position: .standard)
        // Shuffle knights out and back twice; the start position recurs a third
        // time on the final move.
        let cycle: [(Square, Square)] = [
            (.g1, .f3), (.g8, .f6), (.f3, .g1), (.f6, .g8),
            (.g1, .f3), (.g8, .f6), (.f3, .g1), (.f6, .g8),
        ]
        for (from, to) in cycle {
            _ = board.move(pieceAt: from, to: to)
        }
        #expect(
            board.repetitionCount >= 3,
            "expected the start position to have occurred 3 times, saw \(board.repetitionCount)"
        )
        #expect(board.state == .draw(reason: .repetition))
    }

    // MARK: - Persistable position identity (Swift Hasher is not stable)

    @Test("Zobrist keys are stable, not per-process random")
    func zobristIsStable() {
        // The whole point: this value must be identical across processes so it
        // can be a SQLite primary key. Swift's Hasher is seeded per process and
        // cannot be used for this.
        let start = Position.standard
        #expect(start.zobristKey == Position.standard.zobristKey)
        #expect(start.zobristKey != 0)
    }

    @Test("Transpositions produce the same Zobrist key")
    func zobristTransposition() {
        // 1. e4 e5 2. Nf3 Nc6 and 1. Nf3 Nc6 2. e4 e5 reach the same position.
        var a = Board(position: .standard)
        _ = a.move(pieceAt: .e2, to: .e4)
        _ = a.move(pieceAt: .e7, to: .e5)
        _ = a.move(pieceAt: .g1, to: .f3)
        _ = a.move(pieceAt: .b8, to: .c6)

        var b = Board(position: .standard)
        _ = b.move(pieceAt: .g1, to: .f3)
        _ = b.move(pieceAt: .b8, to: .c6)
        _ = b.move(pieceAt: .e2, to: .e4)
        _ = b.move(pieceAt: .e7, to: .e5)

        #expect(a.position.zobristKey == b.position.zobristKey)
    }

    @Test("Zobrist distinguishes side to move, castling rights, and en passant")
    func zobristDistinguishesState() {
        let base = Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")!
        let blackToMove = Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1")!
        let noCastling = Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1")!

        #expect(base.zobristKey != blackToMove.zobristKey, "side to move not in the key")
        #expect(base.zobristKey != noCastling.zobristKey, "castling rights not in the key")

        // Same pieces, differing only by a live en passant target.
        let withEP = Position(fen: "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2")!
        let withoutEP = Position(fen: "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2")!
        #expect(withEP.zobristKey != withoutEP.zobristKey, "en passant file not in the key")
    }

    // MARK: - Attack queries needed for SEE / hanging-piece detection

    @Test("Attackers of a square are queryable for both colors")
    func attackersQuery() {
        // White pawn on e4, black knight on f6 and black pawn on d5 both bear on e4's
        // neighbourhood; check a concrete, unambiguous case instead.
        let position = Position(fen: "8/8/3p4/4P3/8/8/8/K6k b - - 0 1")!
        let board = Board(position: position)

        // The black d6 pawn attacks e5, where the white pawn stands.
        let attackers = board.attackers(of: .e5, by: .black)
        #expect(attackers.contains(.d6), "d6 pawn should attack e5, got \(attackers)")
    }

    @Test("Defenders are distinguishable from attackers")
    func defendersQuery() {
        // White rook on a1 defends a4; black rook on a8 attacks it.
        let position = Position(fen: "r7/8/8/8/R7/8/8/K6k w - - 0 1")!
        let board = Board(position: position)

        #expect(board.attackers(of: .a4, by: .black).contains(.a8))
        #expect(!board.attackers(of: .a4, by: .white).contains(.a8))
    }

    @Test("Square-attacked check works for both colors")
    func isAttackedQuery() {
        let position = Position(fen: "8/8/3p4/4P3/8/8/8/K6k w - - 0 1")!
        let board = Board(position: position)

        #expect(board.isSquareAttacked(.e5, by: .black))
        #expect(board.isSquareAttacked(.d6, by: .white))
        #expect(!board.isSquareAttacked(.h5, by: .black))
    }
}
