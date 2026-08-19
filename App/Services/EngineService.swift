import EngineKit
import Foundation
import OSLog

/// Owns the single Stockfish instance and arbitrates access to it.
///
/// Stockfish keeps process-global state (bitboard tables, thread pool,
/// transposition table), so there is one engine per process. Play, analysis,
/// and guided-mode probes all need it, and they must not interleave: a search
/// started by one client and stopped by another produces garbage. Rather than
/// hope callers behave, this actor hands out leases and performs an explicit
/// handoff whenever ownership changes.
///
/// ## What a lease guarantees
///
/// Exactly one client owns the engine at a time, and no `go` is ever in flight
/// when ownership changes. Both halves matter. Without the first, a background
/// analysis pass can stop a sparring search and the opponent silently never
/// moves; without the second, the incoming owner's first search throws
/// `searchAlreadyRunning`, which is the same wedged game by another route.
///
/// A lease carries a generation, not just a client, because releases are
/// unordered: every call site releases from `defer { Task { … } }`, so a release
/// scheduled by a pass that has already yielded can land *after* its successor's
/// acquire. Checking the generation makes that stale release a no-op instead of
/// a handoff to nobody.
actor EngineService {

    private static let log = Logger(subsystem: "com.usenivel.chesscoach", category: "engine")

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

    /// Proof that a client holds the engine, and the identity `release` and
    /// `search` are checked against.
    struct Lease: Sendable, Equatable, Hashable {
        let client: Client
        fileprivate let generation: UInt64
    }

    /// Why a search was refused.
    enum LeaseError: Error, Sendable {
        /// The lease was preempted, already released, or never taken. The caller
        /// should treat this as a pause, not a failure: the engine is somebody
        /// else's now and the work can be picked up again later.
        case expired
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
    private var lease: Lease?
    private var nextGeneration: UInt64 = 1
    /// Which client the engine's options were last set up for, so a handoff
    /// between two clients that happen to want identical numbers still clears
    /// the search tree.
    private var configuredFor: (client: Client, configuration: Configuration)?
    private var device: DeviceProfile = .unknown
    private var booted = false

    /// The highest-priority client waiting to take the engine, held until that
    /// client is actually holding it.
    ///
    /// Not cleared the moment `stop` is *sent*. `stop` only queues a command;
    /// the preempted client's in-flight search has not even resumed yet, so a
    /// request that ends there is a window too small for anyone to observe — the
    /// preempted pass sails on into its next search and races the new owner for
    /// the engine.
    private var pendingClaim: Client?

    /// One acquire parked until the engine comes free.
    private struct HandoffWaiter {
        let id: UUID
        let client: Client
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var handoffWaiters: [HandoffWaiter] = []

    /// Outstanding acquires per client.
    ///
    /// A client may hold overlapping leases — the analysis pass acquires once to
    /// evaluate and again to enrich, and the first release is still in flight
    /// when the second acquire lands. Counting them is what keeps that first
    /// release from freeing a lease the second phase is still searching under.
    private var outstanding: [Client: Int] = [:]

    /// How long a preempting acquire waits for the holder to stand down before
    /// taking the engine anyway.
    ///
    /// Short, because the whole reason it is preempting is that a human is
    /// waiting on a move, and the client on the other side may simply be gone —
    /// a cancelled task, a pass killed mid-ply.
    private static let preemptionTimeout: Duration = .seconds(3)

    /// How long an acquire that does *not* outrank the holder waits its turn.
    ///
    /// Long, because giving up early means taking the engine from a client that
    /// outranks it, which is the exact inversion this lease protocol exists to
    /// prevent. The bound is here only so a client that dies holding the engine
    /// cannot stall the queue behind it forever.
    private static let queueTimeout: Duration = .seconds(30)

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

    /// Acquires the engine for `client`, preempting a lower-priority holder and
    /// queueing behind a higher-priority one.
    ///
    /// The handoff sequence (ask → wait → drain → isready → ucinewgame →
    /// reconfigure) is what keeps a sparring game from inheriting an analysis
    /// pass's transposition entries, which would otherwise make the opponent
    /// mysteriously stronger on the moves that happen to be cached.
    ///
    /// The *wait* is the load-bearing step. Asking the holder to stop only
    /// queues a `stop` command; the holder's in-flight search has not resumed
    /// yet, let alone noticed. Returning at that point would put two clients on
    /// the engine at once, and whichever called `search` second would get
    /// `EngineError.searchAlreadyRunning` — reachable in the ordinary flow,
    /// since finishing a game queues analysis and tapping "play again" lands
    /// squarely inside that window.
    @discardableResult
    func acquire(_ client: Client, configuration: Configuration) async -> Lease {
        while let holder = lease, holder.client != client {
            let outranks = client > holder.client
            if outranks {
                // `max` so a probe cannot downgrade a claim a sparring move has
                // already staked on the engine.
                pendingClaim = max(pendingClaim ?? client, client)
                await engine.stop()
            }

            let timeout = outranks ? Self.preemptionTimeout : Self.queueTimeout
            if await waitForHandoff(client: client, timeout: timeout) { continue }

            Self.log.warning(
                "Engine handoff to \(client.rawValue, privacy: .public) from \(holder.client.rawValue, privacy: .public) timed out; taking it anyway."
            )
            break
        }

        let granted = Lease(client: client, generation: nextGeneration)
        nextGeneration &+= 1
        lease = granted
        outstanding[client, default: 0] += 1
        // A claim is satisfied once the claimant — or anyone who outranks it —
        // is holding the engine, and not before. Letting the *preempted* client
        // clear it by re-acquiring for its next phase would hand it the engine
        // back out from under whoever is still parked waiting for it.
        if let claim = pendingClaim, client >= claim { pendingClaim = nil }

        // No `go` may outlive its owner. Even after a clean handoff the previous
        // holder's search can still be running inside the engine — it was asked
        // to stop, not waited on — and the incoming owner's first search would
        // then throw rather than run.
        await engine.stop()
        await engine.waitUntilIdle()

        await reconfigure(client: client, configuration: configuration)
        return granted
    }

    /// Releases the lease held by `client`.
    ///
    /// A no-op unless `client` still owns the engine *and* has no other acquire
    /// outstanding, so a release left over from a superseded acquire cannot free
    /// a lease its successor is still searching under.
    func release(_ client: Client) {
        decrementOutstanding(client)
        guard let held = lease, held.client == client, outstanding[client, default: 0] == 0 else { return }
        surrender(held)
    }

    /// Releases a specific lease. Exact, and therefore the form to prefer: a
    /// lease that has already been superseded releases nothing.
    func release(_ lease: Lease) {
        decrementOutstanding(lease.client)
        surrender(lease)
    }

    /// Whether the client currently holding the engine should yield.
    var shouldYield: Bool {
        guard let lease else { return false }
        return shouldYield(lease)
    }

    /// Whether the holder of `lease` should stand down.
    ///
    /// The analysis pass checks this between plies so preemption pauses cleanly
    /// on a ply boundary instead of discarding a partial search — which only
    /// works because the answer stays true from the moment a higher-priority
    /// client asks right through to the moment that client has the engine.
    ///
    /// A lease that is no longer the current one always yields. Whatever its
    /// holder thought it was doing, it is not doing it on this engine.
    func shouldYield(_ lease: Lease) -> Bool {
        guard self.lease == lease else { return true }
        guard let pendingClaim else { return false }
        return pendingClaim > lease.client
    }

    private func decrementOutstanding(_ client: Client) {
        guard let count = outstanding[client], count > 0 else { return }
        outstanding[client] = count - 1
    }

    private func surrender(_ held: Lease) {
        guard lease == held else { return }
        lease = nil
        resumeNextWaiter()
    }

    private func resumeNextWaiter() {
        guard lease == nil, !handoffWaiters.isEmpty else { return }
        // Highest priority first, arrival order among equals. A plain FIFO here
        // would reintroduce the inversion the priority ordering exists to stop.
        var best = handoffWaiters.startIndex
        for index in handoffWaiters.indices where handoffWaiters[index].client > handoffWaiters[best].client {
            best = index
        }
        handoffWaiters.remove(at: best).continuation.resume(returning: true)
    }

    /// Parks until the engine comes free. Answers `false` if it never did.
    private func waitForHandoff(client: Client, timeout: Duration) async -> Bool {
        let id = UUID()
        let deadline = expiration(after: timeout) { await $0.expireHandoff(id) }
        defer { deadline.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            handoffWaiters.append(HandoffWaiter(id: id, client: client, continuation: continuation))
        }
    }

    private func expireHandoff(_ id: UUID) {
        guard let index = handoffWaiters.firstIndex(where: { $0.id == id }) else { return }
        handoffWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// A deadline for one parked acquire, cancelled the moment the wait ends
    /// normally so the common path costs nothing.
    private func expiration(
        after timeout: Duration,
        _ body: @escaping @Sendable (EngineService) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await body(self)
        }
    }

    private func reconfigure(client: Client, configuration: Configuration) async {
        // Reconfiguring on a change of *owner*, not only of numbers: the handoff
        // exists to stop one client from inheriting another's search tree, and
        // two clients can want the same MultiPV while wanting nothing to do with
        // each other's transposition entries. Consecutive acquires by the same
        // client keep the table, which is what makes move-by-move sparring fast.
        if let configuredFor, configuredFor.client == client, configuredFor.configuration == configuration {
            return
        }
        await engine.isReady()
        await engine.newGame()
        await engine.setOption(.multiPV, configuration.multiPV)
        await engine.setOption(.threads, configuration.threads)
        await engine.setOption(.hash, configuration.hashMB)
        await engine.isReady()
        configuredFor = (client, configuration)
    }

    // MARK: - Search

    /// Runs a search under an already-acquired lease.
    ///
    /// The lease is checked rather than trusted. A client whose lease was
    /// preempted between plies would otherwise search against a configuration
    /// belonging to somebody else, and both searches would come back wrong —
    /// silently, since a shallow score looks exactly like a deep one.
    func search(
        _ position: EnginePosition,
        limit: SearchLimit,
        lease: Lease? = nil
    ) async throws -> SearchResult {
        if let lease {
            guard self.lease == lease else { throw LeaseError.expired }
        } else {
            // Call sites that have not threaded their token through still have
            // to prove *somebody* holds the engine; an unleased search is always
            // a bug, and one that races whoever does hold it.
            guard self.lease != nil else { throw LeaseError.expired }
        }
        return try await engine.search(position, limit: limit)
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
        await engine.waitUntilIdle()
        await engine.isReady()

        lease = nil
        pendingClaim = nil
        outstanding.removeAll()
        // Whatever ran before the app went away is not worth keeping: the first
        // acquire after a foreground launch should start from a clean table.
        configuredFor = nil

        // Everyone queued behind the old owner is woken to re-check rather than
        // left parked, since nothing will release the lease they are waiting on.
        let waiting = handoffWaiters
        handoffWaiters.removeAll()
        for waiter in waiting { waiter.continuation.resume(returning: true) }
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
