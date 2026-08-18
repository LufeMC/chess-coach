//
//  TrainHomeScreen.swift
//  ChessCoach
//

import Database
import SwiftUI
import TrainingCore

/// The Train tab: today's puzzle set, and the endgame drills.
///
/// Two entries, kept apart on purpose. A puzzle is one move to find and ten of
/// them is a bounded, predictable session; a drill is a technique played out
/// against an engine for twenty moves. Mixing drills into the queue would make
/// "10 puzzles" mean anywhere between four minutes and forty, which is exactly
/// the kind of promise a daily habit cannot afford to break.
struct TrainHomeScreen: View {

    @Environment(AppModel.self) private var model
    @State private var route: TrainRoute?

    /// Computed rather than stored: `AppDatabase.shared` opens once and caches,
    /// so reading it per access is free, and storing it would move the open into
    /// the view's initialiser.
    private var database: AppDatabase? { AppDatabase.sharedIfAvailable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dailySetCard

                VStack(alignment: .leading, spacing: 12) {
                    Text("Endgame drills")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(DrillFamilyPresentation.all) { family in
                        EndgameDrillCard(
                            family: family,
                            mastery: mastery(for: family.kind),
                            onSelect: { route = .drill(family.kind) }
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationTitle("Train")
        .trainingCover(item: $route) { route in
            destination(for: route)
        }
    }

    // MARK: Daily set

    private var dailySetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's set")
                .font(.headline)

            Text(dueDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                route = .puzzles
            } label: {
                Text("Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(database?.puzzleQueries == nil)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary))
    }

    private var dueDescription: String {
        guard let database, database.puzzleQueries != nil else {
            return "The puzzle corpus is missing from this build."
        }
        let target = DomainTuning.default.cards.sessionTargetSize
        let due = (try? database.srs.dueCount(at: Date())) ?? 0
        guard due > 0 else { return "\(target) puzzles." }
        return "\(target) puzzles — \(due) due for review."
    }

    // MARK: Drills

    private func mastery(for kind: EndgameDrillKind) -> DrillMastery {
        let tuning = DomainTuning.default.curriculum
        let required = kind.isSetScored ? tuning.kpkSetSize : tuning.drillCleanStreakRequired
        let streak = database.map { Int($0.metrics.value(kind.streakMetricKey.rawValue)) } ?? 0
        return DrillMastery(cleanStreak: streak, required: required)
    }

    // MARK: Routing

    @ViewBuilder
    private func destination(for route: TrainRoute) -> some View {
        switch route {
        case .puzzles:
            if let service = trainingService() {
                NavigationStack {
                    PuzzleSessionScreen(model: PuzzleSessionModel(driver: service))
                }
            } else {
                unavailable
            }
        case let .drill(kind):
            NavigationStack {
                EndgameDrillScreen(
                    model: EndgameDrillModel(
                        kind: kind,
                        opponent: EngineDrillOpponent(engine: model.engineService),
                        recorder: trainingService()
                    )
                )
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Training unavailable", systemImage: "square.grid.3x3")
        } description: {
            Text("The app could not open its databases.")
        }
    }

    /// Builds the session service from the shared databases.
    ///
    /// This composition belongs to whoever owns app-wide wiring; until that
    /// exists it lives here, where the only screen that needs it can see it.
    private func trainingService() -> TrainingService? {
        guard let database, let corpus = database.puzzleQueries else { return nil }
        return TrainingService(
            srs: database.srs,
            corpus: corpus,
            metrics: database.metrics,
            dailyLoop: database.dailyLoop,
            settings: database.settings,
            momentPositions: GameMomentPositionSource(games: database.games, moments: database.moments)
        )
    }
}

/// Where the Train tab can go.
enum TrainRoute: Identifiable, Hashable {
    case puzzles
    case drill(EndgameDrillKind)

    var id: String {
        switch self {
        case .puzzles: "puzzles"
        case let .drill(kind): "drill.\(kind.rawValue)"
        }
    }
}

extension View {

    /// A full-screen cover on iPhone, a sheet on Mac.
    ///
    /// Both are the same decision: a solve session takes the whole surface,
    /// because a board with a tab bar under it invites leaving mid-puzzle, and a
    /// half-finished puzzle is scored as a failure.
    @ViewBuilder
    func trainingCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
            fullScreenCover(item: item, content: content)
        #else
            sheet(item: item, content: content)
        #endif
    }
}
