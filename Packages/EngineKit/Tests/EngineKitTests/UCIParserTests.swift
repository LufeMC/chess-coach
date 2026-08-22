import Testing

@testable import EngineKit

@Suite("UCI parsing")
struct UCIParserTests {

    @Test("Parses a full info line")
    func parsesInfoLine() throws {
        let line = "info depth 20 seldepth 28 multipv 1 score cp 34 nodes 1234567 nps 987654 "
            + "hashfull 120 tbhits 0 time 1250 pv e2e4 e7e5 g1f3 b8c6"
        let info = try #require(UCIParser.parseInfo(line))

        #expect(info.depth == 20)
        #expect(info.selDepth == 28)
        #expect(info.multipv == 1)
        #expect(info.score == .centipawns(34))
        #expect(info.nodes == 1_234_567)
        #expect(info.nps == 987_654)
        #expect(info.timeMs == 1250)
        #expect(info.pv == ["e2e4", "e7e5", "g1f3", "b8c6"])
        #expect(info.bestMove == "e2e4")
    }

    @Test("Parses mate scores with sign")
    func parsesMateScore() throws {
        let positive = try #require(UCIParser.parseInfo("info depth 12 multipv 1 score mate 3 pv d1h5"))
        #expect(positive.score == .mate(3))

        let negative = try #require(UCIParser.parseInfo("info depth 12 multipv 1 score mate -2 pv a1a2"))
        #expect(negative.score == .mate(-2))
    }

    @Test("Keeps bounded scores rather than discarding the line")
    func parsesBoundedScore() throws {
        // A lowerbound score is still the best info at that depth; the final
        // line for the depth supersedes it.
        let info = try #require(UCIParser.parseInfo("info depth 15 multipv 1 score cp 120 lowerbound pv e2e4"))
        #expect(info.score == .centipawns(120))
    }

    @Test("Records which side of the window a bounded score fell on")
    func parsesScoreBound() throws {
        // The flag used to be dropped, which left a fail-high from a partial
        // iteration looking exactly like a finished evaluation — including to
        // the code that subtracts rank 2 from rank 1.
        let low = try #require(UCIParser.parseInfo("info depth 15 multipv 1 score cp 120 lowerbound pv e2e4"))
        #expect(low.bound == .lower)

        let high = try #require(UCIParser.parseInfo("info depth 15 multipv 1 score cp -80 upperbound pv e2e4"))
        #expect(high.bound == .upper)

        let exact = try #require(UCIParser.parseInfo("info depth 15 multipv 1 score cp 34 nodes 900 pv e2e4"))
        #expect(exact.bound == .exact)

        let boundedMate = try #require(UCIParser.parseInfo("info depth 21 multipv 1 score mate 4 lowerbound pv d1h5"))
        #expect(boundedMate.score == .mate(4))
        #expect(boundedMate.bound == .lower)
    }

    @Test("Rejects lines with no analysis value")
    func rejectsNonAnalysisLines() {
        #expect(UCIParser.parseInfo("info string NNUE evaluation using nn-x.nnue") == nil)
        #expect(UCIParser.parseInfo("info depth 1 currmove e2e4 currmovenumber 1") == nil)
        #expect(UCIParser.parseInfo("bestmove e2e4") == nil)
        #expect(UCIParser.parseInfo("readyok") == nil)
    }

    @Test("Tracks MultiPV rank")
    func parsesMultiPVRank() throws {
        let second = try #require(UCIParser.parseInfo("info depth 18 multipv 3 score cp -15 pv d2d4 d7d5"))
        #expect(second.multipv == 3)
        #expect(second.score == .centipawns(-15))
    }

    @Test("Parses bestmove with and without ponder")
    func parsesBestMove() throws {
        let withPonder = try #require(UCIParser.parseBestMove("bestmove e2e4 ponder e7e5"))
        #expect(withPonder.best == "e2e4")
        #expect(withPonder.ponder == "e7e5")

        let plain = try #require(UCIParser.parseBestMove("bestmove g1f3"))
        #expect(plain.best == "g1f3")
        #expect(plain.ponder == nil)
    }

    @Test("Terminal positions report no best move")
    func parsesNoneBestMove() throws {
        let none = try #require(UCIParser.parseBestMove("bestmove (none)"))
        #expect(none.best == nil)
    }

    @Test("Parses bench nodes/second")
    func parsesBenchNPS() {
        #expect(UCIParser.parseBenchNPS("Nodes/second    : 1543210") == 1_543_210)
        #expect(UCIParser.parseBenchNPS("Total nodes searched  : 4321") == nil)
    }

    @Test("Mate scores clamp to the mate-equivalent magnitude")
    func mateCentipawnValue() {
        #expect(UCIScore.mate(3).centipawnValue() == 10_000)
        #expect(UCIScore.mate(-3).centipawnValue() == -10_000)
        #expect(UCIScore.centipawns(250).centipawnValue() == 250)
    }

    @Test("Mate in zero is the side to move being mated, not mating")
    func mateInZeroIsALoss() {
        // `score mate 0` is what an engine reports for a position that is
        // already checkmate with the scored side to move. It used to read as a
        // full win here, while `AnalysisKit.EvalMath` scored the same value 0%.
        #expect(UCIScore.mate(0).centipawnValue() == -10_000)
        #expect(UCIScore.mate(0).centipawnValue(mateEquivalent: 3_200) == -3_200)
    }

    @Test("A search reports the deepest iteration it finished")
    func completedDepthDistinguishesTruncation() {
        // The case the flag alone cannot see: Stockfish stopped a `go depth 13
        // movetime 8000` search on the movetime, so nobody called `stop` and
        // `wasTruncated` is false — but the opponent that was supposed to
        // calculate thirteen moves deep only ever got to nine.
        let cutShort = SearchResult(
            bestMove: "e2e4",
            lines: [UCIInfo(depth: 10, score: .centipawns(20), bound: .lower, pv: ["e2e4"])],
            wasTruncated: false,
            completedDepth: 9
        )
        #expect(!cutShort.reachedRequestedDepth(of: .depthWithin(depth: 13, milliseconds: 8_000)))

        let finished = SearchResult(
            bestMove: "e2e4",
            lines: [UCIInfo(depth: 13, score: .centipawns(20), pv: ["e2e4"])],
            wasTruncated: false,
            completedDepth: 13
        )
        #expect(finished.reachedRequestedDepth(of: .depthWithin(depth: 13, milliseconds: 8_000)))

        // A node- or time-limited search never asked for a depth, so it cannot
        // have fallen short of one.
        #expect(cutShort.reachedRequestedDepth(of: .nodes(250_000)))
    }

    @Test("Search commands render correctly")
    func searchLimitCommands() {
        #expect(SearchLimit.nodes(250_000).command == "go nodes 250000")
        #expect(SearchLimit.depth(12).command == "go depth 12")
        #expect(SearchLimit.movetime(1000).command == "go movetime 1000")
        #expect(SearchLimit.depthWithin(depth: 13, milliseconds: 8_000).command == "go depth 13 movetime 8000")
        #expect(
            SearchLimit.clock(whiteMs: 60_000, blackMs: 55_000, whiteIncMs: 5_000, blackIncMs: 5_000).command
                == "go wtime 60000 btime 55000 winc 5000 binc 5000"
        )
    }

    @Test("Position commands render correctly")
    func positionCommands() {
        #expect(EnginePosition.startPosition(moves: []).command == "position startpos")
        #expect(
            EnginePosition.startPosition(moves: ["e2e4", "e7e5"]).command
                == "position startpos moves e2e4 e7e5"
        )
        let fen = "8/8/8/8/8/5K2/6Q1/7k w - - 0 1"
        #expect(EnginePosition.fen(fen, moves: []).command == "position fen \(fen)")
    }
}
