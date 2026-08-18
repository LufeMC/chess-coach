import AnalysisKit
import ChessKit
import Database
import EngineKit
import Foundation
import OSLog
import TrainingCore

/// The post-game pass: walk every ply with the engine, work out what the user got
/// wrong and why, and turn that into a handful of positions worth studying.
///
/// ## Shape of a pass
///
/// Four phases, in order, and only the first two touch the engine:
///
/// 1. **Evaluate** — one search per position (`n` moves means `n + 1` positions)
///    at MultiPV 2. Results go straight into `plyEvals`, which is also the resume
///    checkpoint.
/// 2. **Enrich** — the flagged positions only, re-searched at MultiPV 3 for a
///    coaching alternative, plus a null-move probe for the threat detectors.
/// 3. **Select** — pure: detectors, cause tagging, moment scoring and selection,
///    accuracy. No engine, no database.
/// 4. **Write** — moments, per-move classification, game accuracy, final state.
///
/// ## Preemption
///
/// A human waiting for a sparring move always beats this. The engine lease is
/// taken as `.analysis`, the lowest priority, and the loop asks
/// `engineService.shouldYield` **between plies** — never mid-search, because a
/// search stopped early returns a shallower score that would silently mis-judge
/// exactly one move. On a yield the accumulated evaluations are flushed, the game
/// goes back to `pending`, and the pass returns `.preempted`. The next run reads
/// those rows back and starts at the first ply that has none, so a preempted pass
/// resumes rather than restarts. Thermal pressure is handled identically: the
/// device gets to cool down and the backlog drains later.
actor AnalysisService {

    enum Outcome: Sendable, Equatable {
        case completed
        /// Stopped cleanly on a ply boundary; the game is back in the queue.
        case preempted
        case failed(String)
    }

    // MARK: - Dependencies

    private let engineService: EngineService
    private let store: AnalysisStore

    /// Positions re-searched for coaching lines. A hard cap rather than a
    /// proportion: a 120-move disaster would otherwise triple the pass time
    /// precisely when the user is least interested in a 12-point review.
    private static let enrichmentBudget = 12

    /// How often the evaluation prefix is written out. Insurance against a hard
    /// kill (jetsam, force-quit) — a clean preemption always flushes anyway.
    private static let flushInterval = 8

    init(engineService: EngineService, store: AnalysisStore) {
        self.engineService = engineService
        self.store = store
    }

    // MARK: - Shared instance

    @MainActor private static var instance: AnalysisService?

    /// The process-wide analysis service, or `nil` if the database is unavailable.
    ///
    /// A singleton because the queue must be one queue: two services draining
    /// `awaitingAnalysis` concurrently would fight over the same engine lease and
    /// analyse the same game twice.
    @MainActor
    static func shared(engineService: EngineService) -> AnalysisService? {
        if let instance { return instance }
        guard let database = AppDatabase.sharedIfAvailable else { return nil }
        let service = AnalysisService(engineService: engineService, store: AnalysisStore(database: database))
        instance = service
        return service
    }

    // MARK: - Progress

    private var observers: [UUID: AsyncStream<AnalysisProgress>.Continuation] = [:]
    private(set) var latestProgress: AnalysisProgress?

    /// A stream of progress updates. Each call gets its own stream; all of them
    /// see every update.
    ///
    /// Buffering is `.bufferingNewest(1)`: a progress bar only ever wants the
    /// current value, and an unbounded buffer would let a paused SwiftUI view
    /// accumulate one element per ply.
    nonisolated func progress() -> AsyncStream<AnalysisProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeObserver(id) }
            }
            Task { await self.addObserver(id, continuation) }
        }
    }

    private func addObserver(_ id: UUID, _ continuation: AsyncStream<AnalysisProgress>.Continuation) {
        observers[id] = continuation
        if let latestProgress { continuation.yield(latestProgress) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func emit(_ progress: AnalysisProgress) {
        latestProgress = progress
        for continuation in observers.values { continuation.yield(progress) }
    }

    // MARK: - Queue

    private var isDraining = false

    /// Drains the backlog of games awaiting analysis, oldest first.
    ///
    /// Stops at the first preemption instead of moving on to the next game: the
    /// engine has been claimed by someone more important, so the whole queue is
    /// blocked, not just this entry.
    func analyzePending(limit: Int = 5) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        recoverStalledGames()

        var attempted: Set<UUID> = []
        for _ in 0..<limit {
            guard let next = (try? store.pending(limit: limit))?.first(where: { !attempted.contains($0.id) })
            else { return }

            attempted.insert(next.id)
            if await analyze(gameID: next.id) == .preempted { return }
        }
    }

    /// Returns games abandoned mid-pass to the queue.
    ///
    /// `running` is only ever a live, in-memory condition; a row still carrying it
    /// at launch means the process died holding it. The `plyEvals` written before
    /// the crash survive, so the retry resumes from there.
    private func recoverStalledGames() {
        guard let stalled = try? store.stalled(), !stalled.isEmpty else { return }
        for game in stalled {
            try? store.setState(.pending, forGame: game.id)
        }
        AppLog.analysis.info("Requeued \(stalled.count) game(s) left running by a previous launch.")
    }

    // MARK: - One game

    @discardableResult
    func analyze(gameID: UUID) async -> Outcome {
        emit(AnalysisProgress(gameID: gameID, stage: .queued))

        let game: GameRow
        let moveRows: [GameMoveRow]
        let policy: MomentPolicy
        do {
            guard let loaded = try store.game(id: gameID) else {
                return fail(gameID, "No game \(gameID)")
            }
            game = loaded
            moveRows = try store.moves(forGame: gameID)
            let inputs = try store.policyInputs()
            policy = AnalysisPipeline.momentPolicy(
                weeklyFocusHabit: inputs.weeklyFocusHabit,
                currentRung: inputs.currentRung
            )
        } catch {
            return fail(gameID, String(describing: error))
        }

        guard !moveRows.isEmpty else {
            // A game with no moves has nothing to say, but it must still leave
            // the queue or it will be retried forever.
            try? store.setState(.complete, forGame: gameID)
            emit(AnalysisProgress(gameID: gameID, stage: .finished))
            return .completed
        }

        guard let userColor = game.color.map({ $0 == .white ? Piece.Color.white : .black }) else {
            return fail(gameID, "Unknown user colour '\(game.userColor)'")
        }

        let replay = AnalysisPipeline.replay(uci: moveRows.map(\.uci))
        guard replay.moves.count == moveRows.count else {
            return fail(gameID, "Move \(replay.moves.count + 1) of the stored game is not legal")
        }

        let parameters = FinishedGameRecord.OpponentParams.decode(game.opponentParams)
        let timeControl = parameters.map {
            TimeControl(baseSeconds: Double($0.baseSeconds), incrementSeconds: Double($0.incrementSeconds))
        }

        try? store.setState(.running, forGame: gameID)

        let device = await engineService.deviceProfile
        let nodeBudget = device.analysisNodes

        // MARK: Phase 1 — evaluate every position

        var evaluations: [AnalysisPipeline.PositionEval]
        do {
            await engineService.acquire(.analysis, configuration: .analysis(device: device, multiPV: 2))
            defer { Task { await engineService.release(.analysis) } }

            switch await evaluateAllPlies(
                gameID: gameID,
                replay: replay,
                uci: moveRows.map(\.uci),
                nodeBudget: nodeBudget
            ) {
            case .success(let result):
                evaluations = result
            case .paused(let partial):
                persist(evals: partial, gameID: gameID)
                try? store.setState(.pending, forGame: gameID)
                emit(AnalysisProgress(gameID: gameID, stage: .paused, ply: partial.count, total: replay.positions.count))
                return .preempted
            case .failure(let reason):
                return fail(gameID, reason)
            }
        }
        persist(evals: evaluations, gameID: gameID)

        // MARK: Phase 2 — re-search the interesting positions

        let flagged = AnalysisPipeline.plysToEnrich(
            replay: replay,
            evaluations: evaluations,
            userColor: userColor,
            budget: Self.enrichmentBudget
        )

        var enrichments: [Int: AnalysisPipeline.Enrichment] = [:]
        if !flagged.isEmpty {
            emit(AnalysisProgress(gameID: gameID, stage: .enriching, ply: 0, total: flagged.count))

            // One reconfiguration for the whole phase rather than per position:
            // `acquire` issues `ucinewgame` whenever the configuration changes,
            // which throws away the transposition table each time.
            await engineService.acquire(.analysis, configuration: .analysis(device: device, multiPV: 3))
            defer { Task { await engineService.release(.analysis) } }

            for (index, plyIndex) in flagged.enumerated() {
                if await shouldPause() {
                    // Phase 1's output is already on disk, so resuming skips
                    // straight back to here. Nothing is lost by dropping the
                    // enrichments gathered so far.
                    try? store.setState(.pending, forGame: gameID)
                    emit(AnalysisProgress(gameID: gameID, stage: .paused, ply: index, total: flagged.count))
                    return .preempted
                }

                do {
                    enrichments[plyIndex] = try await enrich(
                        plyIndex: plyIndex,
                        replay: replay,
                        uci: moveRows.map(\.uci),
                        playedUCI: moveRows[plyIndex].uci,
                        nodeBudget: nodeBudget
                    )
                } catch {
                    // A failed enrichment costs a coaching line, not the pass.
                    AppLog.analysis.error("Enrichment failed at ply \(plyIndex + 1): \(String(describing: error), privacy: .public)")
                }
                emit(AnalysisProgress(gameID: gameID, stage: .enriching, ply: index + 1, total: flagged.count))
            }
        }

        // MARK: Phase 3 — pure analysis

        emit(AnalysisProgress(gameID: gameID, stage: .selecting, ply: replay.moves.count, total: replay.positions.count))

        let analyzed = AnalysisPipeline.analyze(
            replay: replay,
            evaluations: evaluations,
            moveRows: moveRows,
            userColor: userColor,
            timeControl: timeControl,
            userFlagged: AnalysisPipeline.userLostOnTime(game: game, userColor: userColor),
            enrichments: enrichments,
            policy: policy
        )

        // MARK: Phase 4 — write

        emit(AnalysisProgress(gameID: gameID, stage: .writing, ply: replay.moves.count, total: replay.positions.count))
        do {
            try store.applyMoveOutcomes(analyzed.moves)
            try store.replaceMoments(
                analyzed.moments.map { AnalysisPipeline.row(for: $0, gameID: gameID) },
                forGame: gameID
            )
            try store.setAccuracy(analyzed.userAccuracy, forGame: gameID)
            try store.setState(.complete, forGame: gameID)
        } catch {
            return fail(gameID, String(describing: error))
        }

        AppLog.analysis.info(
            "Analysed \(gameID.uuidString, privacy: .public): \(analyzed.moments.count) moment(s), accuracy \(analyzed.userAccuracy ?? -1)"
        )
        emit(AnalysisProgress(gameID: gameID, stage: .finished, ply: replay.positions.count, total: replay.positions.count))
        return .completed
    }

    // MARK: - Phase 1

    private enum EvaluationRun {
        case success([AnalysisPipeline.PositionEval])
        /// The prefix completed so far, which is what gets checkpointed.
        case paused([AnalysisPipeline.PositionEval])
        case failure(String)
    }

    private func evaluateAllPlies(
        gameID: UUID,
        replay: AnalysisPipeline.GameReplay,
        uci: [String],
        nodeBudget: Int
    ) async -> EvaluationRun {
        let total = replay.positions.count

        // Resume: whatever a previous pass got through is still on disk. Rows are
        // only ever written as a contiguous prefix, so the first gap is the
        // restart point.
        var evaluations = AnalysisPipeline.resumePrefix(
            from: (try? store.evals(forGame: gameID)) ?? [],
            positionCount: total
        )
        var sinceFlush = 0

        emit(AnalysisProgress(gameID: gameID, stage: .evaluating, ply: evaluations.count, total: total))

        while evaluations.count < total {
            let index = evaluations.count

            if await shouldPause() { return .paused(evaluations) }

            if let terminal = replay.terminalScores[index] {
                // Checkmate or a dead draw: there is no move to search, and asking
                // the engine returns `bestmove (none)` with no usable score.
                evaluations.append(
                    AnalysisPipeline.PositionEval(ply: index + 1, terminalScore: terminal)
                )
                continue
            }

            do {
                let result = try await engineService.search(
                    .startPosition(moves: Array(uci.prefix(index))),
                    limit: .nodes(nodeBudget)
                )
                evaluations.append(AnalysisPipeline.PositionEval(ply: index + 1, result: result))
            } catch {
                return .failure("Search failed at ply \(index + 1): \(error)")
            }

            sinceFlush += 1
            if sinceFlush >= Self.flushInterval {
                persist(evals: evaluations, gameID: gameID)
                sinceFlush = 0
            }
            emit(AnalysisProgress(gameID: gameID, stage: .evaluating, ply: evaluations.count, total: total))
        }

        return .success(evaluations)
    }

    // MARK: - Phase 2

    private func enrich(
        plyIndex: Int,
        replay: AnalysisPipeline.GameReplay,
        uci: [String],
        playedUCI: String,
        nodeBudget: Int
    ) async throws -> AnalysisPipeline.Enrichment {
        let prefix = Array(uci.prefix(plyIndex))
        let result = try await engineService.search(.startPosition(moves: prefix), limit: .nodes(nodeBudget))

        // The null-move probe answers "what was the opponent threatening?" — the
        // input the ignored-threat detectors need. It is only worth its search on
        // positions that already look like mistakes, which is why it lives here
        // rather than in phase 1.
        var probe: ThreatProbe?
        if let probeFEN = NullMove.probeFEN(for: replay.positions[plyIndex]) {
            let probeResult = try await engineService.search(.fen(probeFEN, moves: []), limit: .nodes(nodeBudget / 2))
            if let principal = probeResult.principal {
                probe = ThreatProbe(
                    fen: probeFEN,
                    bestMove: probeResult.bestMove,
                    score: principal.score,
                    pv: principal.pv
                )
            }
        }

        return AnalysisPipeline.Enrichment(result: result, playedUCI: playedUCI, threatProbe: probe)
    }

    // MARK: - Helpers

    /// Whether the pass should stop at this ply boundary.
    ///
    /// Three reasons, all of which mean "stop cleanly and come back later": the
    /// task was cancelled, a higher-priority client wants the engine, or the
    /// device is too hot to keep four cores busy on background work.
    private func shouldPause() async -> Bool {
        if Task.isCancelled { return true }
        if engineService.isThermallyConstrained { return true }
        return await engineService.shouldYield
    }

    private func persist(evals: [AnalysisPipeline.PositionEval], gameID: UUID) {
        do {
            try store.storeEvals(evals.map { $0.row(gameID: gameID) }, forGame: gameID)
        } catch {
            // Losing the checkpoint costs time on the next run, nothing else.
            AppLog.analysis.error("Could not checkpoint evals: \(String(describing: error), privacy: .public)")
        }
    }

    private func fail(_ gameID: UUID, _ reason: String) -> Outcome {
        AppLog.analysis.error("Analysis of \(gameID.uuidString, privacy: .public) failed: \(reason, privacy: .public)")
        // The schema has no column for the reason — `analysisState` is a single
        // string — so it goes to the log and to the progress stream, and the row
        // records only that the pass failed.
        try? store.setState(.failed, forGame: gameID)
        emit(AnalysisProgress(gameID: gameID, stage: .failed, failureReason: reason))
        return .failed(reason)
    }
}
