import Foundation
import Observation
import SwiftUI

/// Root application state and the single place services are constructed.
///
/// Everything below this is a value type or an actor; this is the one piece of
/// long-lived observable state the views bind to.
@Observable
@MainActor
final class AppModel {

    enum BootState: Equatable {
        case idle
        case booting
        case ready
        case failed(String)
    }

    private(set) var bootState: BootState = .idle

    /// Set once the engine reports its measured throughput, so the UI can show
    /// honest analysis-time estimates instead of a guess.
    private(set) var deviceProfile: EngineService.DeviceProfile = .unknown

    /// Navigation target, shared by the Today screen's CTA and any deep link.
    var route: Route?

    let engineService = EngineService()

    enum Route: Hashable {
        case play
        case review(gameID: UUID)
        case moment(momentID: UUID)
        case train
        case profile
        case settings
    }

    /// Non-nil when the database could not be opened. The app still runs — you
    /// can play — but nothing is saved, so this is surfaced rather than swallowed.
    private(set) var databaseError: String?

    /// True when the process was launched by the test runner.
    ///
    /// Unit tests are hosted *inside* this app, so launching normally would boot
    /// the engine and open the database underneath them — two processes' worth
    /// of setup racing one suite. Worse, the engine boot runs a CPU-bound bench
    /// and Stockfish is a process-global singleton, so a test that drives the
    /// engine would be fighting the host for it. Tests own their own setup.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func boot() async {
        guard !Self.isRunningTests else { return }
        guard bootState == .idle else { return }
        bootState = .booting

        // Open the database before any view can fetch. SQLiteData binds
        // `@FetchAll`/`@FetchOne` to a blank fallback if a query runs before the
        // default database is prepared, and that fallback never re-binds — a
        // view that loaded early would stay permanently empty.
        switch AppDatabase.bootstrapIfNeeded() {
        case .success:
            databaseError = nil
        case .failure(let error):
            databaseError = String(describing: error)
        }

        do {
            try await engineService.boot(networks: .standard())
            deviceProfile = await engineService.deviceProfile
            bootState = .ready
        } catch {
            // A missing network is the expected first-run failure; surface it
            // rather than silently running without an engine.
            bootState = .failed(String(describing: error))
        }
    }

    func handleBackgrounding() async {
        await engineService.suspendForBackground()
    }

    func navigate(to route: Route) {
        self.route = route
    }
}
