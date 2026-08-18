import EngineKit
import Foundation

/// Owns the single Stockfish instance and arbitrates access to it.
///
/// Stockfish keeps process-global state (bitboard tables, thread pool,
/// transposition table), so there is one engine per process. Play, analysis,
/// and guided-mode probes all need it, and they must not interleave: a search
/// started by one client and stopped by another produces garbage. Rather than
/// hope callers behave, this actor hands out leases and performs an explicit
/// handoff whenever ownership changes.
actor EngineService {

    /// Who wants the engine. Priority matters: a human waiting on a move always
    /// beats a background analysis pass.
    enum Client: String, Sendable, Comparable {
        /// Sparring/calibration opponent move generation.
        case play
        /// A short probe for guided mode (criticality, null-move threats).
        case probe
        /// Post-game analysis pass — the only preemptible client.
        case analysis

        /// Higher is more important.
        private var priority: Int {
            switch self {
            case .play: 2
            case .probe: 1
            case .analysis: 0
            }
        }

        static func < (lhs: Client, rhs: Client) -> Bool { lhs.priority < rhs.priority }
    }

    /// Engine configuration that differs per client.
    struct Configuration: Sendable, Equatable {
        var multiPV: Int
        var threads: Int
        var hashMB: Int

        static func play(device: DeviceProfile) -> Configuration {
            // Sparring samples among candidate moves, so it needs a wide MultiPV.
            Configuration(multiPV: 10, threads: device.threads, hashMB: device.hashMB)
        }

        static func analysis(device: DeviceProfile, multiPV: Int = 2) -> Configuration {
            Configuration(multiPV: multiPV, threads: device.threads, hashMB: device.hashMB)
        }

        static func probe(device: DeviceProfile) -> Configuration {
            Configuration(multiPV: 1, threads: max(1, device.threads / 2), hashMB: device.hashMB)
        }
    }

    /// Per-device search budget, established once at boot.
    struct DeviceProfile: Sendable, Equatable {
        var threads: Int
        var hashMB: Int
        /// Nodes per position for the post-game analysis pass.
        var analysisNodes: Int
        var benchNPS: Int

        /// Conservative defaults used before calibration completes.
        static let unknown = DeviceProfile(threads: 2, hashMB: 64, analysisNodes: 250_000, benchNPS: 0)
    }

    // MARK: - State

    private let engine: StockfishEngine
    private var currentOwner: Client?
    private var currentConfiguration: Configuration?
    private var device: DeviceProfile = .unknown
    private var booted = false

    /// Set while a low-priority client should stop at its next checkpoint.
    private var preemptionRequested = false

    init(engine: StockfishEngine = .shared) {
        self.engine = engine
    }

    var deviceProfile: DeviceProfile { device }
    var isBooted: Bool { booted }

    // MARK: - Boot

    /// Boots the engine, loads networks, and calibrates the per-position node
    /// budget for this device.
    ///
    /// Calibration matters because the analysis pass promises a bounded wall
    /// time (~10-20s/game), and a fixed node count means very different
    /// durations on an iPhone versus an M-series Mac.
    func boot(networks: NetworkPaths) async throws {
        guard !booted else { return }

        // BOTH networks must exist before the engine is touched.
        //
        // Stockfish runs in-process and calls `exit(EXIT_FAILURE)` from
        // `Network::load` when a net is missing or unreadable — see
        // Stockfish/src/nnue/network.cpp ("The engine will be terminated now").
        // In a subprocess that kills the engine; in-process it kills the whole
        // app, with no crash report and no chance to catch it. So the check has
        // to happen here, before any UCI command is sent.
        //
        // Notably the big net cannot be skipped by simply leaving EvalFile
        // unset: the default value names a file that must then exist, and the
        // small net cannot stand in for it because the two have different
        // architectures.
        for network in [networks.small, networks.big] where !FileManager.default.fileExists(atPath: network.path) {
            throw EngineError.missingNetwork(network.lastPathComponent)
        }

        try await engine.start(bigNet: networks.big, smallNet: networks.small)
        device = await calibrate()
        booted = true
    }

    /// Measures this device's throughput and converts it into a node budget.
    private func calibrate() async -> DeviceProfile {
        let cores = ProcessInfo.processInfo.activeProcessorCount

        #if os(iOS)
        // Leave headroom: the UI, the board animation, and the OS all need
        // cycles, and saturating the performance cores triggers thermal
        // throttling within a couple of minutes of analysis.
        let threads = max(1, min(4, cores / 2))
        let hashMB = 64
        let targetSecondsPerPosition = 0.35
        #else
        let threads = max(1, cores - 2)
        let hashMB = 256
        let targetSecondsPerPosition = 0.25
        #endif

        await engine.setOption(.threads, threads)
        await engine.setOption(.hash, hashMB)
        await engine.isReady()

        let nps = await engine.bench(depth: 8, threads: threads, hashMB: min(hashMB, 64))

        // Derive nodes from measured throughput rather than hardcoding, then
        // clamp: too few nodes makes classification noisy, too many blows the
        // per-game time budget.
        let derived = Int(Double(max(nps, 1)) * targetSecondsPerPosition)
        let analysisNodes = min(max(derived, 120_000), 1_500_000)

        return DeviceProfile(threads: threads, hashMB: hashMB, analysisNodes: analysisNodes, benchNPS: nps)
    }

    // MARK: - Leasing

    /// Acquires the engine for `client`, preempting a lower-priority holder.
    ///
    /// The handoff sequence (stop → drain → isready → ucinewgame → reconfigure)
    /// is what keeps a sparring game from inheriting an analysis pass's
    /// transposition entries, which would otherwise make the opponent
    /// mysteriously stronger on the moves that happen to be cached.
    func acquire(_ client: Client, configuration: Configuration) async {
        if let owner = currentOwner, owner != client {
            // Only ask; the holder yields at its next checkpoint.
            preemptionRequested = true
            await engine.stop()
        }

        currentOwner = client
        preemptionRequested = false

        if currentConfiguration != configuration {
            await engine.isReady()
            await engine.newGame()
            await engine.setOption(.multiPV, configuration.multiPV)
            await engine.setOption(.threads, configuration.threads)
            await engine.setOption(.hash, configuration.hashMB)
            await engine.isReady()
            currentConfiguration = configuration
        }
    }

    func release(_ client: Client) {
        guard currentOwner == client else { return }
        currentOwner = nil
    }

    /// Whether a lower-priority client should yield.
    ///
    /// The analysis pass checks this between plies so preemption pauses cleanly
    /// on a ply boundary instead of discarding a partial search.
    var shouldYield: Bool { preemptionRequested }

    // MARK: - Search

    /// Runs a search under an already-acquired lease.
    func search(_ position: EnginePosition, limit: SearchLimit) async throws -> SearchResult {
        try await engine.search(position, limit: limit)
    }

    func stop() async {
        await engine.stop()
    }

    /// Drains any in-flight search before the app is suspended.
    ///
    /// iOS kills processes that hold CPU after backgrounding; leaving a search
    /// running also wedges the UCI loop mid-command, so the next foreground
    /// launch would deadlock waiting for a `bestmove` that never comes.
    func suspendForBackground() async {
        await engine.stop()
        await engine.isReady()
        currentOwner = nil
    }

    /// Whether analysis should pause to let the device cool down.
    nonisolated var isThermallyConstrained: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}

/// Absolute paths to the NNUE networks.
struct NetworkPaths: Sendable {
    var small: URL
    var big: URL

    /// Resolves the bundled small net and the downloaded big net.
    ///
    /// The small net ships in the bundle (3.5MB) so the app works on first
    /// launch; the big net (71MB) is fetched into Application Support to keep
    /// the download small.
    static func standard(bundle: Bundle = .main) -> NetworkPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Networks", directoryHint: .isDirectory)

        // Bundle first, Application Support as the fallback so a
        // downloaded/updated net can override the shipped one later.
        func resolve(_ name: String) -> URL {
            bundle.url(forResource: name, withExtension: "nnue")
                ?? support.appending(path: "\(name).nnue")
        }

        return NetworkPaths(
            small: resolve("nn-37f18f62d772"),
            big: resolve("nn-1c0000000000")
        )
    }
}
