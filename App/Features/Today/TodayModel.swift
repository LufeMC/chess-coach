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
    /// A habit a required skill on the current rung is gated on and which only
    /// guided games can measure. See ``TodayModel/guidedGate(for:)``.
    var guidedGate: Habit?
    var latestGameID: UUID?
    /// Who the next sparring game is against, so the CTA can name them rather
    /// than saying `Play`. Nil when there was no database to ask.
    var opponentName: String?
    /// The playing rating, for the stat row. Nil until a read succeeds — the
    /// chip renders nothing rather than a placeholder 1100 that would look like
    /// a measurement.
    var userRating: Int?
    /// How far the rating has moved since the last day it was recorded. Nil
    /// when there is no earlier point to compare against, which is the honest
    /// state on day one — the header then shows the number alone.
    var ratingDelta: Int?
    /// True when the store could not be opened, so nothing on this screen was
    /// read and nothing the user does now will be saved.
    ///
    /// A separate flag rather than a zeroed snapshot: a failed read and a first
    /// run produce identical-looking numbers, and showing "Play your first
    /// game" to a user on day thirty is the app lying about their own history.
    var isUnavailable = false
}

/// Loads the Today screen and holds its computed plan.
@Observable
@MainActor
final class TodayModel {

    /// Nil while the first read is in flight. Distinguishes "loading" from
    /// "loaded and empty", which are completely different screens.
    private(set) var snapshot: TodaySnapshot?

    /// Required-skill progress. Arrives after the cheap read — the rung card
    /// renders immediately with a skeleton where the bar goes rather than
    /// holding the whole screen back for it. Progressive reveal: render what is
    /// local now, skeleton only what is still arriving.
    ///
    /// Stays `nil` when the answer is "nothing is measured yet", which is a
    /// different thing from "still working it out" — hence
    /// ``hasMeasuredRung`` below.
    private(set) var rungSkills: RungSkillProgress?
    private(set) var isMeasuringRung = false

    /// Whether the rung measurement has run to a conclusion, whatever that
    /// conclusion was.
    ///
    /// Separate from `rungSkills != nil` because the measurement can legitimately
    /// conclude that there is nothing to draw. Without this the skeleton keyed
    /// off a nil bar would spin under the card for the rest of the session on
    /// exactly the accounts that have least to look at.
    private(set) var hasMeasuredRung = false

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
            opponentName: snapshot.opponentName,
            guidedGate: snapshot.guidedGate
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

    /// The raw count. One number, one place: the streak is drawn in the week
    /// strip beside the seven day marks that explain it, and nowhere else.
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
            rungCount: Curriculum.default.count,
            title: snapshot.rungTitle.isEmpty
                ? (Curriculum.rung(snapshot.rung)?.title ?? "Board Vision")
                : snapshot.rungTitle,
            skills: snapshot.hasAnyGame ? rungSkills : nil,
            focusHabit: snapshot.focusHabit,
            unmeasuredNote: snapshot.hasAnyGame
                ? RungPresentation.measuringNote
                : RungPresentation.firstRunNote
        )
    }

    /// True while the rung bar is still being computed and is worth a skeleton.
    var isRungProgressPending: Bool {
        guard let snapshot, snapshot.hasAnyGame else { return false }
        return !hasMeasuredRung
    }

    // MARK: Loading

    func load() async {
        guard !AppModel.isRunningTests else {
            snapshot = TodaySnapshot()
            return
        }
        guard let database = AppDatabase.sharedIfAvailable else {
            // Not a first run: a first run has an empty store, this has no
            // store. The screen says so, because the alternative is showing a
            // user on day thirty a zeroed streak and "Play your first game",
            // and then discarding the game they play.
            snapshot = TodaySnapshot(isUnavailable: true)
            return
        }

        let date = now()
        let calendar = self.calendar
        // Read on this actor and carried across, because the Train screen owns
        // the session-length preference and its constants live on a `@MainActor`
        // model. Copying the key into this file instead would put the name of a
        // stored value in two places, which is how the two screens start
        // disagreeing about how long a set is.
        let lengths = TrainHomeModel.lengths
        let lengthKey = TrainHomeModel.lengthKey
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.read(
                database: database,
                now: date,
                calendar: calendar,
                puzzleLengths: lengths,
                puzzleLengthKey: lengthKey
            )
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
        // Answered either way. A refresh that produced no state is still an
        // answer — "we cannot measure this" — and leaving the flag false would
        // hold the skeleton under the card forever rather than falling through
        // to the note that explains the absence.
        hasMeasuredRung = true
        guard let state = service.state else { return }

        withAnimation(Motion.standard) {
            rungSkills = Self.skillProgress(for: state)
            if var snapshot {
                snapshot.rung = state.rung
                snapshot.rungTitle = Curriculum.rung(state.rung)?.title ?? snapshot.rungTitle
                snapshot.guidedGate = Self.guidedGate(for: state)
                if let focus = state.focus {
                    snapshot.focusHabit = focus.microGoalTitle
                }
                self.snapshot = snapshot
            }
        }
    }

    /// The rung bar, from the advancement decision the ladder already made.
    ///
    /// ## The bug this shape exists to stop
    ///
    /// The card used to draw ``AdvancementDecision/requiredSkillProgress``
    /// directly. That figure counts an *unmeasured* required skill as unmet,
    /// which is exactly right for deciding advancement — "we have never measured
    /// this" is not evidence of competence — and exactly wrong for a progress
    /// bar. On the day after a user's first game nothing has been measured yet,
    /// so the home screen drew a confident 0% and went on drawing it for a week
    /// or two: the app telling a player it has just placed on rung 2 that they
    /// have made no progress at all. The "Measuring — a few more games" note
    /// written for precisely that state was unreachable, because it only
    /// appeared before the first game existed.
    ///
    /// So: nothing measured *and* games are what would measure it → no bar, keep
    /// the note. Anything measured → a bar, with the caption saying how much of
    /// the denominator is still unlooked-at.
    ///
    /// The `sampleSource` test is what keeps the note honest. A rung-1 user is
    /// gated on `basicMates`, which is measured from endgame-drill runs and
    /// which no amount of sparring will ever move — showing "a few more games"
    /// there is an instruction that does not work, and a user who follows it and
    /// watches nothing happen concludes the ladder is broken. Those rungs get
    /// the bar and the count instead, and the Profile ladder names the drill.
    nonisolated static func skillProgress(for state: CurriculumState) -> RungSkillProgress? {
        let requiredIDs = Set((Curriculum.rung(state.rung)?.requiredSkills ?? []).map(\.id))
        let evaluations = state.decision.evaluations.filter { requiredIDs.contains($0.skillID) }
        guard !evaluations.isEmpty else { return nil }

        let unmeasured = evaluations.filter { !$0.unmeasuredCriteria.isEmpty }
        let waitingOnPlay = unmeasured.allSatisfy { evaluation in
            evaluation.unmeasuredCriteria.allSatisfy { criterion in
                criterion.metricKey.presentation.sampleSource == nil
            }
        }
        if unmeasured.count == evaluations.count, waitingOnPlay { return nil }

        return RungSkillProgress(
            met: evaluations.filter(\.isMet).count,
            total: evaluations.count,
            unmeasured: unmeasured.count
        )
    }

    /// A required skill on this rung that only a guided game can ever measure.
    ///
    /// ## Why this is worth a whole path through the app
    ///
    /// `r2.threatAwareness` is required, and one of its two criteria is
    /// `guided.scanThreats.hitRate`. That metric is written in exactly one
    /// place: a guided prompt that fired and was answered. A user who follows
    /// the daily CTA plays sparring games, so the criterion stays unmeasured,
    /// the skill stays unmet, and rung 2 → 3 is unreachable however well they
    /// play — with nothing anywhere saying which door is shut.
    ///
    /// Unmeasured, not unmet: a criterion the user is simply failing needs
    /// practice, and the ordinary loop supplies it. This is the narrower case of
    /// a number the loop cannot produce at all.
    nonisolated static func guidedGate(for state: CurriculumState) -> Habit? {
        let requiredIDs = Set((Curriculum.rung(state.rung)?.requiredSkills ?? []).map(\.id))
        for evaluation in state.decision.evaluations where requiredIDs.contains(evaluation.skillID) {
            for criterion in evaluation.unmeasuredCriteria {
                if let habit = guidedHabit(for: criterion.metricKey) { return habit }
            }
        }
        return nil
    }

    /// The habit whose guided prompts produce a metric, for the metrics that
    /// have no other producer. Nil for everything a game or a drill can move.
    nonisolated static func guidedHabit(for key: MetricKey) -> Habit? {
        key == .guidedScanThreatsHitRate ? .scanThreats : nil
    }

    /// The cheap read: four indexed queries, no board replay.
    ///
    /// `nonisolated` and `static` so it can run off the main actor without
    /// capturing the model.
    private nonisolated static func read(
        database: AppDatabase,
        now: Date,
        calendar: Calendar,
        puzzleLengths: [Int],
        puzzleLengthKey: String
    ) -> TodaySnapshot {
        var snapshot = TodaySnapshot()
        let todayKey = DailyLoop.dayKey(for: now, calendar: calendar)

        let loop = try? database.dailyLoop.loop(for: todayKey)

        // Five weeks covers the current strip plus enough history for any
        // streak the strip can show.
        let recent = (try? database.dailyLoop.recent(limit: 35)) ?? []
        snapshot.completedDays = StreakCalculator.completedDays(recent)
        snapshot.hasHistory = StreakCalculator.hasHistory(recent, todayKey: todayKey)

        // Calibration games are filtered out, not merely skipped over. They are
        // a measurement the app asks for before the loop starts, played against
        // an arbitrary opponent at an arbitrary strength, and counting the last
        // of them as "today's game" means the user's real first day opens with
        // the game square already ticked and a review of a game they were told
        // was a test.
        let games = ((try? database.games.recent(limit: 10)) ?? [])
            .filter { $0.gameMode != .calibration }
        let latest = games.first
        snapshot.hasAnyGame = latest != nil
        snapshot.latestGameID = latest?.id

        snapshot.progress = DailyProgress(
            loop ?? DailyLoop(day: todayKey),
            moments: momentsQueue(database: database, latest: latest),
            puzzleTarget: puzzleTarget(
                database: database,
                lengths: puzzleLengths,
                key: puzzleLengthKey
            )
        )
        // A game today is history the daily-loop rows may not have caught yet.
        snapshot.hasHistory = snapshot.hasHistory || !games.isEmpty

        // Stamped as soon as the day is finished, because this screen is the
        // only place that knows the day's real moment queue: a game that left
        // one moment is a complete day at `momentsReviewed: 1`, and a row read
        // tomorrow cannot tell that from a day someone walked away from. Left
        // unstamped, the strip greys out a day the screen just called done and
        // the next morning opens with "Your streak restarted."
        if snapshot.progress.isComplete, loop?.completedAt == nil {
            try? database.dailyLoop.update(day: todayKey) { $0.completedAt = now }
            snapshot.completedDays.insert(todayKey)
        }

        if let settings = try? database.settings.current() {
            let rating = Int(settings.userRating.rounded())
            snapshot.userRating = rating
            snapshot.ratingDelta = ratingDelta(
                database: database,
                current: rating,
                todayKey: todayKey
            )
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

    /// What the latest game left to review, in the terms the step is drawn in.
    ///
    /// The count is of the moments the review screen will actually put on
    /// screen — ranked by score, capped at the filmstrip's three — and it
    /// counts them whatever their status. Counting only the unread ones is the
    /// cheaper query and the wrong number: opening the review marks its first
    /// card reviewed, so an unread count read a second later has already
    /// shrunk, and a target that shrinks with the work marks a three-moment
    /// game finished after two.
    private nonisolated static func momentsQueue(
        database: AppDatabase,
        latest: Database.Game?
    ) -> MomentsQueue {
        guard let latest else { return .unknown }
        switch latest.analysis {
        // A state string this build cannot read says nothing about the queue,
        // so the step keeps its nominal target rather than claiming a stall.
        case .none:
            return .unknown
        case .pending, .running:
            return .analysing
        case .failed:
            return .unavailable
        case .complete:
            let moments = (try? database.moments.moments(forGame: latest.id)) ?? []
            let shown = moments
                .sorted { $0.score > $1.score }
                .prefix(ReviewMomentCards.limit)
            return .counted(
                total: shown.count,
                reviewed: shown.filter { $0.momentStatus != .new }.count
            )
        }
    }

    /// How many puzzles today's set is, as chosen on Train.
    ///
    /// Falls back to the nominal ten when nothing is stored or the stored value
    /// is not one of the offered lengths — a target the Length chip cannot show
    /// would be a promise no session can keep.
    private nonisolated static func puzzleTarget(
        database: AppDatabase,
        lengths: [Int],
        key: String
    ) -> Int {
        let stored = Int(database.metrics.value(key, default: 0))
        return lengths.contains(stored) ? stored : DailyProgress.puzzlesTarget
    }

    /// What the daily loop asks for next once the review is behind you, priced.
    ///
    /// For screens that are not Today and have no business loading it: one
    /// indexed read of the day's row plus the stored set length. The moments
    /// step is excluded rather than ranked, because the only caller is standing
    /// on the review — pointing a "what's next" button back at the screen it is
    /// drawn on is the dead end this exists to remove.
    ///
    /// Nil when there is nothing left in the day. The caller says "done for
    /// today" then, rather than inventing work to keep momentum.
    static func nextStepAfterReview(
        database: AppDatabase? = AppDatabase.sharedIfAvailable,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (title: String, destination: TodayDestination)? {
        guard let database else { return nil }
        let todayKey = DailyLoop.dayKey(for: now, calendar: calendar)
        let loop = (try? database.dailyLoop.loop(for: todayKey)) ?? DailyLoop(day: todayKey)
        let progress = DailyProgress(
            loop,
            puzzleTarget: puzzleTarget(
                database: database,
                lengths: TrainHomeModel.lengths,
                key: TrainHomeModel.lengthKey
            )
        )
        guard
            let step = TodayPlanner.unblockedSteps(for: progress).first(where: { $0 != .moments })
        else { return nil }

        return (
            TodayPlanner.actionTitle(for: step, progress: progress, firstRun: false),
            step.destination
        )
    }

    /// The rating's move since the last day it was recorded.
    ///
    /// Measured against the newest sample from an *earlier* day, not the newest
    /// sample outright: the history coalesces to one point per day, so today's
    /// own point is the number already on screen and comparing it with itself
    /// would report a permanent zero. Nil when there is no earlier point —
    /// there is no movement to report on the first day, and inventing a `+0`
    /// would be a measurement the app never took.
    private nonisolated static func ratingDelta(
        database: AppDatabase,
        current: Int,
        todayKey: String
    ) -> Int? {
        let samples = (try? database.metrics.samples(
            key: MetricKey.ladderRating.rawValue,
            window: MetricWindow.allTime.key,
            limit: 60
        )) ?? []
        guard let previous = samples.last(where: { $0.day < todayKey }) else { return nil }
        let delta = current - Int(previous.value.rounded())
        return delta == 0 ? nil : delta
    }

    // MARK: Routing

    /// Maps a plan destination onto app navigation. The plan deliberately does
    /// not know game IDs; this is the only place that does.
    func route(for destination: TodayDestination) -> AppModel.Route {
        switch destination {
        case .play: .play
        // Intercepted by the caller, which has the model to start a coached
        // game with. Sparring is the honest fallback if a future call site
        // forgets: the same game, minus the questions.
        case .playGuided: .play
        case .train: .train
        case .progress: .profile
        case .reviewLatestGame:
            // Falling back to `.play` rather than dead-ending: if there is no
            // game to review, the honest next move is to play one.
            snapshot?.latestGameID.map { AppModel.Route.review(gameID: $0) } ?? .play
        }
    }
}
