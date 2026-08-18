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
            #if os(macOS)
                MacRootView()
            #else
                PhoneRootView()
            #endif
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

        TabView {
            Tab("Today", systemImage: "target") {
                NavigationStack { TodayScreen() }
            }
            Tab("Play", systemImage: "play.circle") {
                NavigationStack { PlayScreen() }
            }
            Tab("Train", systemImage: "square.grid.3x3") {
                NavigationStack { TrainScreen() }
            }
            Tab("Profile", systemImage: "chart.line.uptrend.xyaxis") {
                NavigationStack { ProfileScreen() }
            }
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
            case .games: GamesListScreen()
            case .train: TrainScreen()
            case .profile: ProfileScreen()
            case .settings: SettingsScreen()
            }
        }
    }
}
#endif
