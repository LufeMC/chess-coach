import SwiftUI

/// Platform split: iPhone is board-first with a tab bar, Mac is review-centric
/// with a sidebar. Both drive the same `AppModel.Route`.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.bootState {
        case .idle, .booting:
            BootView()
        case .failed(let message):
            BootFailureView(message: message)
        case .ready:
            // Calibration gates the app rather than presenting over it: the
            // rating and starting rung it produces are what every other screen
            // reads, so entering Today first would mean showing a ladder and a
            // leak chart with nothing behind them.
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
    }
}

private struct BootView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Warming up the engine")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BootFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Engine unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
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
