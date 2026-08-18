import Database
import Foundation
import Observation
import SwiftUI

// NOTE FOR INTEGRATION: this is the real games list. The placeholder
// `GamesListScreen` in `App/Features/Placeholders.swift` still owns that name, so
// this type is `GameLibraryScreen` to keep the app compiling while both exist.
// When the placeholder is deleted, either rename this type to `GamesListScreen`
// or point `RootView.MacRootView` at `GameLibraryScreen()`. One line either way.

/// The list of played games, and the way into Review.
struct GameLibraryScreen: View {

    @State private var model = GameLibraryModel()

    var body: some View {
        // Its own stack: today this screen is planted directly in the Mac
        // sidebar's detail column, which is not a navigation container. If it
        // ever gets embedded in an existing `NavigationStack`, drop this one.
        NavigationStack {
            content
                .navigationTitle("Games")
                .task { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Could not read your games", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }

        case .ready where model.rows.isEmpty:
            ContentUnavailableView {
                Label("No games yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Play a game and it will appear here with its analysis.")
            }

        case .ready:
            List(model.rows) { row in
                NavigationLink {
                    ReviewScreen(gameID: row.id)
                } label: {
                    GameLibraryRow(row: row)
                }
            }
            #if os(iOS)
                .listStyle(.insetGrouped)
            #else
                .listStyle(.inset)
            #endif
            .refreshable { await model.load(force: true) }
        }
    }
}

/// One game, at a glance.
///
/// Result leads because it is what the reader is looking for; accuracy is a
/// number, so it goes right-aligned and monospaced; and the analysis indicator
/// appears **only when analysis is outstanding**. A state marker on every row
/// would be a badge on 100% of rows, which conveys tone rather than data.
private struct GameLibraryRow: View {
    let row: GameSummaryRow

    var body: some View {
        HStack(spacing: 12) {
            Text(row.resultSymbol)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(row.resultTint.opacity(0.18)))
                .foregroundStyle(row.resultTint)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.opponent)
                    .font(.body.weight(.medium))
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let indicator = row.analysisIndicator {
                Label(indicator.title, systemImage: indicator.symbol)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(indicator.title))
            }

            Text(row.accuracyText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(row.accuracyText == "—" ? .tertiary : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Model

@Observable
@MainActor
final class GameLibraryModel {

    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var rows: [GameSummaryRow] = []

    private let database: AppDatabase?

    init(database: AppDatabase? = AppDatabase.sharedIfAvailable) {
        self.database = database
    }

    func load(force: Bool = false) async {
        guard force || state == .loading else { return }
        guard let database else {
            state = .failed("The games database could not be opened.")
            return
        }

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[Database.Game], LoadFailure> in
            do {
                return .success(try database.games.recent(limit: 100))
            } catch {
                return .failure(LoadFailure(message: String(describing: error)))
            }
        }.value

        switch outcome {
        case .failure(let failure):
            state = .failed(failure.message)
        case .success(let games):
            rows = games.map { game in
                GameSummaryRow.make(
                    game: game,
                    opponentName: OpponentRoster.opponent(forRating: game.opponentRating).name
                )
            }
            state = .ready
        }
    }

    /// `any Error` is not `Sendable`; this crosses an actor boundary.
    struct LoadFailure: Error, Sendable {
        var message: String
    }
}
