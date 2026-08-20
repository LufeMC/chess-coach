//
//  TodayModel.swift
//  ChessCoach
//

import Database
import Foundation
import Observation
import SwiftUI
import TrainingCore

/// Everything the Today screen needs from disk, in one `Sendable` value.
///
/// A single struct rather than a handful of `@State`s so the whole read can
/// happen off the main actor and land in one assignment — a screen that arrives
/// in five separate publishes is a screen that visibly reflows five times.
struct TodaySnapshot: Sendable, Equatable {
    var progress: DailyProgress = .zero
    var completedDays: Set<String> = []
    var hasHistory = false
    var hasAnyGame = false
    var rung: Int = 1
    var rungTitle: String = ""
    var focusHabit: String?
    var latestGameID: UUID?
    /// Who the next sparring game is against, so the CTA can name them rather
    /// than saying `Play`. Nil when there was no database to ask.
    var opponentName: String?
    /// The playing rating, for the stat row. Nil until a read succeeds — the
    /// chip renders nothing rather than a placeholder 1100 that would look like
    /// a measurement.
    var userRating: Int?
}

/// Loads the Today screen and holds its computed plan.
@Observable
@MainActor
final class TodayModel {

    /// Nil while the first read is in flight. Distinguishes "loading" from
    /// "loaded and empty", which are completely different screens.
    private(set) var snapshot: TodaySnapshot?

    /// Required-skill progress, 0...1. Arrives after the cheap read — the rung
    /// card renders immediately with a skeleton where the bar goes rather than
    /// holding the whole screen back for it. Progressive reveal: render what is
    /// local now, skeleton only what is still arriving.
    private(set) var rungProgress: Double?
    private(set) var isMeasuringRung = false

    private let now: () -> Date
    private let calendar: Calendar

    init(now: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    // MARK: Derived

    var isLoading: Bool { snapshot == nil }

    var plan: TodayPlan {
        let snapshot = snapshot ?? TodaySnapshot()
        return TodayPlanner.plan(
            progress: snapshot.progress,
            hasHistory: snapshot.hasHistory,
            streakBroken: StreakCalculator.isStreakBroken(
                completedDays: snapshot.completedDays,
                today: now(),
                calendar: calendar
            ),
            opponentName: snapshot.opponentName
        )
    }

    var daySlots: [DaySlot] {
        StreakCalculator.weekSlots(
            completedDays: snapshot?.completedDays ?? [],
            today: now(),
            calendar: calendar,
            hasHistory: snapshot?.hasHistory ?? false
        )
    }

    /// Nil below one day. A `0 day streak` label on first run is a score for a
    /// game the user has not been allowed to play yet.
    var streak: Denominator? {
        Denominator.streak(streakDays)
    }

    /// The raw count, for the stat row's counter — which shows a greyed zero
    /// rather than vanishing, because a counter at rest is not the same thing
    /// as a label announcing a failure.
    var streakDays: Int {
        StreakCalculator.currentStreak(
            completedDays: snapshot?.completedDays ?? [],
            today: now(),
            calendar: calendar
        )
    }

    var rung: RungPresentation {
        let snapshot = snapshot ?? TodaySnapshot()
        return RungPresentation(
            rung: snapshot.rung,
            title: snapshot.rungTitle.isEmpty
                ? (Curriculum.rung(snapshot.rung)?.title ?? "Board Vision")
                : snapshot.rungTitle,
            progress: snapshot.hasAnyGame ? rungProgress : nil,
            focusHabit: snapshot.focusHabit,
            unmeasuredNote: snapshot.hasAnyGame
                ? RungPresentation.measuringNote
                : RungPresentation.firstRunNote
        )
    }

    /// True while the rung bar is still being computed and is worth a skeleton.
    var isRungProgressPending: Bool {
        guard let snapshot, snapshot.hasAnyGame else { return false }
        return rungProgress == nil
    }

    // MARK: Loading

    func load() async {
        guard !AppModel.isRunningTests else {
            snapshot = TodaySnapshot()
            return
        }
        guard let database = AppDatabase.sharedIfAvailable else {
            // No database means nothing was ever saved, which is honestly
            // indistinguishable from a first run — so show that, rather than a
            // half-populated screen built on a failed read.
            snapshot = TodaySnapshot()
            return
        }

        let date = now()
        let calendar = self.calendar
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.read(database: database, now: date, calendar: calendar)
        }.value

        withAnimation(Motion.standard) {
            snapshot = loaded
        }

        // Only worth the ~60 queries and 20 board replays once a game exists.
        // On a genuine first run the answer is already known: unmeasured.
        guard loaded.hasAnyGame else { return }
        await measureRung(database: database)
    }

    private func measureRung(database: AppDatabase) async {
        guard !isMeasuringRung else { return }
        isMeasuringRung = true
        defer { isMeasuringRung = false }

        let service = MetricsService(
            games: database.games,
            moments: database.moments,
            metrics: database.metrics,
            settings: database.settings
        )
        await service.refresh()
        guard let state = service.state else { return }

        withAnimation(Motion.standard) {
            rungProgress = state.decision.requiredSkillProgress
            if var snapshot {
                snapshot.rung = state.rung
                snapshot.rungTitle = Curriculum.rung(state.rung)?.title ?? snapshot.rungTitle
                if let focus = state.focus {
                    snapshot.focusHabit = focus.microGoalTitle
                }
                self.snapshot = snapshot
            }
        }
    }

    /// The cheap read: four indexed queries, no board replay.
    ///
    /// `nonisolated` and `static` so it can run off the main actor without
    /// capturing the model.
    private nonisolated static func read(
        database: AppDatabase,
        now: Date,
        calendar: Calendar
    ) -> TodaySnapshot {
        var snapshot = TodaySnapshot()
        let todayKey = DailyLoop.dayKey(for: now, calendar: calendar)

        let loop = try? database.dailyLoop.loop(for: todayKey)

        // Five weeks covers the current strip plus enough history for any
        // streak the strip can show.
        let recent = (try? database.dailyLoop.recent(limit: 35)) ?? []
        snapshot.completedDays = StreakCalculator.completedDays(recent)
        snapshot.hasHistory = StreakCalculator.hasHistory(recent, todayKey: todayKey)

        let games = (try? database.games.recent(limit: 1)) ?? []
        snapshot.hasAnyGame = !games.isEmpty
        snapshot.latestGameID = games.first?.id

        // Counted only once the pass that produces moments has finished. While
        // analysis is pending or running the count is *unknown*, not zero, and
        // the day keeps its nominal target — reporting zero mid-pass would tick
        // the moments row green seconds before its moments arrived.
        let momentsAvailable: Int? =
            if let latest = games.first, latest.analysis == .complete {
                (try? database.moments.eligibleCount(forGame: latest.id)) ?? 0
            } else {
                nil
            }
        if let loop {
            snapshot.progress = DailyProgress(loop, momentsAvailable: momentsAvailable)
        } else {
            snapshot.progress = DailyProgress(momentsAvailable: momentsAvailable)
        }
        // A game today is history the daily-loop rows may not have caught yet.
        snapshot.hasHistory = snapshot.hasHistory || !games.isEmpty

        if let settings = try? database.settings.current() {
            snapshot.userRating = Int(settings.userRating.rounded())
            snapshot.rung = settings.currentRung
            snapshot.rungTitle = Curriculum.rung(settings.currentRung)?.title ?? ""
            snapshot.focusHabit = settings.weeklyFocusHabit
                .flatMap(Habit.init(rawValue:))?
                .microGoalTitle
        }

        // Through the picker rather than off the stored rating, because the
        // opponent named here has to be the one the Play screen puts above the
        // board — and the offset cycle can move that pick a whole roster entry.
        snapshot.opponentName = OpponentPicker.nextOpponentName(database: database)

        return snapshot
    }

    // MARK: Routing

    /// Maps a plan destination onto app navigation. The plan deliberately does
    /// not know game IDs; this is the only place that does.
    func route(for destination: TodayDestination) -> AppModel.Route {
        switch destination {
        case .play: .play
        case .train: .train
        case .weekSummary: .profile
        case .reviewLatestGame:
            // Falling back to `.play` rather than dead-ending: if there is no
            // game to review, the honest next move is to play one.
            snapshot?.latestGameID.map { AppModel.Route.review(gameID: $0) } ?? .play
        }
    }
}
