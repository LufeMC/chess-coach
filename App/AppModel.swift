import EngineKit
import Foundation
import Observation
import SwiftUI
import TrainingCore

#if canImport(UIKit)
    import UIKit
#endif

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
        case failed(BootFailure)
    }

    /// A boot that did not finish, in the two registers it has to be said in.
    ///
    /// The failure screen used to render `String(describing: error)`, so the
    /// first thing a user could meet was `missingNetwork("nn-1c000.nnue")` with
    /// nothing to tap. The plain sentence is what the screen shows; the raw case
    /// is kept because it is the only thing worth pasting into a bug report.
    struct BootFailure: Equatable {
        var message: String
        var detail: String
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

    /// True while a game is actually being played, which hides the tab bar.
    ///
    /// `PlayScreen` used to get this for free from
    /// `.toolbar(.hidden, for: .tabBar)`, and that modifier still hides the
    /// *system* bar — but the app draws its own now, stacked outside the
    /// `TabView` where no toolbar modifier can reach it. Without this the bar
    /// sat under the board for the whole game, offering three ways to walk out
    /// of a position the user is meant to be concentrating on.
    var isPlayingGame = false

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

    /// A guided game the Play tab should start on arrival, rather than sparring.
    ///
    /// Set beside ``pendingPlayRequest`` because a guided game *is* the play
    /// request, only coached. Carried separately so the flag stays a plain
    /// "start a game" everywhere else.
    ///
    /// This is the only route the app has to `guided.scanThreats.hitRate`, which
    /// gates a required rung-2 skill: prompts are only ever logged inside a
    /// guided game, so a user who follows the daily CTA into sparring every day
    /// can never clear the rung however well they play.
    var pendingGuidedHabit: Habit?

    /// A set the Train tab should start on arrival, consumed by
    /// ``TrainHomeScreen``.
    ///
    /// The mirror of ``pendingPlayRequest``, and it exists for the same reason:
    /// Today's CTA names the set and its price ("10 puzzles · ~4 min"), so
    /// landing on a hub with a length selector and a second Start button asks
    /// for a decision the CTA already took.
    var pendingTrainRequest: Bool = false

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
            // worse than skipping it. Skipping it silently would be worse
            // still, which is what ``databaseError`` and the notice the root
            // view draws from it are for.
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
            bootState = .failed(
                BootFailure(message: Self.explain(error), detail: String(describing: error))
            )
            return
        }

        observeThermalRecovery()
        drainPendingAnalysis()
    }

    /// Runs the boot again after a failure.
    ///
    /// `boot()` guards on `.idle` so nothing can re-enter it while it is
    /// running. A failure is the one state where starting over is exactly what
    /// was asked for, so the gate is reopened here rather than loosened there.
    func retryBoot() async {
        guard case .failed = bootState else { return }
        bootState = .idle
        await boot()
    }

    /// What a boot failure means, in a sentence naming what fixes it.
    ///
    /// Every case here is about a file or a process the user cannot see, so the
    /// sentence has to carry the only action available to them. Reinstalling is
    /// a real fix for a missing network — the nets ship in the bundle — and
    /// reopening is a real fix for a handshake the engine slept through.
    static func explain(_ error: any Error) -> String {
        switch error as? EngineError {
        case .missingNetwork:
            return "Part of the chess engine is missing from this install. Deleting the app and installing it again fixes it."
        case .handshakeTimeout, .searchTimeout:
            return "The chess engine did not start in time. This is usually a busy phone rather than a broken app."
        case .notStarted, .searchAlreadyRunning, .engineRejected, .none:
            return "The chess engine could not start, so there is nothing to play against yet."
        }
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

    // MARK: - Scene phase

    /// The engine drain, while the app is on its way out.
    ///
    /// Kept so the way back in can wait for it. A foreground resume that
    /// overtakes an unfinished drain starts an analysis pass into an engine that
    /// is a microsecond from being stopped, and the pass pauses itself on the
    /// stop — which from the Review screen looks exactly like analysis that
    /// silently refuses to finish.
    private var engineDrain: Task<Void, Never>?

    /// Drains the engine before the process is suspended.
    ///
    /// Synchronous on purpose, and holding a background-execution assertion for
    /// the same reason ``GameSession`` refuses to hop to a `Task` for its clock:
    /// this is the one moment the work has to actually happen. The drain is
    /// three round trips to a thread that is mid-search, and it only starts
    /// after two actor hops — long enough for iOS to suspend the process first,
    /// leaving behind exactly what the drain exists to prevent: a `go` frozen
    /// in flight and a UCI loop that the next launch finds waiting for a
    /// `bestmove` nobody will ever send.
    func handleBackgrounding() {
        let assertion = BackgroundAssertion(name: "Engine drain")
        let engineService = self.engineService
        let previous = engineDrain
        engineDrain = Task {
            await previous?.value
            await engineService.suspendForBackground()
            assertion.end()
        }
    }

    /// Picks the analysis backlog back up when the user comes back.
    ///
    /// The drain above returns a half-finished pass to `pending`, and until this
    /// existed nothing asked for it again: the queue was only pumped at boot and
    /// when a game finished. "Finish a game, switch apps while it analyses, come
    /// back to read the review" is an ordinary evening, and it used to end on a
    /// Review screen promising an analysis that would not arrive until the user
    /// happened to play again.
    ///
    /// Safe to call on every activation. `analyzePending` is guarded by its own
    /// `isDraining` flag and resumes from the evaluations already on disk, so an
    /// activation during a live pass is a no-op rather than a second pass.
    func handleForegrounding() {
        // SwiftUI reports `.active` on the way in as well as on the way back, so
        // this can land before — or instead of — the boot that owns the engine.
        // Draining then would run every queued game against an engine that has
        // not started, and each one would be marked failed for it.
        guard bootState == .ready else { return }

        let engineService = self.engineService
        let drain = engineDrain
        Task {
            // Deliberately *waiting on* the drain rather than queueing behind
            // it: a pass takes tens of seconds, and putting it in the same chain
            // would make the next backgrounding hold its assertion until the
            // whole backlog had been analysed.
            await drain?.value
            guard let service = AnalysisService.shared(engineService: engineService) else { return }
            await service.analyzePending()
        }
    }

    /// Re-drains the analysis queue once the device has cooled off.
    ///
    /// Thermal pressure pauses a pass mid-game (`AnalysisService.shouldPause`),
    /// and a phone that got hot enough to trigger it is usually a phone the user
    /// is still holding — so waiting for the *next* launch to notice is waiting
    /// for the one event that may not come. `.serious` and above is what pauses,
    /// so anything below it is the signal to try again.
    private func observeThermalRecovery() {
        // `queue: .main` so the handler lands on the actor this model already
        // lives on; the work it starts is a detached Task either way.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            guard state == .nominal || state == .fair else { return }
            MainActor.assumeIsolated { self?.drainPendingAnalysis() }
        }
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
            pendingTrainRequest = true
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

    /// Finishes whatever is pushed on Today, then goes on to the next step.
    ///
    /// The review lives in the Today stack, so a screen that says "done here,
    /// now do your puzzles" has to clear the stack as well as change the tab —
    /// otherwise the game the user has just finished reviewing is still sitting
    /// on Today when they come back to it.
    func advance(to route: Route) {
        todayPath.removeAll()
        navigate(to: route)
    }

    /// Opens Play on a coached game aimed at one habit.
    ///
    /// Separate from ``navigate(to:)`` rather than a fifth `Route` case, because
    /// the route enum is also the Today stack's push type and a guided game is
    /// not a push — it is the Play tab, started differently.
    func navigate(toGuidedGame habit: Habit) {
        selectedTab = .play
        pendingGuidedHabit = habit
        pendingPlayRequest = true
    }

    /// Marks the pending play request consumed so returning to the tab later
    /// does not start a second game.
    func consumePlayRequest() -> Bool {
        defer { pendingPlayRequest = false }
        return pendingPlayRequest
    }

    /// The habit the pending game should be coached on, taken so a later visit
    /// to the tab starts an ordinary sparring game.
    func consumeGuidedRequest() -> Habit? {
        defer { pendingGuidedHabit = nil }
        return pendingGuidedHabit
    }

    /// Marks the pending Train request consumed, so coming back to the tab later
    /// lands on the hub rather than dropping straight into another set.
    func consumeTrainRequest() -> Bool {
        defer { pendingTrainRequest = false }
        return pendingTrainRequest
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

/// Permission to keep running for a moment after the app leaves the screen.
///
/// iOS suspends a backgrounded process at the first opportunity and does not
/// warn the code it is about to freeze. Work that has already been *scheduled*
/// is not work that has been *done*, which is the whole hazard: the engine drain
/// is a handful of awaits, and without an assertion the process can stop between
/// any two of them, mid-`stop`, mid-`isready`.
///
/// A no-op where there is no UIKit — the Mac does not suspend apps this way.
@MainActor
final class BackgroundAssertion {

    #if canImport(UIKit)
        private var task: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(name: String) {
        #if canImport(UIKit)
            // The expiration handler is not optional in practice: an assertion
            // still held when the time runs out gets the app killed, and a kill
            // here is precisely the "engine frozen mid-search" state the drain
            // was protecting against.
            task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.end()
            }
        #endif
    }

    /// Hands the time back. Safe to call twice; the second call does nothing.
    func end() {
        #if canImport(UIKit)
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        #endif
    }
}
