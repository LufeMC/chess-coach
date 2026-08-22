import BoardUI
import SwiftUI

/// Platform split: iPhone is board-first with a tab bar, Mac is review-centric
/// with a sidebar. Both drive the same `AppModel.Route`.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.bootState {
        case .idle, .booting:
            BootView()
        case .failed(let failure):
            BootFailureView(failure: failure) {
                Task { await model.retryBoot() }
            }
        case .ready:
            VStack(spacing: 0) {
                // Every screen below this saves something, and none of them can
                // when the database did not open. Each says so in its own words
                // when the user reaches it; this is the one place that can say
                // it before they spend a game finding out.
                if model.databaseError != nil {
                    StorageUnavailableNotice()
                }

                // Calibration gates the app rather than presenting over it: the
                // rating and starting rung it produces are what every other
                // screen reads, so entering Today first would mean showing a
                // ladder and a leak chart with nothing behind them.
                if model.needsCalibration {
                    CalibrationScreen { model.calibrationFinished() }
                } else {
                    #if os(macOS)
                        MacRootView()
                    #else
                        PhoneRootView()
                    #endif
                }
            }
            // The Haptics switch in Settings names the board's own feedbacks —
            // lift, drop, refusal, capture, check — and BoardUI has no way to
            // see a setting the app stores. Handing it down from the one root
            // every screen hangs off is what makes the switch tell the truth.
            // `BoardAppearance` is `@Observable`, so flipping it re-renders the
            // boards with the new value rather than waiting for a relaunch.
            .environment(\.boardHapticsEnabled, BoardAppearance.shared.hapticsEnabled)
        }
    }
}

/// The wait before the first screen.
///
/// "Warming up the engine" was the first sentence the app ever said, and it was
/// about a subsystem. This one is about the board, and it says how long: the
/// engine measures this device on every launch, which is real work with no
/// visible cause, and a wait nobody has sized reads as a wait that has hung.
private struct BootView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            VStack(spacing: 4) {
                Text("Getting the board ready")
                    .font(.footnote.weight(.semibold))
                Text("A few seconds — the app measures this device's speed each launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
    }
}

/// The engine did not start.
///
/// A dead end with a Swift enum printed in it was the worst screen in the app:
/// nothing to tap, and a sentence naming a type. The plain reason is the
/// content, trying again is the action — a handshake that timed out on a busy
/// phone usually succeeds on the second attempt — and the raw case stays
/// reachable for the one reader it is any use to.
private struct BootFailureView: View {
    let failure: AppModel.BootFailure
    let onRetry: () -> Void

    @State private var isShowingDetail = false

    var body: some View {
        ContentUnavailableView {
            Label("The engine could not start", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 10) {
                Text(failure.message)

                Button(isShowingDetail ? "Hide details" : "Show details") {
                    isShowingDetail.toggle()
                }
                .font(.footnote)

                if isShowingDetail {
                    Text(failure.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } actions: {
            Button("Try again", action: onRetry)
                .buttonStyle(.primaryAction)
        }
        .animation(Motion.standard, value: isShowingDetail)
    }
}

/// Nothing can be written to disk.
///
/// Rare — it takes an unwritable Application Support directory — and total when
/// it happens: no rating, no saved games, no review. The three screens that hit
/// it each explain themselves once the user is standing on them, which is one
/// screen too late.
private struct StorageUnavailableNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nothing can be saved right now")
                .typeRole(.label)
            Text("You can still play, but games, ratings and reviews are lost when the app closes.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.caution.dynamic.opacity(0.16))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.hairline.dynamic)
                .frame(height: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing can be saved right now. You can still play, but games, ratings and reviews are lost when the app closes.")
    }
}

#if os(iOS)
private struct PhoneRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        // The system tab bar is hidden per tab and ``MainTabBar`` takes its place
        // in a `VStack`. `TabView` is still what holds the tabs, so each one
        // keeps its own navigation stack and its own lazily-built content —
        // rebuilding that with a `switch` would throw away both.
        //
        // A `VStack` rather than a `safeAreaInset` on the `TabView`: with the
        // system bar hidden, an inset is drawn *over* the tab content instead of
        // shrinking it, which ate the bottom of every screen's action bar.
        // Stacking makes the tab content genuinely shorter, which is the thing
        // the screens inside need to be true.
        VStack(spacing: 0) {
            tabs
            if !model.isPlayingGame {
                MainTabBar(selection: $model.selectedTab)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(Motion.standard, value: model.isPlayingGame)
    }

    private var tabs: some View {
        @Bindable var model = model

        return TabView(selection: $model.selectedTab) {
            Tab("Today", systemImage: "house.fill", value: AppModel.Tab.today) {
                NavigationStack(path: $model.todayPath) {
                    TodayScreen()
                        .navigationDestination(for: AppModel.Route.self) { route in
                            destination(for: route)
                        }
                }
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Play", systemImage: "play.fill", value: AppModel.Tab.play) {
                NavigationStack { PlayScreen() }
                    .toolbar(.hidden, for: .tabBar)
            }
            Tab("Train", systemImage: "dumbbell.fill", value: AppModel.Tab.train) {
                NavigationStack { TrainHomeScreen() }
                    .toolbar(.hidden, for: .tabBar)
            }
            Tab("Profile", systemImage: "person.fill", value: AppModel.Tab.profile) {
                NavigationStack { ProfileView() }
                    .toolbar(.hidden, for: .tabBar)
            }
        }
    }

    /// The Today stack's push targets.
    ///
    /// Only routes that are genuinely *pushes* appear here — tab roots are
    /// handled by `AppModel.navigate(to:)` changing the selection instead.
    @ViewBuilder
    private func destination(for route: AppModel.Route) -> some View {
        switch route {
        case .review(let gameID):
            ReviewScreen(gameID: gameID)
        case .moment(let gameID, let momentID):
            ReviewScreen(gameID: gameID, focusMomentID: momentID)
        case .settings:
            SettingsScreen()
        case .play, .train, .profile:
            // Unreachable: these change the tab rather than pushing. Rendering
            // nothing is better than a crash if a future deep link says otherwise.
            EmptyView()
        }
    }
}
#endif

#if os(macOS)
private struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .today

    enum SidebarItem: String, CaseIterable, Identifiable {
        case today = "Today"
        case games = "Games"
        case train = "Train"
        case profile = "Profile"
        case settings = "Settings"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .today: "target"
            case .games: "list.bullet.rectangle"
            case .train: "square.grid.3x3"
            case .profile: "chart.line.uptrend.xyaxis"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch selection {
            case .today, nil: TodayScreen()
            case .games: GameLibraryScreen()
            case .train: TrainHomeScreen()
            case .profile: ProfileView()
            case .settings: SettingsScreen()
            }
        }
    }
}
#endif
