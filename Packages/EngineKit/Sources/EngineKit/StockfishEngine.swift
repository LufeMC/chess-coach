import CStockfish
import Foundation

/// Actor-serialized access to the in-process Stockfish engine.
///
/// Stockfish owns process-global state (bitboard tables, thread pool,
/// transposition table), so there is exactly one engine per process and this is
/// a singleton. Callers coordinate access through `EngineService`'s lease
/// protocol rather than talking to this type concurrently.
///
/// ## Nothing here waits forever
///
/// Every await in this type is parked on a promise the engine thread may never
/// keep. It runs on a detached thread, it can die there, and a command it
/// refuses is answered with a diagnostic line rather than the reply the caller
/// is waiting on — so a bad FEN in one stored game could otherwise stall the
/// analysis queue behind it permanently, with nothing logged and nothing shown.
/// Three rules keep that from happening: every wait carries a deadline, output
/// that means "I will not answer" fails the outstanding wait instead of being
/// ignored, and a cancelled task sends `stop` rather than staying blocked until
/// a `bestmove` that an infinite search never sends.
public actor StockfishEngine {

    public static let shared = StockfishEngine()

    private var started = false
    private let lineStream: AsyncStream<String>
    private let lineContinuation: AsyncStream<String>.Continuation
    private var consumerTask: Task<Void, Never>?

    // MARK: - Outstanding waits
    //
    // At most one of each kind at a time. Each carries a ticket so a deadline
    // that fires late — after the engine answered and the next caller installed
    // its own wait — cannot fail somebody else's.

    private var nextTicket: UInt64 = 1

    private var handshakeWaiter: CheckedContinuation<Bool, Never>?
    private var handshakeTicket: UInt64 = 0

    private var readyWaiter: CheckedContinuation<Bool, Never>?
    private var readyTicket: UInt64 = 0

    private var benchWaiter: CheckedContinuation<Int, Never>?
    private var benchTicket: UInt64 = 0

    private var searchWaiter: CheckedContinuation<SearchResult, any Error>?
    private var searchTicket: UInt64 = 0

    /// True from the moment `go` is queued until `bestmove` comes back.
    ///
    /// Tracked separately from `searchWaiter` because a search whose caller has
    /// timed out or been cancelled is still running inside the engine. Starting
    /// the next one on top of it is what produces `searchAlreadyRunning`, and in
    /// the app that reads as an opponent who never moves.
    private var searchInFlight = false

    /// Set when the in-flight search has been asked to stop, so its result can
    /// be marked truncated instead of passed off as a completed one.
    private var searchStopped = false

    /// Callers parked in `waitUntilIdle`.
    private struct IdleWaiter {
        let ticket: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var idleWaiters: [IdleWaiter] = []

    /// Deepest info line seen per MultiPV rank for the in-flight search.
    private var searchLines: [Int: UCIInfo] = [:]

    /// Deepest *finished* rank-1 iteration of the in-flight search.
    ///
    /// Tracked as the search runs rather than derived from `searchLines` at the
    /// end, because the last line for rank 1 is often a bound from the partial
    /// iteration the engine was stopped in — the depth it reached and the depth
    /// it completed are different numbers, and only the second one describes the
    /// strength of the answer. See ``SearchResult/completedDepth``.
    private var searchCompletedDepth = 0

    /// Every line the engine has emitted since `startCapture()`. Only used by
    /// diagnostics and tests; nil in normal operation so we don't grow forever.
    private var capturedLines: [String]?

    private init() {
        (lineStream, lineContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    /// Boots the engine thread and completes the UCI handshake.
    ///
    /// - Parameters:
    ///   - bigNet: absolute path to the full NNUE network, if present on disk.
    ///   - smallNet: absolute path to the small NNUE network (bundled).
    ///   - timeout: how long the engine may take to answer `uci` and `isready`.
    public func start(
        bigNet: URL? = nil,
        smallNet: URL? = nil,
        timeout: Duration = .seconds(20)
    ) async throws {
        guard !started else { return }
        started = true

        let continuation = lineContinuation
        SFBridge.shared.start(responseHandler: { line in
            continuation.yield(line)
        })

        let stream = lineStream
        consumerTask = Task { [weak self] in
            // Single ordered consumer: AsyncStream preserves yield order, which
            // is what keeps `bestmove` from being processed before the `info`
            // lines that belong to the same search.
            for await line in stream {
                guard let self else { return }
                await self.process(line)
            }
        }

        // Handshake: "uci" -> option list -> "uciok".
        let ticket = takeTicket()
        handshakeTicket = ticket
        let deadline = expiration(after: timeout) { await $0.expireHandshake(ticket) }
        let acknowledged = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            handshakeWaiter?.resume(returning: false)
            handshakeWaiter = continuation
            SFBridge.shared.send("uci")
        }
        deadline.cancel()
        guard acknowledged else { throw EngineError.handshakeTimeout }

        // Networks must be set before the first search; Stockfish will otherwise
        // report a missing-eval-file error on `go`.
        if let smallNet {
            send("setoption name \(UCIOption.evalFileSmall.rawValue) value \(smallNet.path)")
        }
        if let bigNet {
            send("setoption name \(UCIOption.evalFile.rawValue) value \(bigNet.path)")
        }
        guard await isReady(timeout: timeout) else { throw EngineError.handshakeTimeout }
    }

    /// True once the handshake has completed.
    public var isStarted: Bool { started }

    /// True while a `go` is outstanding.
    public var isSearching: Bool { searchInFlight }

    // MARK: - Commands

    public func send(_ command: String) {
        SFBridge.shared.send(command)
    }

    public func setOption(_ option: UCIOption, _ value: String) {
        send("setoption name \(option.rawValue) value \(value)")
    }

    public func setOption(_ option: UCIOption, _ value: Int) {
        setOption(option, String(value))
    }

    /// Sends `isready` and waits for `readyok`. Also serves as a barrier that
    /// flushes any queued option changes.
    ///
    /// Answers `false` if the engine stayed silent past `timeout`, rather than
    /// throwing: every caller of this uses it as a barrier, and a barrier that
    /// forces each of them into error handling buys nothing the next command
    /// will not discover anyway.
    @discardableResult
    public func isReady(timeout: Duration = .seconds(20)) async -> Bool {
        let ticket = takeTicket()
        readyTicket = ticket
        let deadline = expiration(after: timeout) { await $0.expireReady(ticket) }
        defer { deadline.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            readyWaiter?.resume(returning: false)
            readyWaiter = continuation
            SFBridge.shared.send("isready")
        }
    }

    /// Clears search state between games. Required by the lease handoff so a
    /// sparring game never inherits an analysis pass's transposition entries.
    public func newGame() async {
        send("ucinewgame")
        await isReady()
    }

    public func setPosition(_ position: EnginePosition) {
        send(position.command)
    }

    /// Runs one search and waits for `bestmove`.
    ///
    /// Only one search may be in flight; the caller (EngineService) guarantees
    /// this via its lease. A second concurrent call throws rather than
    /// corrupting the first search's results.
    ///
    /// - Parameter timeout: overrides the deadline derived from `limit`. The
    ///   derived one is right almost always — see `SearchLimit.silenceBudget`.
    public func search(
        _ position: EnginePosition,
        limit: SearchLimit,
        timeout: Duration? = nil
    ) async throws -> SearchResult {
        guard started else { throw EngineError.notStarted }
        guard !searchInFlight else { throw EngineError.searchAlreadyRunning }
        try Task.checkCancellation()

        searchLines.removeAll(keepingCapacity: true)
        searchStopped = false
        searchCompletedDepth = 0
        searchInFlight = true
        setPosition(position)

        let ticket = takeTicket()
        searchTicket = ticket
        let deadline = (timeout ?? limit.silenceBudget).map { budget in
            expiration(after: budget) { await $0.expireSearch(ticket) }
        }
        defer { deadline?.cancel() }

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SearchResult, any Error>) in
                searchWaiter = continuation
                SFBridge.shared.send(limit.command)
            }
        } onCancel: {
            // The engine runs on its own thread and never learns about
            // cancellation on its own. Without this a cancelled task stays
            // parked until a `bestmove` arrives — which for an infinite search
            // is never, and for a long one is long after the caller stopped
            // caring.
            Task { await self.stop() }
        }

        // A cancelled search still produces a `bestmove`, and that result is
        // whatever the engine had reached when it was cut off. Returning it
        // would hand the caller a shallow score dressed as a finished one.
        try Task.checkCancellation()
        return result
    }

    /// Asks the engine to stop searching. The in-flight `search(_:limit:)` call
    /// returns with whatever it found, marked `wasTruncated`; it does not throw.
    public func stop() {
        guard searchInFlight else { return }
        searchStopped = true
        SFBridge.shared.send("stop")
    }

    /// Waits until no search is in flight.
    ///
    /// The lease handoff in `EngineService` depends on this. Handing the engine
    /// to a new owner while the previous owner's `go` is still running makes the
    /// new owner's first search throw `searchAlreadyRunning`, and there is no
    /// call site anywhere that can do anything useful with that.
    public func waitUntilIdle(timeout: Duration = .seconds(10)) async {
        guard searchInFlight else { return }
        let ticket = takeTicket()
        let deadline = expiration(after: timeout) { await $0.expireIdle(ticket) }
        defer { deadline.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(IdleWaiter(ticket: ticket, continuation: continuation))
        }
    }

    /// Runs Stockfish's own benchmark and returns nodes/second.
    ///
    /// Used by the M0 smoke test to prove the NEON/dotprod build path is active:
    /// a scalar-fallback build reports a small fraction of the NPS of a
    /// correctly-vectorized one on the same hardware.
    ///
    /// Answers `0` if the bench never reports, which the calibration caller
    /// already treats as "no measurement" and falls back from.
    public func bench(
        depth: Int = 8,
        threads: Int = 1,
        hashMB: Int = 16,
        timeout: Duration = .seconds(180)
    ) async -> Int {
        let ticket = takeTicket()
        benchTicket = ticket
        let deadline = expiration(after: timeout) { await $0.expireBench(ticket) }
        defer { deadline.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            benchWaiter?.resume(returning: 0)
            benchWaiter = continuation
            SFBridge.shared.send("bench \(hashMB) \(threads) \(depth) default depth")
        }
    }

    // MARK: - Diagnostics

    /// Starts recording every engine line, for tests and troubleshooting.
    public func startCapture() { capturedLines = [] }

    /// Returns and clears the recorded lines.
    public func drainCapture() -> [String] {
        defer { capturedLines = [] }
        return capturedLines ?? []
    }

    // MARK: - Line handling

    private func process(_ line: String) {
        if capturedLines != nil { capturedLines?.append(line) }

        if line.hasPrefix("uciok") {
            resumeHandshake(acknowledged: true)
            return
        }

        if line.hasPrefix("readyok") {
            resumeReady(acknowledged: true)
            return
        }

        if let info = UCIParser.parseInfo(line) {
            // Later lines for a rank are deeper, so they supersede earlier ones.
            searchLines[info.multipv] = info
            // An exact rank-1 score is the engine saying it finished that
            // iteration for its first move. A bound is not — it is the score it
            // had when something cut the iteration off — so a bounded line
            // advances the reported depth without advancing the completed one.
            if info.multipv == 1, info.bound == .exact {
                searchCompletedDepth = max(searchCompletedDepth, info.depth)
            }
            return
        }

        if let bestMove = UCIParser.parseBestMove(line) {
            let lines = searchLines.values.sorted { $0.multipv < $1.multipv }
            finishSearch(
                with: SearchResult(
                    bestMove: bestMove.best,
                    ponderMove: bestMove.ponder,
                    lines: lines,
                    wasTruncated: searchStopped,
                    completedDepth: searchCompletedDepth
                )
            )
            return
        }

        if let nps = UCIParser.parseBenchNPS(line) {
            resumeBench(nps: nps)
            return
        }

        if let rejection = Self.rejection(in: line) {
            failEveryWait(with: .engineRejected(rejection))
        }
    }

    /// The line, when it means the engine has refused the command it was given.
    ///
    /// Stockfish answers a command it cannot parse with `Unknown command:`, and
    /// reports a network it could not load or a position it would not take as an
    /// `info string`. Neither is followed by a `bestmove`, so a caller parked on
    /// one gets silence until its deadline — and one stored game with a corrupt
    /// FEN would stall the whole analysis queue behind it every time its turn
    /// came round.
    ///
    /// Deliberately narrow. Ordinary boot chatter (`id name`, the option list,
    /// the NNUE banner, the numa strings) must not be mistaken for a refusal.
    private static func rejection(in line: String) -> String? {
        if line.hasPrefix("Unknown command:") { return line }
        guard line.hasPrefix("info string") else { return nil }
        let lowered = line.lowercased()
        guard lowered.contains("error") || lowered.contains("failed") else { return nil }
        return line
    }

    private func finishSearch(with result: SearchResult) {
        // State first, resume second: a caller woken by this must find the
        // engine already idle, or the very next thing it does throws
        // `searchAlreadyRunning`.
        searchLines.removeAll(keepingCapacity: true)
        searchStopped = false
        searchCompletedDepth = 0
        searchInFlight = false
        let waiter = searchWaiter
        searchWaiter = nil
        searchTicket = 0
        waiter?.resume(returning: result)
        signalIdle()
    }

    /// Fails the outstanding search.
    ///
    /// - Parameter engineStillRunning: whether the engine will go on to print a
    ///   `bestmove` for this search anyway. A deadline does not stop the search,
    ///   it only stops waiting for it, so the slot stays occupied until that
    ///   `bestmove` lands; a refusal means no `bestmove` is coming and the slot
    ///   has to be freed here or nothing will ever search again.
    private func failSearch(_ error: EngineError, engineStillRunning: Bool) {
        let waiter = searchWaiter
        searchWaiter = nil
        searchTicket = 0

        if !engineStillRunning {
            searchLines.removeAll(keepingCapacity: true)
            searchStopped = false
            searchCompletedDepth = 0
            searchInFlight = false
        }

        waiter?.resume(throwing: error)
        if !engineStillRunning { signalIdle() }
    }

    private func failEveryWait(with error: EngineError) {
        failSearch(error, engineStillRunning: false)
        resumeHandshake(acknowledged: false)
        resumeReady(acknowledged: false)
        resumeBench(nps: 0)
    }

    private func signalIdle() {
        guard !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume() }
    }

    private func resumeHandshake(acknowledged: Bool) {
        guard let waiter = handshakeWaiter else { return }
        handshakeWaiter = nil
        handshakeTicket = 0
        waiter.resume(returning: acknowledged)
    }

    private func resumeReady(acknowledged: Bool) {
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        readyTicket = 0
        waiter.resume(returning: acknowledged)
    }

    private func resumeBench(nps: Int) {
        guard let waiter = benchWaiter else { return }
        benchWaiter = nil
        benchTicket = 0
        waiter.resume(returning: nps)
    }

    // MARK: - Deadlines

    private func expireHandshake(_ ticket: UInt64) {
        guard handshakeTicket == ticket else { return }
        resumeHandshake(acknowledged: false)
    }

    private func expireReady(_ ticket: UInt64) {
        guard readyTicket == ticket else { return }
        resumeReady(acknowledged: false)
    }

    private func expireBench(_ ticket: UInt64) {
        guard benchTicket == ticket else { return }
        resumeBench(nps: 0)
    }

    private func expireSearch(_ ticket: UInt64) {
        guard searchTicket == ticket, searchWaiter != nil else { return }
        // Ask the engine to wind up as well as giving up on it: an abandoned
        // search that keeps grinding burns cores the user is waiting on, and its
        // eventual `bestmove` is what frees the slot for the next caller.
        stop()
        failSearch(.searchTimeout, engineStillRunning: true)
    }

    private func expireIdle(_ ticket: UInt64) {
        guard let index = idleWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        idleWaiters.remove(at: index).continuation.resume()
    }

    /// A deadline for one wait.
    ///
    /// `Task.sleep` rather than a timer because cancelling it when the engine
    /// answers on time then costs nothing, and because the wait is charged to
    /// the cooperative pool instead of a thread.
    private func expiration(
        after timeout: Duration,
        _ body: @escaping @Sendable (StockfishEngine) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await body(self)
        }
    }

    private func takeTicket() -> UInt64 {
        defer { nextTicket &+= 1 }
        return nextTicket
    }
}
