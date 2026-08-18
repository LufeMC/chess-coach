import AnalysisKit
import ChessKit
import Database
import EngineKit
import Foundation
import Testing

@testable import ChessCoach

// Unit tests for the engine-free half of the post-game pass. Every fixture here
// is hand-written engine output: no Stockfish, no SQLite, no clock.

// MARK: - Fixtures

private enum Fixture {

    /// 1. e4 e5 2. Nf3 Nf6 — four plies, all legal, no captures.
    static let openingUCI = ["e2e4", "e7e5", "g1f3", "g8f6"]

    static func info(_ score: UCIScore, pv: [String], rank: Int = 1, depth: Int = 20) -> UCIInfo {
        UCIInfo(multipv: rank, depth: depth, score: score, nodes: 250_000, pv: pv)
    }

    static func moveRows(gameID: UUID, uci: [String], thinkTimes: [Int]) -> [GameMoveRow] {
        uci.enumerated().map { index, text in
            GameMoveRow(
                gameID: gameID,
                ply: index + 1,
                san: text,
                uci: text,
                thinkTimeMs: index < thinkTimes.count ? thinkTimes[index] : 5_000
            )
        }
    }
}

// MARK: - Replay

@Suite("Replay")
struct ReplayTests {

    @Test("Replays a legal move list into positions and moves")
    func replaysLegalMoves() {
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)

        #expect(replay.moves.count == 4)
        // One more position than moves: the position before each move, plus the
        // final one.
        #expect(replay.positions.count == 5)
        #expect(replay.positions[0].fen == Position.standard.fen)
        #expect(replay.moves[0].piece.color == .white)
        #expect(replay.moves[1].piece.color == .black)
    }

    @Test("Stops at the first move that does not apply")
    func stopsAtIllegalMove() {
        let replay = AnalysisPipeline.replay(uci: ["e2e4", "e7e5", "e2e4"])
        #expect(replay.moves.count == 2)
        #expect(replay.positions.count == 3)
    }

    @Test("Records the square a capture landed on")
    func recordsCaptureSquare() {
        // 1. e4 d5 2. exd5 — the capture lands on d5.
        let replay = AnalysisPipeline.replay(uci: ["e2e4", "d7d5", "e4d5"])
        #expect(replay.lastCaptureSquares[0] == nil)
        #expect(replay.lastCaptureSquares[2] == nil)
        #expect(replay.lastCaptureSquares[3] == Square("d5"))
    }

    @Test("Checkmate scores as mate(-1), never mate(0)")
    func checkmateScoresNegative() throws {
        // Fool's mate: 1. f3 e5 2. g4 Qh4#
        let replay = AnalysisPipeline.replay(uci: ["f2f3", "e7e5", "g2g4", "d8h4"])
        let terminal = try #require(replay.terminalScores.last ?? nil)

        // The value matters: `.mate(0)` negates to itself, so the player who
        // delivered mate would read as 0%. `.mate(-1)` negates to `.mate(1)`.
        #expect(terminal == .mate(-1))
        #expect(EvalMath.winPercent(score: terminal) == 0)
        #expect(EvalMath.winPercent(score: Perspective.moverRelativeAfterMove(terminal)) == 100)
    }

    @Test("Stalemate scores as a dead draw")
    func stalemateScoresZero() throws {
        let position = try #require(Position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"))
        #expect(AnalysisPipeline.terminalScore(for: position) == .centipawns(0))
    }

    @Test("A normal position has no terminal score")
    func normalPositionIsNotTerminal() {
        #expect(AnalysisPipeline.terminalScore(for: .standard) == nil)
    }
}

// MARK: - Checkpoint round-trip

@Suite("Evaluation checkpointing")
struct CheckpointTests {

    @Test("A searched position survives a write/read round trip")
    func roundTripsSearchedPosition() {
        let gameID = UUID()
        let original = AnalysisPipeline.PositionEval(
            ply: 7,
            best: Fixture.info(.centipawns(42), pv: ["e2e4", "e7e5"]),
            second: Fixture.info(.mate(3), pv: ["d2d4"], rank: 2),
            nodes: 250_000,
            depth: 21
        )

        let restored = AnalysisPipeline.PositionEval(row: original.row(gameID: gameID))

        #expect(restored.ply == 7)
        #expect(restored.best?.score == .centipawns(42))
        #expect(restored.best?.pv == ["e2e4", "e7e5"])
        #expect(restored.second?.score == .mate(3))
        #expect(restored.second?.pv == ["d2d4"])
        #expect(restored.nodes == 250_000)
        #expect(restored.depth == 21)
    }

    @Test("A terminal position round trips as terminal, not as a search")
    func roundTripsTerminalPosition() {
        let original = AnalysisPipeline.PositionEval(ply: 40, terminalScore: .mate(-1))
        let restored = AnalysisPipeline.PositionEval(row: original.row(gameID: UUID()))

        #expect(restored.best == nil)
        #expect(restored.terminalScore == .mate(-1))
        #expect(restored.score == .mate(-1))
    }
}

// MARK: - Resume accounting

@Suite("Resume accounting")
struct ResumeTests {

    private func rows(plies: [Int]) -> [PlyEvalRow] {
        plies.map { ply in
            AnalysisPipeline.PositionEval(ply: ply, best: Fixture.info(.centipawns(ply), pv: ["e2e4"]))
                .row(gameID: UUID())
        }
    }

    @Test("An empty checkpoint restarts from the beginning")
    func emptyCheckpointRestartsFromZero() {
        #expect(AnalysisPipeline.resumePrefix(from: [], positionCount: 10).isEmpty)
    }

    @Test("A complete checkpoint is reused whole")
    func completeCheckpointIsReused() {
        let restored = AnalysisPipeline.resumePrefix(from: rows(plies: [1, 2, 3, 4]), positionCount: 4)
        #expect(restored.count == 4)
        #expect(restored.map(\.ply) == [1, 2, 3, 4])
    }

    @Test("A partial checkpoint resumes at the next ply")
    func partialCheckpointResumes() {
        let restored = AnalysisPipeline.resumePrefix(from: rows(plies: [1, 2, 3]), positionCount: 9)
        #expect(restored.count == 3)
    }

    @Test("A gap truncates rather than skipping past it")
    func gapTruncates() {
        // Rows 5 and 6 exist but 4 does not. Using them would leave ply 4
        // permanently unevaluated, so everything from the gap on is discarded.
        let restored = AnalysisPipeline.resumePrefix(from: rows(plies: [1, 2, 3, 5, 6]), positionCount: 9)
        #expect(restored.count == 3)
    }

    @Test("Rows out of order still restore in ply order")
    func unorderedRowsRestoreInOrder() {
        let restored = AnalysisPipeline.resumePrefix(from: rows(plies: [3, 1, 2]), positionCount: 5)
        #expect(restored.map(\.ply) == [1, 2, 3])
    }
}

// MARK: - Perspective

@Suite("Perspective and judgment")
struct PerspectiveTests {

    /// Builds evaluations for `Fixture.openingUCI` where white's third ply
    /// (`g1f3`) collapses from +30 to a 400cp advantage for black.
    private func evaluationsWithWhiteBlunder() -> [AnalysisPipeline.PositionEval] {
        [
            .init(ply: 1, best: Fixture.info(.centipawns(20), pv: ["e2e4"])),
            .init(ply: 2, best: Fixture.info(.centipawns(-15), pv: ["e7e5"])),
            .init(
                ply: 3,
                best: Fixture.info(.centipawns(30), pv: ["b1c3"]),
                second: Fixture.info(.centipawns(10), pv: ["d2d4"], rank: 2)
            ),
            // Black to move here, and +400 is *black's* score.
            .init(ply: 4, best: Fixture.info(.centipawns(400), pv: ["f8c5"])),
            .init(ply: 5, best: Fixture.info(.centipawns(-380), pv: ["d2d4"]))
        ]
    }

    @Test("The after-move score is read from the mover's side, not the engine's")
    func deltaEPUsesMoverPerspective() throws {
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)
        let summary = try #require(
            AnalysisPipeline.summarize(moveIndex: 2, replay: replay, evaluations: evaluationsWithWhiteBlunder())
        )

        // The stored score is +400 for black. Read naively it would look like a
        // *gain* for white; converted, it is a collapse.
        #expect(summary.engineScoreAfter == .centipawns(400))
        #expect(summary.deltaEP > 0.30)
        #expect(EvalMath.judgment(deltaEP: summary.deltaEP) == .blunder)
    }

    @Test("The same swing judged for black comes out identically")
    func blackBlunderMatchesWhiteBlunder() throws {
        // Black's second ply (index 3, `g8f6`) collapses by the same amount.
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)
        let evaluations: [AnalysisPipeline.PositionEval] = [
            .init(ply: 1, best: Fixture.info(.centipawns(20), pv: ["e2e4"])),
            .init(ply: 2, best: Fixture.info(.centipawns(-15), pv: ["e7e5"])),
            .init(ply: 3, best: Fixture.info(.centipawns(30), pv: ["b1c3"])),
            .init(ply: 4, best: Fixture.info(.centipawns(30), pv: ["f8c5"])),
            // White to move; +400 belongs to white, so black just collapsed.
            .init(ply: 5, best: Fixture.info(.centipawns(400), pv: ["d2d4"]))
        ]

        let white = try #require(
            AnalysisPipeline.summarize(moveIndex: 2, replay: replay, evaluations: evaluationsWithWhiteBlunder())
        )
        let black = try #require(
            AnalysisPipeline.summarize(moveIndex: 3, replay: replay, evaluations: evaluations)
        )

        // Symmetry is the whole point: an identical swing must judge identically
        // for either colour, which is exactly what a hand-rolled sign flip breaks.
        #expect(abs(white.deltaEP - black.deltaEP) < 0.001)
    }

    @Test("A quiet move is not judged as an error")
    func quietMoveIsNotAnError() throws {
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)
        let evaluations: [AnalysisPipeline.PositionEval] = [
            .init(ply: 1, best: Fixture.info(.centipawns(20), pv: ["e2e4"])),
            .init(ply: 2, best: Fixture.info(.centipawns(-15), pv: ["e7e5"])),
            .init(ply: 3, best: Fixture.info(.centipawns(30), pv: ["g1f3"])),
            .init(ply: 4, best: Fixture.info(.centipawns(-25), pv: ["f8c5"])),
            .init(ply: 5, best: Fixture.info(.centipawns(28), pv: ["d2d4"]))
        ]

        let summary = try #require(
            AnalysisPipeline.summarize(moveIndex: 2, replay: replay, evaluations: evaluations)
        )
        #expect(EvalMath.judgment(deltaEP: summary.deltaEP) == .ok)
    }
}

// MARK: - Classification

@Suite("Classification mapping")
struct ClassificationTests {

    @Test("Error judgments map straight through")
    func errorsMapThrough() {
        #expect(MoveClassification.classify(judgment: .blunder, playedBestMove: false) == .blunder)
        #expect(MoveClassification.classify(judgment: .mistake, playedBestMove: false) == .mistake)
        #expect(MoveClassification.classify(judgment: .inaccuracy, playedBestMove: false) == .inaccuracy)
    }

    @Test("A judgment of ok splits on whether the engine's move was found")
    func okSplitsOnBestMove() {
        #expect(MoveClassification.classify(judgment: .ok, playedBestMove: true) == .best)
        #expect(MoveClassification.classify(judgment: .ok, playedBestMove: false) == .good)
    }

    @Test("An error is still an error even when it was the engine's move")
    func errorWinsOverBestMove() {
        // Reachable in a lost position where every move loses ground; calling it
        // "best" there would be actively misleading.
        #expect(MoveClassification.classify(judgment: .blunder, playedBestMove: true) == .blunder)
    }
}

// MARK: - Clocks

@Suite("Clock reconstruction")
struct ClockTests {

    private let control = TimeControl(baseSeconds: 600, incrementSeconds: 5)

    @Test("Each colour's clock is tracked separately")
    func tracksBothClocks() {
        let before = AnalysisPipeline.remainingClockBeforeMove(
            thinkTimes: [10_000, 20_000, 30_000, 40_000],
            movers: [.white, .black, .white, .black],
            control: control
        )

        #expect(before[0] == 600_000)
        #expect(before[1] == 600_000)
        // White: 600s - 10s + 5s increment.
        #expect(before[2] == 595_000)
        // Black: 600s - 20s + 5s increment.
        #expect(before[3] == 585_000)
    }

    @Test("Without a time control there are no clocks to reconstruct")
    func noControlMeansNoClocks() {
        let before = AnalysisPipeline.remainingClockBeforeMove(
            thinkTimes: [1_000, 2_000],
            movers: [.white, .black],
            control: nil
        )
        #expect(before == [nil, nil])
    }

    @Test("Clock pressure uses the larger of the floor and a tenth of the base")
    func clockPressureThreshold() {
        // 600s base: a tenth is 60s, which beats the 30s floor.
        #expect(AnalysisPipeline.isClockPressure(remainingMs: 45_000, control: control))
        #expect(!AnalysisPipeline.isClockPressure(remainingMs: 90_000, control: control))

        // 60s base: a tenth is 6s, so the 30s floor governs.
        let bullet = TimeControl(baseSeconds: 60, incrementSeconds: 0)
        #expect(AnalysisPipeline.isClockPressure(remainingMs: 20_000, control: bullet))
        #expect(!AnalysisPipeline.isClockPressure(remainingMs: 40_000, control: bullet))
    }

    @Test("No clock and no control means no pressure")
    func missingInputsMeanNoPressure() {
        #expect(!AnalysisPipeline.isClockPressure(remainingMs: nil, control: control))
        #expect(!AnalysisPipeline.isClockPressure(remainingMs: 1_000, control: nil))
    }
}

// MARK: - Enrichment selection

@Suite("Enrichment selection")
struct EnrichmentTests {

    @Test("Only the user's plies are considered, and only the flagged ones")
    func picksFlaggedUserPlies() {
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)
        let evaluations: [AnalysisPipeline.PositionEval] = [
            .init(ply: 1, best: Fixture.info(.centipawns(20), pv: ["e2e4"])),
            .init(ply: 2, best: Fixture.info(.centipawns(-25), pv: ["e7e5"])),
            // White to move and +250: black's previous move cost a lot. It is the
            // opponent's move, so it must not be picked.
            .init(ply: 3, best: Fixture.info(.centipawns(250), pv: ["b1c3"])),
            // Black to move and +400: white's move just collapsed.
            .init(ply: 4, best: Fixture.info(.centipawns(400), pv: ["f8c5"])),
            .init(ply: 5, best: Fixture.info(.centipawns(-380), pv: ["d2d4"]))
        ]

        let flagged = AnalysisPipeline.plysToEnrich(
            replay: replay,
            evaluations: evaluations,
            userColor: .white,
            budget: 12
        )

        // Ply index 2 is white's blunder; index 0 was fine; 1 and 3 are black's.
        #expect(flagged == [2])
    }

    @Test("The budget caps the list and the worst moves win the slots")
    func budgetCapsSelection() {
        let uci = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "d2d3", "f8c5"]
        let replay = AnalysisPipeline.replay(uci: uci)

        // Every white move collapses; the later ones collapse harder.
        var evaluations: [AnalysisPipeline.PositionEval] = []
        for index in 0...uci.count {
            let isWhiteToMove = index % 2 == 0
            let score = isWhiteToMove ? 30 : 200 + index * 40
            evaluations.append(
                .init(ply: index + 1, best: Fixture.info(.centipawns(score), pv: [], depth: 20))
            )
        }

        let flagged = AnalysisPipeline.plysToEnrich(
            replay: replay,
            evaluations: evaluations,
            userColor: .white,
            budget: 2
        )

        #expect(flagged.count == 2)
        // Returned in board order so the engine walks forward through the game.
        #expect(flagged == flagged.sorted())
        // The two worst are the last two white moves.
        #expect(flagged == [4, 6])
    }
}

// MARK: - Whole pass

@Suite("Full pure pass")
struct FullPassTests {

    private func run(userColor: Piece.Color) -> AnalyzedGame {
        let gameID = UUID()
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)
        let evaluations: [AnalysisPipeline.PositionEval] = [
            .init(ply: 1, best: Fixture.info(.centipawns(20), pv: ["e2e4"])),
            .init(ply: 2, best: Fixture.info(.centipawns(-15), pv: ["e7e5"])),
            .init(
                ply: 3,
                best: Fixture.info(.centipawns(30), pv: ["b1c3"]),
                second: Fixture.info(.centipawns(10), pv: ["d2d4"], rank: 2)
            ),
            .init(ply: 4, best: Fixture.info(.centipawns(400), pv: ["f8c5"])),
            .init(ply: 5, best: Fixture.info(.centipawns(-380), pv: ["d2d4"]))
        ]

        return AnalysisPipeline.analyze(
            replay: replay,
            evaluations: evaluations,
            moveRows: Fixture.moveRows(
                gameID: gameID,
                uci: Fixture.openingUCI,
                thinkTimes: [3_000, 3_000, 30_000, 3_000]
            ),
            userColor: userColor,
            timeControl: TimeControl(baseSeconds: 600, incrementSeconds: 5),
            userFlagged: false,
            enrichments: [:],
            policy: MomentPolicy()
        )
    }

    @Test("Every move gets a row, and only the user's gets a classification")
    func onlyUserMovesAreJudged() {
        let result = run(userColor: .white)

        #expect(result.moves.count == 4)
        #expect(result.moves.map(\.ply) == [1, 2, 3, 4])

        // White (the user) played plies 1 and 3.
        #expect(result.moves[0].classification != nil)
        #expect(result.moves[2].classification == MoveClassification.blunder.rawValue)

        // Black is the opponent: evaluated, never judged.
        #expect(result.moves[1].classification == nil)
        #expect(result.moves[3].classification == nil)
        #expect(result.moves[1].winPctBefore != nil)
        #expect(result.moves[1].accuracy == nil)
    }

    @Test("The blunder becomes a moment")
    func blunderProducesAMoment() throws {
        let result = run(userColor: .white)

        #expect(!result.moments.isEmpty)
        #expect(result.moments.count <= 3)
        let moment = try #require(result.moments.first)
        #expect(moment.ply == 3)
        #expect(moment.judgment == .blunder)
        #expect(moment.kind == .mistake)
        #expect(moment.playedUCI == "g1f3")
    }

    @Test("Game accuracy is produced and reflects the blunder")
    func accuracyReflectsTheBlunder() throws {
        let result = run(userColor: .white)
        let accuracy = try #require(result.userAccuracy)

        #expect(accuracy > 0)
        #expect(accuracy < 100)
    }

    @Test("Switching the user's colour switches which moves are judged")
    func colourSwitchesWhoIsJudged() {
        let result = run(userColor: .black)

        #expect(result.moves[0].classification == nil)
        #expect(result.moves[2].classification == nil)
        #expect(result.moves[1].classification != nil)
        #expect(result.moves[3].classification != nil)
        // White's collapse is not the black player's problem.
        #expect(result.moments.allSatisfy { $0.ply % 2 == 0 })
    }

    @Test("Win percentages are stored from the mover's own side")
    func winPercentsAreMoverRelative() throws {
        let result = run(userColor: .white)

        // Ply 3 is white's blunder: white's own win% must drop across it.
        let blunder = try #require(result.moves.first { $0.ply == 3 })
        let before = try #require(blunder.winPctBefore)
        let after = try #require(blunder.winPctAfter)
        #expect(before > after)
        #expect(before > 50)
        #expect(after < 50)
    }

    @Test("A move list longer than the eval list degrades instead of crashing")
    func handlesTruncatedEvaluations() {
        let gameID = UUID()
        let replay = AnalysisPipeline.replay(uci: Fixture.openingUCI)
        let result = AnalysisPipeline.analyze(
            replay: replay,
            evaluations: [.init(ply: 1, best: Fixture.info(.centipawns(20), pv: ["e2e4"]))],
            moveRows: Fixture.moveRows(gameID: gameID, uci: Fixture.openingUCI, thinkTimes: []),
            userColor: .white,
            timeControl: nil,
            userFlagged: false,
            enrichments: [:],
            policy: MomentPolicy()
        )

        #expect(result.moves.count == 4)
        #expect(result.moves.allSatisfy { $0.classification == nil })
        #expect(result.moments.isEmpty)
        #expect(result.userAccuracy == nil)
    }
}

// MARK: - Progress accounting

@Suite("Progress accounting")
struct ProgressTests {

    @Test("Fraction is nil until the total is known")
    func fractionNeedsATotal() {
        #expect(AnalysisProgress(gameID: UUID(), stage: .queued).fraction == nil)
    }

    @Test("Fraction tracks plies over total and saturates")
    func fractionTracksPlies() {
        let id = UUID()
        #expect(AnalysisProgress(gameID: id, stage: .evaluating, ply: 0, total: 40).fraction == 0)
        #expect(AnalysisProgress(gameID: id, stage: .evaluating, ply: 10, total: 40).fraction == 0.25)
        #expect(AnalysisProgress(gameID: id, stage: .finished, ply: 40, total: 40).fraction == 1)
        // A stage that reports more plies than positions must not exceed 1.
        #expect(AnalysisProgress(gameID: id, stage: .writing, ply: 99, total: 40).fraction == 1)
    }

    @Test("Only finished and failed are terminal — paused is not")
    func pausedIsNotTerminal() {
        let id = UUID()
        #expect(AnalysisProgress(gameID: id, stage: .finished).isTerminal)
        #expect(AnalysisProgress(gameID: id, stage: .failed, failureReason: "x").isTerminal)
        // A paused pass resumes, so the UI must not tear its progress view down.
        #expect(!AnalysisProgress(gameID: id, stage: .paused).isTerminal)
        #expect(!AnalysisProgress(gameID: id, stage: .evaluating).isTerminal)
    }
}

// MARK: - Opponent parameters

@Suite("Opponent parameter blob")
struct OpponentParamsTests {

    @Test("Round trips through the JSON column")
    func roundTrips() throws {
        let params = FinishedGameRecord.OpponentParams(
            opponentRating: 1420,
            baseSeconds: 600,
            incrementSeconds: 5,
            secondTryEnabled: true,
            guidedEnabled: false
        )

        let decoded = try #require(FinishedGameRecord.OpponentParams.decode(params.json))
        #expect(decoded == params)
    }

    @Test("Garbage decodes to nil rather than throwing")
    func garbageDecodesToNil() {
        #expect(FinishedGameRecord.OpponentParams.decode("{}") == nil)
        #expect(FinishedGameRecord.OpponentParams.decode("not json") == nil)
    }
}

// MARK: - Rows

@Suite("Row mapping")
struct RowMappingTests {

    @Test("A finished game maps onto its rows")
    func mapsFinishedGame() {
        let id = UUID()
        let record = FinishedGameRecord(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            mode: GameMode.sparring.rawValue,
            userColor: .black,
            opponentRating: 1300,
            result: GameResult.blackWins.rawValue,
            termination: GameTermination.checkmate.rawValue,
            pgn: "1. e4 e5 0-1",
            moves: [
                .init(ply: 1, san: "e4", uci: "e2e4", byUser: false, thinkTimeMs: 1_200, clockAfterMs: 599_000),
                .init(ply: 2, san: "e5", uci: "e7e5", byUser: true, thinkTimeMs: 2_400, clockAfterMs: 598_000)
            ],
            opponentParams: .init(
                opponentRating: 1300,
                baseSeconds: 600,
                incrementSeconds: 5,
                secondTryEnabled: false,
                guidedEnabled: false
            ),
            isRated: true
        )

        let row = record.gameRow
        #expect(row.id == id)
        #expect(row.userColor == PlayerColor.black.rawValue)
        #expect(row.endedAt != nil)
        // Every finished game must enter the analysis queue.
        #expect(row.analysis == .pending)
        #expect(row.opponentParams.contains("1300"))

        let moves = record.moveRows
        #expect(moves.count == 2)
        #expect(moves.allSatisfy { $0.gameID == id })
        #expect(moves.map(\.ply) == [1, 2])
        #expect(moves.allSatisfy { $0.classification == nil })
    }

    @Test("A moment maps onto its row without losing its diagnosis")
    func mapsMoment() {
        let gameID = UUID()
        let moment = AnalysisKit.Moment(
            ply: 17,
            phase: .middlegame,
            fenBefore: Position.standard.fen,
            sideToMove: .white,
            playedSAN: "Nf3",
            playedUCI: "g1f3",
            bestSAN: "Nc3",
            bestUCI: "b1c3",
            cpBefore: 30,
            cpAfter: -400,
            winPctBefore: 52,
            winPctAfter: 18,
            deltaEP: 0.34,
            judgment: .blunder,
            criticalityGap: 0.2,
            detector: .hangingPiece,
            causeTag: .hungMovedPiece,
            stepTag: .s5BlunderCheck,
            modifiers: ["impulse"],
            score: MomentScore(severity: 0.68, learnability: 1, relevance: 1.5),
            kind: .mistake,
            srsEligible: true
        )

        let row = AnalysisPipeline.row(for: moment, gameID: gameID)
        #expect(row.gameID == gameID)
        #expect(row.ply == 17)
        #expect(row.causeTag == "hungMovedPiece")
        #expect(row.stepTag == "S5")
        #expect(row.kind == "mistake")
        #expect(row.bestUCI == "b1c3")
        #expect(row.modifierList == ["impulse"])
        #expect(row.momentStatus == .new)
        #expect(abs(row.score - moment.total) < 0.000_001)
    }

    @Test("A moment with no best move stores an empty string, not a crash")
    func handlesMissingBestMove() {
        let moment = AnalysisKit.Moment(
            ply: 3,
            phase: .opening,
            fenBefore: Position.standard.fen,
            sideToMove: .black,
            playedSAN: "e5",
            playedUCI: "e7e5",
            bestSAN: nil,
            bestUCI: nil,
            cpBefore: 0,
            cpAfter: 0,
            winPctBefore: 50,
            winPctAfter: 50,
            deltaEP: 0,
            judgment: .ok,
            criticalityGap: 0,
            detector: nil,
            causeTag: .generic,
            stepTag: .s3Candidates,
            score: MomentScore(severity: 0, learnability: 0, relevance: 1),
            kind: .reinforcement,
            srsEligible: false
        )

        let row = AnalysisPipeline.row(for: moment, gameID: UUID())
        #expect(row.bestSAN.isEmpty)
        #expect(row.bestUCI.isEmpty)
    }
}

// MARK: - Moment policy

@Suite("Moment policy")
struct MomentPolicyTests {

    @Test("The weekly focus habit weights every cause tag that maps to it")
    func focusHabitWeightsItsCauses() {
        let policy = AnalysisPipeline.momentPolicy(weeklyFocusHabit: "blunderCheck", currentRung: 2)

        #expect(policy.weeklyFocusTags.contains(.hungMovedPiece))
        #expect(policy.weeklyFocusTags.contains(.hungLeftPiece))
        #expect(policy.weeklyFocusTags.contains(.allowedShallowTactic))
        #expect(!policy.weeklyFocusTags.contains(.endgameTechnique))
    }

    @Test("An unknown or absent habit produces no focus weighting")
    func unknownHabitIsIgnored() {
        #expect(AnalysisPipeline.momentPolicy(weeklyFocusHabit: nil, currentRung: 1).weeklyFocusTags.isEmpty)
        #expect(
            AnalysisPipeline.momentPolicy(weeklyFocusHabit: "notAHabit", currentRung: 1)
                .weeklyFocusTags.isEmpty
        )
    }

    @Test("Rung 1 weights the board-vision causes")
    func rungOneWeightsBoardVision() {
        let policy = AnalysisPipeline.momentPolicy(weeklyFocusHabit: nil, currentRung: 1)
        #expect(policy.currentRungTags.contains(.hungMovedPiece))
        #expect(policy.limit == 3)
    }

    @Test("A rung that does not exist degrades to no weighting")
    func unknownRungIsEmpty() {
        #expect(AnalysisPipeline.momentPolicy(weeklyFocusHabit: nil, currentRung: 99).currentRungTags.isEmpty)
    }
}

// MARK: - Flagging

@Suite("Flag attribution")
struct FlagTests {

    private func game(termination: String, result: String) -> GameRow {
        GameRow(
            mode: GameMode.sparring.rawValue,
            userColor: PlayerColor.white.rawValue,
            opponentRating: 1200,
            result: result,
            termination: termination
        )
    }

    @Test("A timeout loss is attributed to the user who lost it")
    func userTimeoutIsDetected() {
        let lost = game(termination: GameTermination.timeout.rawValue, result: GameResult.blackWins.rawValue)
        #expect(AnalysisPipeline.userLostOnTime(game: lost, userColor: .white))
        #expect(!AnalysisPipeline.userLostOnTime(game: lost, userColor: .black))
    }

    @Test("A timeout win is not a flag for the winner")
    func timeoutWinIsNotAFlag() {
        let won = game(termination: GameTermination.timeout.rawValue, result: GameResult.whiteWins.rawValue)
        #expect(!AnalysisPipeline.userLostOnTime(game: won, userColor: .white))
    }

    @Test("Losses by other means are not flags")
    func otherTerminationsAreNotFlags() {
        let mated = game(termination: GameTermination.checkmate.rawValue, result: GameResult.blackWins.rawValue)
        #expect(!AnalysisPipeline.userLostOnTime(game: mated, userColor: .white))
    }
}
