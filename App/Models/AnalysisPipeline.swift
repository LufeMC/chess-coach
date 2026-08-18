import AnalysisKit
import ChessKit
import Database
import EngineKit
import Foundation
import TrainingCore

/// The engine-free half of the post-game pass.
///
/// Everything here is a pure function over value types: give it a move list and
/// some canned engine output and it produces the same classifications, moments
/// and accuracy that a live run would. That is the point — the interesting logic
/// (perspective conversion, judgment, moment selection, resume accounting) is
/// testable without booting Stockfish or opening a database.
enum AnalysisPipeline {

    // MARK: - Replay

    /// The whole game, replayed onto real positions.
    struct GameReplay: Sendable {
        /// `positions[k]` is the position with the first `k` moves applied, so it
        /// has `moves.count + 1` entries.
        var positions: [Position]
        var moves: [Move]
        /// Non-`nil` where `positions[k]` is checkmate or a dead draw and there is
        /// nothing for the engine to search.
        var terminalScores: [UCIScore?]
        /// Square the move *into* `positions[k]` captured on, if it was a capture.
        /// Feeds `Criticality`'s forced-recapture filter.
        var lastCaptureSquares: [Square?]
    }

    /// Replays a UCI move list from the starting position.
    ///
    /// Stops at the first move that does not apply rather than throwing; the
    /// caller compares `moves.count` against what it expected and decides.
    static func replay(uci: [String]) -> GameReplay {
        var positions: [Position] = [.standard]
        var moves: [Move] = []
        var lastCaptureSquares: [Square?] = [nil]

        for text in uci {
            guard let current = positions.last,
                let applied = LineReplay.apply(uci: text, to: current)
            else { break }

            moves.append(applied.move)
            positions.append(applied.position)
            if case .capture = applied.move.result {
                lastCaptureSquares.append(applied.move.end)
            } else {
                lastCaptureSquares.append(nil)
            }
        }

        return GameReplay(
            positions: positions,
            moves: moves,
            terminalScores: positions.map(terminalScore(for:)),
            lastCaptureSquares: lastCaptureSquares
        )
    }

    /// The score a position with no legal move deserves, side-to-move relative.
    ///
    /// Two things are deliberate here.
    ///
    /// `Board(position:).state` is **not** used, even though it looks like the
    /// obvious answer. `Board` computes its state for the side that just moved, so
    /// a board built from a bare position reports on the side that is *not* to
    /// move and calls a mated position `.active`. `PositionUtilities` exists
    /// precisely because of that, and says so in its own documentation.
    ///
    /// Checkmate scores `.mate(-1)`, not the engine's own `.mate(0)`, because
    /// converting an after-move score to the mover's perspective negates it and
    /// `-0 == 0`. A `.mate(0)` would survive the flip unchanged and read as 0% —
    /// for the player who just *delivered* mate. `-1` negates to `+1`, which is
    /// what actually happened.
    ///
    /// Only mate and stalemate count. A fifty-move or insufficient-material
    /// position still has legal moves, so the engine can and should search it; the
    /// live game's own termination is what records the draw.
    static func terminalScore(for position: Position) -> UCIScore? {
        if PositionUtilities.isCheckmate(position) { return .mate(-1) }
        if PositionUtilities.isStalemate(position) { return .centipawns(0) }
        return nil
    }

    // MARK: - Stored evaluations

    /// One searched position, in the form both the engine and `plyEvals` speak.
    struct PositionEval: Sendable, Equatable {
        /// 1-based half-move number of the move about to be played here.
        var ply: Int
        var best: UCIInfo?
        var second: UCIInfo?
        var nodes: Int
        var depth: Int
        /// Set instead of `best` when the position is terminal.
        var terminalScore: UCIScore?

        init(
            ply: Int,
            best: UCIInfo? = nil,
            second: UCIInfo? = nil,
            nodes: Int = 0,
            depth: Int = 0,
            terminalScore: UCIScore? = nil
        ) {
            self.ply = ply
            self.best = best
            self.second = second
            self.nodes = nodes
            self.depth = depth
            self.terminalScore = terminalScore
        }

        init(ply: Int, result: SearchResult) {
            let principal = result.principal
            self.init(
                ply: ply,
                best: principal,
                second: result.line(rank: 2),
                nodes: principal?.nodes ?? 0,
                depth: principal?.depth ?? 0
            )
        }

        /// Restores an evaluation checkpointed by an earlier pass.
        init(row: PlyEvalRow) {
            let pv1 = row.pv1.split(separator: " ").map(String.init)
            let score1 = Self.score(cp: row.pv1Cp, mate: row.pv1Mate)

            guard !pv1.isEmpty else {
                // No principal variation means the position was terminal — that is
                // how `row(gameID:)` writes one.
                self.init(ply: row.ply, terminalScore: score1)
                return
            }

            let pv2 = row.pv2.split(separator: " ").map(String.init)
            self.init(
                ply: row.ply,
                best: UCIInfo(
                    multipv: 1,
                    depth: row.depth,
                    score: score1 ?? .centipawns(0),
                    nodes: row.nodes,
                    pv: pv1
                ),
                second: pv2.isEmpty
                    ? nil
                    : UCIInfo(
                        multipv: 2,
                        depth: row.depth,
                        score: Self.score(cp: row.pv2Cp, mate: row.pv2Mate) ?? .centipawns(0),
                        nodes: row.nodes,
                        pv: pv2
                    ),
                nodes: row.nodes,
                depth: row.depth
            )
        }

        /// Score of the position, from the side to move's perspective.
        var score: UCIScore? { best?.score ?? terminalScore }

        func row(gameID: UUID) -> PlyEvalRow {
            PlyEvalRow(
                gameID: gameID,
                ply: ply,
                pv1Cp: Self.centipawns(score),
                pv1Mate: Self.mate(score),
                pv1: (best?.pv ?? []).joined(separator: " "),
                pv2Cp: Self.centipawns(second?.score),
                pv2Mate: Self.mate(second?.score),
                pv2: (second?.pv ?? []).joined(separator: " "),
                nodes: nodes,
                depth: depth
            )
        }

        static func score(cp: Int?, mate: Int?) -> UCIScore? {
            if let mate { return .mate(mate) }
            if let cp { return .centipawns(cp) }
            return nil
        }

        static func centipawns(_ score: UCIScore?) -> Int? {
            if case .centipawns(let cp) = score { return cp }
            return nil
        }

        static func mate(_ score: UCIScore?) -> Int? {
            if case .mate(let n) = score { return n }
            return nil
        }
    }

    /// The contiguous prefix of a previous pass that can be reused.
    ///
    /// Stops at the first missing ply rather than using every row it finds. Rows
    /// are always written as a prefix, so a gap would mean corruption — and
    /// resuming *past* a gap would leave a ply permanently unevaluated, which is
    /// worse than re-searching a few positions.
    static func resumePrefix(from rows: [PlyEvalRow], positionCount: Int) -> [PositionEval] {
        let byPly = Dictionary(rows.map { ($0.ply, $0) }, uniquingKeysWith: { first, _ in first })
        var restored: [PositionEval] = []
        for index in 0..<positionCount {
            guard let row = byPly[index + 1] else { break }
            restored.append(PositionEval(row: row))
        }
        return restored
    }

    // MARK: - Enrichment

    /// The extra searches a flagged position earns.
    struct Enrichment: Sendable {
        /// Rank 1 from the deeper re-search.
        var best: UCIInfo?
        /// The best idea that is neither the played move nor (necessarily) the
        /// engine's first choice — "here is what else there was", which is the
        /// line coaching needs. Rank 2 normally; rank 3 when rank 2 happens to be
        /// the move the player actually made, which is why the re-search asks for
        /// three lines rather than two.
        var alternative: UCIInfo?
        var threatProbe: ThreatProbe?

        init(best: UCIInfo? = nil, alternative: UCIInfo? = nil, threatProbe: ThreatProbe? = nil) {
            self.best = best
            self.alternative = alternative
            self.threatProbe = threatProbe
        }

        init(result: SearchResult, playedUCI: String, threatProbe: ThreatProbe?) {
            self.best = result.principal
            self.alternative = [2, 3]
                .compactMap { result.line(rank: $0) }
                .first { $0.pv.first != playedUCI }
            self.threatProbe = threatProbe
        }
    }

    /// What one of the user's moves looks like before any detector runs.
    struct MoveSummary: Sendable {
        var bestLine: UCIInfo
        var secondLine: UCIInfo?
        var refutationLine: UCIInfo?
        /// Side-to-move relative score of the position after the move — i.e. the
        /// opponent's. Handed to `MoveContext` unflipped; it owns the conversion.
        var engineScoreAfter: UCIScore
        var deltaEP: Double
        var criticality: CriticalityResult
    }

    /// Reads the two stored evaluations around one move.
    ///
    /// Criticality is deliberately measured from the *base* MultiPV-2 pass rather
    /// than from an enriched re-search, so the gap means the same thing at every
    /// ply of the game.
    static func summarize(
        moveIndex: Int,
        replay: GameReplay,
        evaluations: [PositionEval]
    ) -> MoveSummary? {
        guard moveIndex + 1 < evaluations.count,
            moveIndex < replay.positions.count,
            let bestLine = evaluations[moveIndex].best,
            let engineScoreAfter = evaluations[moveIndex + 1].score
        else { return nil }

        // The single conversion that everything else depends on: the engine
        // searched the position *after* the move with the opponent to move, so its
        // score belongs to the opponent. `Perspective` owns the negation.
        let moverRelativeAfter = Perspective.moverRelativeAfterMove(engineScoreAfter)

        return MoveSummary(
            bestLine: bestLine,
            secondLine: evaluations[moveIndex].second,
            refutationLine: evaluations[moveIndex + 1].best,
            engineScoreAfter: engineScoreAfter,
            deltaEP: EvalMath.deltaEP(before: bestLine.score, after: moverRelativeAfter),
            criticality: Criticality.evaluate(
                best: bestLine,
                secondBest: evaluations[moveIndex].second,
                board: Board(position: replay.positions[moveIndex]),
                lastCaptureSquare: replay.lastCaptureSquares[moveIndex]
            )
        )
    }

    /// Which of the user's plies are worth a second, deeper look.
    ///
    /// Mistakes obviously, but also positions that genuinely branched even when
    /// the user found the move — those are the reinforcement candidates, and
    /// praise without a line to show is not coaching. Ordered by how much is at
    /// stake and capped, then returned in board order so the engine walks forward
    /// through the game and keeps its transposition table useful.
    static func plysToEnrich(
        replay: GameReplay,
        evaluations: [PositionEval],
        userColor: Piece.Color,
        budget: Int
    ) -> [Int] {
        var weighted: [(index: Int, weight: Double)] = []

        for index in replay.moves.indices where replay.moves[index].piece.color == userColor {
            guard let summary = summarize(moveIndex: index, replay: replay, evaluations: evaluations)
            else { continue }

            let judgment = EvalMath.judgment(deltaEP: summary.deltaEP)
            guard judgment >= .inaccuracy || summary.criticality.isCritical else { continue }
            weighted.append((index, max(summary.deltaEP, summary.criticality.gap)))
        }

        return weighted
            .sorted { $0.weight > $1.weight }
            .prefix(budget)
            .map(\.index)
            .sorted()
    }

    // MARK: - The pass

    static func analyze(
        replay: GameReplay,
        evaluations: [PositionEval],
        moveRows: [GameMoveRow],
        userColor: Piece.Color,
        timeControl: TimeControl?,
        userFlagged: Bool,
        enrichments: [Int: Enrichment],
        policy: MomentPolicy
    ) -> AnalyzedGame {
        let clocks = remainingClockBeforeMove(
            thinkTimes: moveRows.map(\.thinkTimeMs),
            movers: replay.moves.map { $0.piece.color },
            control: timeControl
        )
        let lastUserIndex = replay.moves.lastIndex { $0.piece.color == userColor }

        var analyzed: [AnalyzedMove] = []
        var candidates: [AnalysisKit.Moment] = []
        var accuracies: [Double] = []
        var winPercents: [Double] = []

        for index in replay.moves.indices {
            guard index < moveRows.count else { break }
            let row = moveRows[index]
            let isUserMove = replay.moves[index].piece.color == userColor

            guard let summary = summarize(moveIndex: index, replay: replay, evaluations: evaluations) else {
                analyzed.append(AnalyzedMove(id: row.id, ply: row.ply))
                continue
            }

            let moverRelativeAfter = Perspective.moverRelativeAfterMove(summary.engineScoreAfter)
            let winPctBefore = EvalMath.winPercent(score: summary.bestLine.score)
            let winPctAfter = EvalMath.winPercent(score: moverRelativeAfter)

            guard isUserMove else {
                // The opponent's moves are evaluated so the review can draw an
                // eval graph, but never judged: classifying the engine's play
                // would put "blunder" chips on moves the user did not make.
                analyzed.append(
                    AnalyzedMove(
                        id: row.id,
                        ply: row.ply,
                        classification: nil,
                        winPctBefore: winPctBefore,
                        winPctAfter: winPctAfter
                    )
                )
                continue
            }

            let enrichment = enrichments[index]
            guard
                let context = MoveContext(
                    ply: row.ply,
                    positionBefore: replay.positions[index],
                    playedUCI: row.uci,
                    // The enriched re-search is deeper and at wider MultiPV, so it
                    // supersedes the base pass where it exists.
                    bestLine: enrichment?.best ?? summary.bestLine,
                    secondLine: enrichment?.alternative ?? summary.secondLine,
                    refutationLine: summary.refutationLine,
                    evalBefore: (enrichment?.best ?? summary.bestLine).score,
                    // Raw, unflipped: `MoveContext` performs the conversion itself.
                    evalAfterEngine: summary.engineScoreAfter,
                    thinkTimeMs: row.thinkTimeMs,
                    timeControl: timeControl,
                    clockPressure: isClockPressure(remainingMs: clocks[index], control: timeControl),
                    // Attributed to the user's last move: that is the decision
                    // after which the clock ran out.
                    didFlag: userFlagged && index == lastUserIndex,
                    threatProbe: enrichment?.threatProbe,
                    criticality: summary.criticality,
                    priorMoves: Array(replay.moves.prefix(index)),
                    lastCaptureSquare: replay.lastCaptureSquares[index]
                )
            else {
                analyzed.append(
                    AnalyzedMove(
                        id: row.id,
                        ply: row.ply,
                        classification: nil,
                        winPctBefore: winPctBefore,
                        winPctAfter: winPctAfter
                    )
                )
                continue
            }

            let findings = DetectorSuite.run(context)
            let mistake = CauseTagger.tag(findings: findings, context: context)

            if MomentBuilder.isMistakeCandidate(context) {
                candidates.append(
                    MomentBuilder.make(
                        context: context,
                        findings: findings,
                        mistake: mistake,
                        policy: policy,
                        kind: .mistake
                    )
                )
            } else if MomentBuilder.isReinforcementCandidate(context) {
                candidates.append(
                    MomentBuilder.make(
                        context: context,
                        findings: findings,
                        mistake: mistake,
                        policy: policy,
                        kind: .reinforcement
                    )
                )
            }

            let accuracy = context.accuracy
            accuracies.append(accuracy)
            winPercents.append(EvalMath.winPercent(score: context.evalBefore))

            analyzed.append(
                AnalyzedMove(
                    id: row.id,
                    ply: row.ply,
                    classification: MoveClassification
                        .classify(judgment: context.judgment, playedBestMove: context.playedBestMove)
                        .rawValue,
                    winPctBefore: EvalMath.winPercent(score: context.evalBefore),
                    winPctAfter: EvalMath.winPercent(score: context.evalAfter),
                    accuracy: accuracy
                )
            )
        }

        return AnalyzedGame(
            moves: analyzed,
            moments: MomentSelector.select(candidates: candidates, policy: policy),
            userAccuracy: EvalMath.gameAccuracy(moveAccuracies: accuracies, winPercents: winPercents)
        )
    }

    // MARK: - Clocks

    /// Clock pressure starts at whichever is larger: half a minute, or a tenth of
    /// the starting time. The floor matters for long games (a minute left in a
    /// 90-minute game is panic) and the proportion matters for short ones.
    static let clockPressureFloorMs = 30_000

    static func isClockPressure(remainingMs: Int?, control: TimeControl?) -> Bool {
        guard let remainingMs, let control else { return false }
        return remainingMs < max(clockPressureFloorMs, Int(control.baseSeconds * 1000) / 10)
    }

    /// Rebuilds each player's remaining clock *before* each move.
    ///
    /// `gameMoves` has no clock column, but nothing is lost: the live session
    /// subtracts the think time and then adds the increment, so replaying that
    /// arithmetic over the stored think times reproduces the clocks exactly.
    static func remainingClockBeforeMove(
        thinkTimes: [Int],
        movers: [Piece.Color],
        control: TimeControl?
    ) -> [Int?] {
        guard let control else { return Array(repeating: nil, count: thinkTimes.count) }

        let increment = Int(control.incrementSeconds * 1000)
        var remaining: [Piece.Color: Int] = [
            .white: Int(control.baseSeconds * 1000),
            .black: Int(control.baseSeconds * 1000)
        ]

        var before: [Int?] = []
        for index in thinkTimes.indices {
            let mover = index < movers.count ? movers[index] : .white
            let clock = remaining[mover] ?? 0
            before.append(clock)
            remaining[mover] = max(0, clock - thinkTimes[index]) + increment
        }
        return before
    }

    /// Whether the user was the one who ran out of time.
    static func userLostOnTime(game: GameRow, userColor: Piece.Color) -> Bool {
        guard game.termination == GameTermination.timeout.rawValue else { return false }
        guard let result = game.result.flatMap(GameResult.init(rawValue:)), result != .draw else { return false }
        return !result.isWin(for: userColor == .white ? .white : .black)
    }

    // MARK: - Policy

    /// Turns the user's settings into the weights `MomentSelector` uses.
    ///
    /// The two taxonomies are joined through `Habit`: the analysis layer names
    /// causes, the curriculum names habits, and `TrainingCore` owns the mapping
    /// between them. Doing the join here rather than hard-coding a cause list
    /// means adding a detector cannot silently drop out of the focus weighting.
    static func momentPolicy(weeklyFocusHabit: String?, currentRung: Int) -> MomentPolicy {
        let focusHabit = weeklyFocusHabit.flatMap(Habit.init(rawValue:))
        let rungHabits = Curriculum.rung(currentRung)?.habits ?? []

        var focusTags: Set<AnalysisKit.CauseTag> = []
        var rungTags: Set<AnalysisKit.CauseTag> = []

        for tag in AnalysisKit.CauseTag.allCases {
            guard let habit = TrainingCore.CauseTag(tag.rawValue).habit(rung: currentRung) else { continue }
            if habit == focusHabit { focusTags.insert(tag) }
            if rungHabits.contains(habit) { rungTags.insert(tag) }
        }

        return MomentPolicy(weeklyFocusTags: focusTags, currentRungTags: rungTags)
    }

    // MARK: - Rows

    static func row(for moment: AnalysisKit.Moment, gameID: UUID) -> MomentRow {
        MomentRow(
            gameID: gameID,
            ply: moment.ply,
            fen: moment.fenBefore,
            kind: moment.kind.rawValue,
            causeTag: moment.causeTag.rawValue,
            stepTag: moment.stepTag.rawValue,
            modifiers: MomentRow.encodeModifiers(moment.modifiers),
            playedSAN: moment.playedSAN,
            playedUCI: moment.playedUCI,
            bestSAN: moment.bestSAN ?? "",
            bestUCI: moment.bestUCI ?? "",
            deltaEP: moment.deltaEP,
            score: moment.total
        )
    }
}

/// The strings written to `games.termination`.
///
/// A closed vocabulary in one place: `AnalysisPipeline` matches on `timeout` to
/// decide whether a move gets the `flagged` modifier, and a typo there would fail
/// silently rather than loudly.
enum GameTermination: String, Sendable, CaseIterable {
    case checkmate
    case resignation
    case timeout
    case stalemate
    case agreement
    case fiftyMoves
    case insufficientMaterial
    case repetition
    case unknown
}

extension AnalyzedMove {
    init(id: UUID, ply: Int) {
        self.init(id: id, ply: ply, classification: nil, winPctBefore: nil, winPctAfter: nil, accuracy: nil)
    }
}
