import Database
import Foundation
import Observation
import SwiftUI

/// Everything the summary needs that only the finished session knows.
///
/// Carried across the push rather than re-read, so the headline is correct the
/// instant the screen appears — the game is still being written to disk at that
/// point, and a summary that says "loading" about a game the user just played is
/// absurd.
struct GameSummaryTarget: Identifiable, Hashable {
    var gameID: UUID
    var outcome: GameSession.Outcome
    var opponentName: String
    var opponentRating: Int
    var plyCount: Int
    var persistenceFailure: String?

    var id: UUID { gameID }

    static func == (lhs: GameSummaryTarget, rhs: GameSummaryTarget) -> Bool {
        lhs.gameID == rhs.gameID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(gameID)
    }
}

/// Beat 3 of the handoff: what the game amounted to, and the one step that
/// follows it.
///
/// Pushed, not presented. Review is a destination you walk back from, and a
/// sheet would frame the whole post-game loop as a detour from playing.
///
/// The tone model is one number with room around it. No confetti — especially
/// not after a loss, and having it only after a win is worse, because then the
/// screen's *shape* tells you how to feel about your own game. Three numbers,
/// two of which arrive late and skeleton in place until they do.
struct GameSummaryScreen: View {

    let target: GameSummaryTarget

    @State private var model: GameSummaryModel

    init(target: GameSummaryTarget) {
        self.target = target
        _model = State(initialValue: GameSummaryModel(gameID: target.gameID))
    }

    private var presentation: GameSummaryPresentation {
        GameSummaryPresentation.make(
            GameSummaryPresentation.Input(
                outcome: target.outcome,
                opponentName: target.opponentName,
                opponentRating: target.opponentRating,
                plyCount: target.plyCount,
                accuracy: model.accuracy,
                momentCount: model.momentCount,
                analysisState: model.analysisState,
                persistenceFailure: target.persistenceFailure
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presentation.headline)
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer(minLength: 32)

            HStack(alignment: .top, spacing: 0) {
                ForEach(presentation.stats) { stat in
                    StatColumn(stat: stat)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.analysisState == nil || model.analysisState == .pending || model.analysisState == .running {
                // Names the work rather than bouncing a dot at the user.
                Text("Analysing the game — accuracy and moments fill in here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            }

            if let failure = target.persistenceFailure {
                SummaryNotice(text: "This game was not saved: \(failure)")
                    .padding(.top, 18)
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .safeAreaInset(edge: .bottom) {
            action
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.track() }
    }

    @ViewBuilder
    private var action: some View {
        switch presentation.action {
        case .review(let title):
            NavigationLink {
                ReviewScreen(gameID: target.gameID)
            } label: {
                Text(title)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .unavailable(let note):
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One number, with its label a tier below it in the type scale.
private struct StatColumn: View {

    let stat: GameSummaryPresentation.Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = stat.value {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            } else {
                // Skeleton at the value's exact geometry, so nothing jumps when
                // the real number lands.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 46, height: 30)
                    .padding(.vertical, 3)
            }

            Text(stat.label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.25), value: stat.value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(stat.label): \(stat.value ?? "still being worked out")"))
    }
}

private struct SummaryNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary))
    }
}

// MARK: - Model

/// Watches the game's analysis land.
///
/// The pass is queued by `GameSession` as the game finishes and runs at the
/// engine's lowest priority, so the numbers genuinely are not available when
/// this screen first appears. Polling rather than a stream because the analysis
/// service's progress feed is per-pass and process-wide, while this screen only
/// cares about one game's row — a 2-second read of two indexed tables is
/// cheaper than the plumbing to observe it properly, and it stops the moment
/// the pass reaches a terminal state.
@Observable
@MainActor
final class GameSummaryModel {

    private(set) var accuracy: Double?
    private(set) var momentCount: Int?
    private(set) var analysisState: AnalysisState?

    private let gameID: UUID
    private let database: AppDatabase?

    init(gameID: UUID, database: AppDatabase? = AppDatabase.sharedIfAvailable) {
        self.gameID = gameID
        self.database = database
    }

    func track() async {
        while !Task.isCancelled {
            await refresh()
            if analysisState == .complete || analysisState == .failed { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refresh() async {
        guard let database else { return }
        let id = gameID

        let snapshot = await Task.detached(priority: .utility) { () -> Snapshot? in
            guard let game = try? database.games.game(id: id) else { return nil }
            let moments = (try? database.moments.moments(forGame: id))?.count
            return Snapshot(
                accuracy: game.userAccuracy,
                analysisState: game.analysis,
                momentCount: game.analysis == .complete ? (moments ?? 0) : nil
            )
        }.value

        guard let snapshot else { return }
        accuracy = snapshot.accuracy
        analysisState = snapshot.analysisState
        momentCount = snapshot.momentCount
    }

    private struct Snapshot: Sendable {
        var accuracy: Double?
        var analysisState: AnalysisState?
        var momentCount: Int?
    }
}

#Preview("Summary") {
    NavigationStack {
        GameSummaryScreen(
            target: GameSummaryTarget(
                gameID: UUID(),
                outcome: .init(result: "1-0", termination: "checkmate", userWon: true),
                opponentName: "Oscar",
                opponentRating: 1050,
                plyCount: 61
            )
        )
    }
}
