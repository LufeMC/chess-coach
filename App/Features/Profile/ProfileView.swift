//
//  ProfileView.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Rating history, the curriculum ladder, and the rating-leak diagnosis.
///
/// Three sections in one scroll, ordered by how often the user needs them:
/// where they are (the chart), what they are working towards (the ladder), and
/// what is costing them points right now (the leaks).
///
/// Note the shape difference between them, which follows the house rule "prose
/// in cards, data in rows": the chart is a self-contained instrument and gets a
/// card; the ladder and the leak table are data and sit in the open, separated
/// by rules rather than boxed.
///
/// This is the screen that answers "is a year of this working", so it is the one
/// screen allowed to spend words. The chart says what the number means in a
/// sentence, and the leak table says what to do about it — both of which the
/// user would otherwise have to infer from a shape.
struct ProfileView: View {

    @Environment(AppModel.self) private var appModel

    @State private var model = ProfileModel()
    @State private var selectedLeak: LeakRow?

    var body: some View {
        #if os(macOS)
            // The Mac sidebar's detail column is not a navigation stack, so the
            // leak drill-in needs one of its own. On iOS `RootView` already
            // provides it.
            NavigationStack { content }
        #else
            content
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                RatingChartCard(model: model)

                CurriculumLadderSection(
                    state: model.snapshot.ladder,
                    onToggle: { model.toggleRung($0) }
                )

                RatingLeaksSection(
                    leaks: model.snapshot.leaks,
                    windowGames: model.snapshot.leakWindowGames,
                    state: model.snapshot.leakState,
                    trends: model.leakTrends,
                    onSelect: { selectedLeak = $0 },
                    onTrain: { train($0) }
                )

                if let loadError = model.loadError {
                    Text(loadError)
                        .typeRole(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .animation(Motion.standard, value: model.snapshot.ladder.expandedRungID)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationDestination(item: $selectedLeak) { leak in
            LeakDetailScreen(
                leak: leak,
                occurrences: model.snapshot.occurrences(for: leak.causeTag),
                onTrain: { train(leak) }
            )
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    /// The diagnosis's one exit. Naming *where the user wants to go* and letting
    /// `AppModel` decide how the app gets there is what keeps this screen from
    /// knowing that training is a tab.
    private func train(_ leak: LeakRow) {
        selectedLeak = nil
        // The leak's habit rides along, so the session that opens drills the
        // thing the row just diagnosed. A row that only reached the queue's
        // front page would leave the user to translate a cause tag into the
        // right practice themselves, which is the whole job of this screen.
        appModel.navigate(toTrain: leak.habit)
    }
}

// MARK: - Previews

#if DEBUG

/// Sample data, so the design is reviewable without a populated database.
///
/// Kept in `DEBUG` and never used by the shipping screen: a preview fixture
/// that leaks into production is how a screen ends up showing plausible numbers
/// that nobody measured.
extension ProfileSnapshot {

    static func sample(now: Date = Date()) -> ProfileSnapshot {
        var metrics = MetricSnapshot()
        metrics.set(0.8, samples: 12, for: .hangingPiecePer100, window: .lastGames(8))
        metrics.set(3.2, samples: 12, for: .blundersPer100, window: .lastGames(12))
        metrics.set(0.61, samples: 30, for: .cleanRetryRate, window: .lastGames(30))
        metrics.set(3, samples: 3, for: .kqkDrillCleanStreak, window: .allTime)
        metrics.set(3, samples: 3, for: .krkDrillCleanStreak, window: .allTime)
        metrics.set(1180, samples: 40, for: .puzzleRating, window: .allTime)
        metrics.set(0.72, samples: 24, for: .guidedScanThreatsHitRate, window: .lastGames(24))

        let ladder = Curriculum.default
        let decision = advancement(
            state: AdvancementState(
                currentRung: 2,
                metrics: metrics,
                gamesAtRung: 6,
                daysAtRung: 9
            ),
            ladder: ladder
        )

        let leaks: [Leak] = [
            Leak(causeTag: .hungMovedPiece, habit: .blunderCheck,
                 weightedEPLost: 16.8, epLostPerGame: 0.42, count: 14, deltaVsPreviousWeek: 0.03),
            Leak(causeTag: .missedNewThreat, habit: .whatChanged,
                 weightedEPLost: 12.4, epLostPerGame: 0.31, count: 11, deltaVsPreviousWeek: -0.02),
            Leak(causeTag: .forcingBias, habit: .candidatesFirst,
                 weightedEPLost: 4.8, epLostPerGame: 0.12, count: 6, deltaVsPreviousWeek: 0.0),
            Leak(causeTag: .miscountedExchange, habit: .calcToQuiet,
                 weightedEPLost: 2.4, epLostPerGame: 0.06, count: 4, deltaVsPreviousWeek: 0.0)
        ]

        // A rating walk with a shrinking deviation, which is what a settling
        // estimate actually looks like.
        var ratingPoints: [ProfileSeriesPoint] = []
        var puzzlePoints: [ProfileSeriesPoint] = []
        var accuracyPoints: [ProfileSeriesPoint] = []
        var rating = 1080.0
        var puzzle = 1050.0
        var deviation = 120.0
        for day in stride(from: 84, through: 0, by: -3) {
            let date = now.addingTimeInterval(-Double(day) * 86_400)
            rating += Double.random(in: -22...26)
            puzzle += Double.random(in: -18...24)
            deviation = max(48, deviation - 2.2)
            ratingPoints.append(ProfileSeriesPoint(date: date, value: rating, deviation: nil))
            puzzlePoints.append(ProfileSeriesPoint(date: date, value: puzzle, deviation: deviation))
            accuracyPoints.append(
                ProfileSeriesPoint(date: date, value: Double.random(in: 68...92), deviation: nil)
            )
        }

        return ProfileSnapshot(
            currentRung: 2,
            series: [.rating: ratingPoints, .accuracy: accuracyPoints, .puzzles: puzzlePoints],
            ladder: CurriculumLadderState(
                ladder: ladder,
                currentRung: 2,
                metrics: metrics,
                blockers: decision.blockers
            ),
            leaks: LeakTable.rows(from: leaks),
            leakWindowGames: 40,
            leakState: .measured,
            occurrences: [
                CauseTag.hungMovedPiece.rawValue: (0..<9).map { index in
                    LeakOccurrence(
                        id: UUID(),
                        gameID: UUID(),
                        playedAt: now.addingTimeInterval(-Double(index) * 9 * 86_400),
                        ply: 27 + index * 4,
                        playedSAN: "Nf3",
                        bestSAN: "Qe2",
                        epLost: 0.38 - Double(index) * 0.02,
                        opponentRating: 1150,
                        result: "0-1"
                    )
                }
            ],
            generatedAt: now
        )
    }
}

#Preview("Populated") {
    NavigationStack {
        ProfilePreviewHost(model: ProfileModel(snapshot: .sample()))
    }
}

#Preview("Empty") {
    NavigationStack {
        ProfilePreviewHost(model: ProfileModel(snapshot: .empty()))
    }
}

/// Preview shell that drives the same sections with an injected model.
///
/// Deliberately does not build an `AppModel`: constructing one boots services,
/// and a preview that boots the engine is a preview that takes forty seconds to
/// show a chart.
private struct ProfilePreviewHost: View {
    @State var model: ProfileModel
    @State private var selectedLeak: LeakRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                RatingChartCard(model: model)
                CurriculumLadderSection(
                    state: model.snapshot.ladder,
                    onToggle: { model.toggleRung($0) }
                )
                RatingLeaksSection(
                    leaks: model.snapshot.leaks,
                    windowGames: model.snapshot.leakWindowGames,
                    state: model.snapshot.leakState,
                    trends: model.leakTrends,
                    onSelect: { selectedLeak = $0 }
                )
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationDestination(item: $selectedLeak) { leak in
            LeakDetailScreen(leak: leak, occurrences: model.snapshot.occurrences(for: leak.causeTag))
        }
    }
}

#endif
