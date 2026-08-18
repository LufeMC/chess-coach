import CStockfish
import Foundation

/// Actor-serialized access to the in-process Stockfish engine.
///
/// Stockfish owns process-global state (bitboard tables, thread pool,
/// transposition table), so there is exactly one engine per process and this is
/// a singleton. Callers coordinate access through `EngineService`'s lease
/// protocol rather than talking to this type concurrently.
public actor StockfishEngine {

    public static let shared = StockfishEngine()

    private var started = false
    private let lineStream: AsyncStream<String>
    private let lineContinuation: AsyncStream<String>.Continuation
    private var consumerTask: Task<Void, Never>?

    // Outstanding awaits, at most one of each kind at a time.
    private var handshakeWaiter: CheckedContinuation<Void, Never>?
    private var readyWaiter: CheckedContinuation<Void, Never>?
    private var benchWaiter: CheckedContinuation<Int, Never>?
    private var searchWaiter: CheckedContinuation<SearchResult, Never>?

    /// Deepest info line seen per MultiPV rank for the in-flight search.
    private var searchLines: [Int: UCIInfo] = [:]

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
    public func start(bigNet: URL? = nil, smallNet: URL? = nil) async throws {
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handshakeWaiter = continuation
            SFBridge.shared.send("uci")
        }

        // Networks must be set before the first search; Stockfish will otherwise
        // report a missing-eval-file error on `go`.
        if let smallNet {
            send("setoption name \(UCIOption.evalFileSmall.rawValue) value \(smallNet.path)")
        }
        if let bigNet {
            send("setoption name \(UCIOption.evalFile.rawValue) value \(bigNet.path)")
        }
        await isReady()
    }

    /// True once the handshake has completed.
    public var isStarted: Bool { started }

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
    public func isReady() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
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
    public func search(_ position: EnginePosition, limit: SearchLimit) async throws -> SearchResult {
        guard started else { throw EngineError.notStarted }
        guard searchWaiter == nil else { throw EngineError.searchAlreadyRunning }

        searchLines.removeAll(keepingCapacity: true)
        setPosition(position)

        return await withCheckedContinuation { (continuation: CheckedContinuation<SearchResult, Never>) in
            searchWaiter = continuation
            SFBridge.shared.send(limit.command)
        }
    }

    /// Asks the engine to stop searching. The in-flight `search(_:limit:)` call
    /// returns with whatever it found; it does not throw.
    public func stop() {
        guard searchWaiter != nil else { return }
        SFBridge.shared.send("stop")
    }

    /// Runs Stockfish's own benchmark and returns nodes/second.
    ///
    /// Used by the M0 smoke test to prove the NEON/dotprod build path is active:
    /// a scalar-fallback build reports a small fraction of the NPS of a
    /// correctly-vectorized one on the same hardware.
    public func bench(depth: Int = 8, threads: Int = 1, hashMB: Int = 16) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
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
            handshakeWaiter?.resume()
            handshakeWaiter = nil
            return
        }

        if line.hasPrefix("readyok") {
            readyWaiter?.resume()
            readyWaiter = nil
            return
        }

        if let info = UCIParser.parseInfo(line) {
            // Later lines for a rank are deeper, so they supersede earlier ones.
            searchLines[info.multipv] = info
            return
        }

        if let bestMove = UCIParser.parseBestMove(line) {
            let lines = searchLines.values.sorted { $0.multipv < $1.multipv }
            let result = SearchResult(best: bestMove.best, ponder: bestMove.ponder, lines: lines)
            searchWaiter?.resume(returning: result)
            searchWaiter = nil
            searchLines.removeAll(keepingCapacity: true)
            return
        }

        if let nps = UCIParser.parseBenchNPS(line) {
            benchWaiter?.resume(returning: nps)
            benchWaiter = nil
            return
        }
    }
}

private extension SearchResult {
    init(best: String?, ponder: String?, lines: [UCIInfo]) {
        self.init(bestMove: best, ponderMove: ponder, lines: lines)
    }
}
