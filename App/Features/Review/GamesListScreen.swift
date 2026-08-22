import Database
import Foundation
import Observation
import SwiftUI

// The file name is a leftover: this type was called `GameLibraryScreen` only to
// avoid colliding with a `GamesListScreen` placeholder that has since been
// deleted along with the rest of `App/Features/Placeholders.swift`. The name is
// kept because it is the one both call sites use — `TodayScreen`'s history
// glyph and the macOS sidebar — and renaming a wired-up screen to match a file
// name is churn, not cleanup.

/// The list of played games, and the way into Review.
struct GameLibraryScreen: View {

    @State private var model = GameLibraryModel()

    var body: some View {
        // The stack is Mac-only, and that is the whole point of the split.
        //
        // On the Mac this screen is planted directly in the sidebar's detail
        // column, which is not a navigation container, so it has to bring its
        // own or the row taps have nowhere to push to. On iPhone it arrives by
        // `NavigationLink` from `TodayScreen`'s history glyph — and `TodayScreen`
        // already sits inside the Today tab's `NavigationStack` (`RootView`), so
        // a stack here would be a stack inside a stack: two navigation bars, a
        // title stranded under a back button, and a push animation that runs on
        // the wrong container.
        //
        // This is what the previous comment said to do — "if it ever gets
        // embedded in an existing NavigationStack, drop this one" — written when
        // the Mac sidebar was the only caller. The iPhone caller arrived later
        // and the condition went unnoticed.
        #if os(macOS)
            NavigationStack { listing }
        #else
            listing
        #endif
    }

    private var listing: some View {
        content
            .navigationTitle("Games")
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            // The final layout is known — rows of a fixed height — so it is
            // drawn rather than covered by a spinner. `craft-standards.md`:
            // no spinners outside a button, and nothing at all under ~200ms.
            LoadingRows()

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
                    .typeRole(.headline)
                Text(row.subtitle)
                    .typeRole(.caption)
                if let toReview = row.toReviewText {
                    Text(toReview)
                        .typeRole(.caption, appliesForeground: false)
                        .foregroundStyle(Palette.accent.dynamic)
                }
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
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(row.accuracyText == "—" ? .tertiary : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// The list's own shape, drawn while the read is in flight.
private struct LoadingRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonView(width: 22, height: 22, cornerRadius: 11)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonView(width: 96, height: 14)
                        SkeletonView(width: 150, height: 11)
                    }
                    Spacer(minLength: 8)
                    SkeletonView(width: 34, height: 12)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel(Text("Loading your games"))
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

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[GameSummaryRow], LoadFailure> in
            do {
                let games = try database.games.recent(limit: 100)
                return .success(
                    games.map { game in
                        GameSummaryRow.make(
                            game: game,
                            opponentName: OpponentRoster.opponent(forRating: game.opponentRating).name,
                            // An indexed count per row rather than a fetch: it is
                            // the same number Today's CTA promises, so a row that
                            // says "2 to review" and the checklist step that sends
                            // you there cannot disagree.
                            toReviewCount: (try? database.moments.eligibleCount(forGame: game.id)) ?? 0
                        )
                    }
                )
            } catch {
                return .failure(LoadFailure(message: String(describing: error)))
            }
        }.value

        switch outcome {
        case .failure(let failure):
            AppLog.persistence.error("Could not list games: \(failure.message, privacy: .public)")
            state = .failed(StorageFailureText.reading(failure.message))
        case .success(let loaded):
            rows = loaded
            state = .ready
        }
    }

    /// `any Error` is not `Sendable`; this crosses an actor boundary.
    struct LoadFailure: Error, Sendable {
        var message: String
    }
}
