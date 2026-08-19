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

        TabView(selection: $model.selectedTab) {
            Tab("Today", systemImage: "target", value: AppModel.Tab.today) {
                NavigationStack(path: $model.todayPath) {
                    TodayScreen()
                        .navigationDestination(for: AppModel.Route.self) { route in
                            destination(for: route)
                        }
                }
            }
            Tab("Play", systemImage: "play.circle", value: AppModel.Tab.play) {
                NavigationStack { PlayScreen() }
            }
            Tab("Train", systemImage: "square.grid.3x3", value: AppModel.Tab.train) {
                NavigationStack { TrainHomeScreen() }
            }
            Tab("Profile", systemImage: "chart.line.uptrend.xyaxis", value: AppModel.Tab.profile) {
                NavigationStack { ProfileView() }
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
