import Foundation
import Observation
import SwiftUI
import TrainingCore

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

    let engineService = EngineService()

    enum Route: Hashable {
        case play
        case review(gameID: UUID)
        case moment(gameID: UUID, momentID: UUID)
        case train
        case profile
        case settings
    }

    /// The tab bar's selection. Owned here rather than by the root view because
    /// a route arriving from the Today CTA has to be able to change it.
    var selectedTab: Tab = .today

    enum Tab: Hashable {
        case today
        case play
        case train
        case profile
    }

    /// Push stack for the Today tab. Review and moment routes land here because
    /// reviewing is something you arrive at from the daily loop, not a
    /// destination with its own tab.
    var todayPath: [Route] = []

    /// A game the Play tab should start on arrival, consumed by `PlayScreen`.
    ///
    /// Carried as state rather than acted on directly because the Play tab may
    /// not be on screen yet when the route is set; the screen picks it up in its
    /// own `task`.
    var pendingPlayRequest: Bool = false

    /// A habit the Train tab should build its next session around, set when the
    /// user taps a rating leak.
    ///
    /// The leak table is the app's diagnosis and the drill queue is its
    /// prescription; a leak row that merely explains itself leaves the user to
    /// carry the diagnosis to the right drill by hand, which is exactly the work
    /// the app exists to do for them.
    var pendingTrainingHabit: Habit?

    /// Non-nil when the database could not be opened. The app still runs — you
    /// can play — but nothing is saved, so this is surfaced rather than swallowed.
    private(set) var databaseError: String?

    /// Whether the day-one calibration still needs to run.
    ///
    /// Completion is stored as a metric rather than a settings column: adding a
    /// column to a CloudKit-synced table is a schema migration, and "have we
    /// measured this user yet" is exactly the kind of derived fact the metrics
    /// table already exists to hold.
    private(set) var needsCalibration = false

    /// Marks calibration done so the gate closes without waiting on a re-read.
    func calibrationFinished() {
        needsCalibration = false
    }

    private func refreshCalibrationState() {
        guard let database = AppDatabase.sharedIfAvailable else {
            // With no database there is nowhere to record a result, so putting
            // the user through a five-game diagnostic every launch would be
            // worse than skipping it.
            needsCalibration = false
            return
        }
        let completed = try? database.metrics.metric(
            key: StoredCalibrationOutcome.completedKey,
            window: "allTime"
        )
        needsCalibration = completed == nil
    }

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
        refreshCalibrationState()
        // Before any board or haptic is produced: the appearance object mirrors
        // the stored haptics setting into `Haptics.isEnabled` when it is first
        // touched, so a user who turned haptics off would otherwise feel every
        // capture until something happened to read a board style.
        BoardAppearance.prepare()
        // Same reason, second channel: without this the app runs on the
        // compiled-in default, so a user who turned sound off hears it again
        // after every relaunch — and the first sound of a session would build
        // its player on the move path.
        Sound.prepare()

        do {
            try await engineService.boot(networks: .standard())
            deviceProfile = await engineService.deviceProfile
            bootState = .ready
        } catch {
            // A missing network is the expected first-run failure; surface it
            // rather than silently running without an engine.
            bootState = .failed(String(describing: error))
            return
        }

        drainPendingAnalysis()
    }

    /// Resumes any analysis pass left pending by a preemption or a crash.
    ///
    /// Without this the queue only drains when the *next* game finishes, so a
    /// user who stops playing keeps an unanalysed game and a Review screen with
    /// no eval curve until they happen to play again.
    ///
    /// Detached from boot so a long backlog cannot delay first paint.
    private func drainPendingAnalysis() {
        let engineService = self.engineService
        Task {
            guard let service = AnalysisService.shared(engineService: engineService) else { return }
            await service.analyzePending()
        }
    }

    func handleBackgrounding() async {
        await engineService.suspendForBackground()
    }

    /// Resolves a route into the tab selection and push stack that show it.
    ///
    /// This is the only place that knows a review lives inside the Today tab, or
    /// that Play is a tab root rather than a push — screens name *where they
    /// want to go* and this decides how the app gets there.
    func navigate(to route: Route) {
        switch route {
        case .play:
            selectedTab = .play
            pendingPlayRequest = true
        case .train:
            selectedTab = .train
        case .profile:
            selectedTab = .profile
        case .review, .moment:
            selectedTab = .today
            // Replace rather than append: arriving at a review from the daily
            // CTA twice should not build a stack of identical screens.
            todayPath = [route]
        case .settings:
            selectedTab = .today
            todayPath = [.settings]
        }
    }

    /// Marks the pending play request consumed so returning to the tab later
    /// does not start a second game.
    func consumePlayRequest() -> Bool {
        defer { pendingPlayRequest = false }
        return pendingPlayRequest
    }

    /// Opens Train with its next session aimed at one habit.
    func navigate(toTrain habit: Habit?) {
        pendingTrainingHabit = habit
        selectedTab = .train
    }

    /// Takes the requested habit, so coming back to Train later gets the week's
    /// ordinary focus rather than a leak the user has already worked through.
    func consumeTrainingHabit() -> Habit? {
        defer { pendingTrainingHabit = nil }
        return pendingTrainingHabit
    }
}
