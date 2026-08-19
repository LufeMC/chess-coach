//
//  TrainHomeModel.swift
//  ChessCoach
//

import Database
import Foundation
import Observation
import SwiftUI
import TrainingCore

// MARK: - Focus vocabulary

/// Short names for the habits, for the places a sentence will not fit.
///
/// `Habit.microGoalTitle` is an imperative — "Blunder-check every move" — which
/// is right on a coaching chip and wrong on a picker, where the label has to
/// name the *subject* so a row of them can be scanned. Kept here rather than
/// pushed into `TrainingCore` because it is a UI decision about a chip's width,
/// and the package has no chips.
enum FocusVocabulary {

    static func chipTitle(_ habit: Habit) -> String {
        switch habit {
        case .whatChanged: "What changed"
        case .scanThreats: "Threats"
        case .candidatesFirst: "Candidates"
        case .calcToQuiet: "Calculation"
        case .blunderCheck: "Blunder-check"
        case .kingSafety: "King safety"
        case .endgameTechnique: "Endgames"
        case .convertCleanly: "Converting"
        case .clockDiscipline: "The clock"
        }
    }
}

// MARK: - Due row

/// One row of the "Due today" list.
struct DueCardPresentation: Sendable, Hashable, Identifiable {

    var id: UUID
    /// The concept, humanised — `fork`, `back-rank mate`.
    var concept: String

    /// Probability the user still recalls this card, 0...1.
    ///
    /// The ring on the row's left draws this and nothing else. It is deliberately
    /// *not* the interval: "due in 6 days, stability 14.2" is the scheduler's
    /// vocabulary, and exposing it turns a training app into a settings panel
    /// people optimise instead of study. A ring that empties as memory fades
    /// says the same thing in the only unit the user has any intuition for.
    var recall: Double

    /// Share of attempts on this theme that were solved unaided, or `nil` while
    /// the theme has never been attempted above the curriculum's rating floor —
    /// which is rendered as *nothing*, never as 0%.
    var mastery: Double?

    /// `fork · 60% mastered`.
    var subtitle: String {
        guard let mastery else { return concept }
        return "\(concept) · \(Int((mastery * 100).rounded()))% mastered"
    }
}

/// How many rows the "Due today" list shows.
///
/// The list is a preview of the session, not an inventory of the deck. Past
/// about half a dozen rows it stops being readable and starts being a backlog,
/// and a visible backlog is the thing that makes people close a review app.
private let dueRowLimit = 6

// MARK: - Model

/// Everything the Train tab needs that is not a puzzle.
///
/// The screen used to build its own `TrainingService` inline and read metrics
/// straight out of the database in view-body accessors. That was survivable
/// while Train had one button; it stops being survivable the moment the screen
/// has to know the week's focus, the session length, the due list and whether
/// the user has earned a rung, because every one of those is a value that
/// changes in response to something the user did and therefore has to be
/// observable rather than recomputed on every layout pass.
@MainActor
@Observable
final class TrainHomeModel {

    /// The lengths the Length chip offers.
    ///
    /// Three, not a stepper. The session length is a promise about how long
    /// today takes; a continuous control invites tuning it, and a user who spends
    /// thirty seconds choosing 11 has already lost more time than the extra
    /// puzzle costs.
    static let lengths = [5, 10, 15]

    /// The chosen length. Stored beside the other training counters rather than
    /// on `AppSettings`, because a settings column is a synced schema migration
    /// and this is a preference about one screen.
    static let lengthKey = "session.targetSize"

    /// The promotion the user has earned but not yet taken.
    struct Promotion: Sendable, Hashable {
        var rung: Int
        var title: String
    }

    // MARK: Observable state

    private(set) var rung = 1
    private(set) var focus: WeeklyFocus?
    private(set) var due: [DueCardPresentation] = []
    private(set) var dueCount = 0
    private(set) var promotion: Promotion?
    private(set) var isMeasuring = false

    private var storedLength = DomainTuning.default.cards.sessionTargetSize

    /// Puzzles in the next session.
    ///
    /// Writes through on change rather than in a `didSet`, so restoring the
    /// stored value on appear cannot write it straight back.
    var length: Int {
        get { storedLength }
        set {
            guard newValue != storedLength else { return }
            storedLength = newValue
            try? database?.metrics.set(Self.lengthKey, value: Double(newValue), sampleCount: 1, at: Date())
        }
    }

    // MARK: Dependencies

    private let database: AppDatabase?
    private let metricsService: MetricsService?

    /// The initialiser does no I/O on purpose.
    ///
    /// SwiftUI re-creates the view struct on every parent body pass, and a
    /// `@State` default expression is evaluated each time even though only the
    /// first result is kept — so anything read here would be read on every
    /// render and thrown away. The stored preferences are picked up in
    /// ``load()`` instead, which runs once, from the screen's `task`.
    ///
    /// - Parameter database: Defaults to the shared database, and to `nil` under
    ///   the test runner. The unit suites are hosted inside this app, so a model
    ///   built during a test would open the real `user.sqlite` underneath them —
    ///   `AppDatabase.shared` is a lazy `static let`, so merely reading it is the
    ///   thing that opens the file.
    init(database: AppDatabase? = AppModel.isRunningTests ? nil : AppDatabase.sharedIfAvailable) {
        self.database = database
        self.metricsService = database.map {
            MetricsService(
                games: $0.games,
                moments: $0.moments,
                metrics: $0.metrics,
                settings: $0.settings
            )
        }
    }

    /// True when there is a corpus to serve puzzles from.
    var canStartSession: Bool { database?.puzzleQueries != nil }

    /// The habits the picker offers.
    ///
    /// Restricted to the ones the current rung actually measures. Letting the
    /// user pick a habit the ladder is not tracking means a week of work that
    /// moves nothing on Today and nothing on Profile, which is a worse outcome
    /// than a shorter menu.
    var habitChoices: [Habit] {
        let habits = Curriculum.rung(rung)?.habits ?? []
        return habits.sorted { $0.rawValue < $1.rawValue }
    }

    /// The focus a leak-driven session should use.
    ///
    /// Returns the week's focus when the leak names the habit already being
    /// worked on, so tapping the top leak does not quietly reset the streak and
    /// drill multiplier the week has accumulated. Otherwise it builds a
    /// one-session focus: the habit is what `SessionAssembler` weights the mix
    /// by, and the session is deliberately not written back as the week's focus
    /// — practising a second leak once is not a decision to change what the week
    /// is about.
    func focus(for habit: Habit) -> WeeklyFocus {
        if let focus, focus.habit == habit { return focus }
        return WeeklyFocus(habit: habit, reason: .initialSelection)
    }

    var focusChipTitle: String {
        focus.map { FocusVocabulary.chipTitle($0.habit) } ?? "Any"
    }

    // MARK: Loading

    func load() async {
        guard !AppModel.isRunningTests, let database else { return }

        restorePreferences(from: database)

        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.readDue(database: database, now: Date())
        }.value

        withAnimation(Motion.standard) {
            due = snapshot.rows
            dueCount = snapshot.total
        }

        await measure()
    }

    /// Three indexed single-row reads, taken before anything expensive.
    ///
    /// The focus in particular is read here rather than waited for, because the
    /// session cannot wait: a user who opens Train and taps Start before the
    /// recompute lands still has to get the week's 60/40 mix, and the selector's
    /// last answer is already on disk. The recompute only ever refines this.
    private func restorePreferences(from database: AppDatabase) {
        let stored = Int(database.metrics.value(Self.lengthKey, default: 0))
        if Self.lengths.contains(stored) { storedLength = stored }
        if let settings = try? database.settings.current() { rung = settings.currentRung }
        focus = MetricsService.storedFocus(metrics: database.metrics, settings: database.settings)
    }

    /// Recomputes the curriculum so the focus chip and the promotion row are
    /// describing the same instant as Today and Profile.
    private func measure() async {
        guard let metricsService, !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }

        await metricsService.refresh()
        apply(metricsService.state)
        // Falls back to the stored focus so a session started before the first
        // recompute lands still gets the week's mix rather than a general one.
        if focus == nil { focus = metricsService.sessionFocus }
    }

    private func apply(_ state: CurriculumState?) {
        guard let state else { return }
        withAnimation(Motion.standard) {
            rung = state.rung
            focus = state.focus
            promotion = state.decision.canAdvance
                ? state.decision.nextRung.map {
                    Promotion(rung: $0, title: Curriculum.rung($0)?.title ?? "")
                }
                : nil
        }
    }

    // MARK: Intents

    /// Takes the promotion the user has earned.
    ///
    /// Deliberately a tap rather than a side effect of the recompute that
    /// noticed it. `MetricsService.advanceRung()` is separate from `refresh()`
    /// for exactly this reason: moving up a rung is the one thing in the
    /// curriculum the user is told about rather than shown afterwards, and a
    /// rung that changed while they were looking at the drill grid is a rung
    /// they will not believe they earned.
    func acceptPromotion() async {
        guard let metricsService, promotion != nil else { return }
        guard await metricsService.advanceRung() != nil else { return }
        apply(metricsService.state)
    }

    /// Changes the week's habit.
    ///
    /// Surfaced here, on the chip that sits above `Start`, because this is the
    /// only place in the app where changing the habit changes what the very next
    /// tap gives you: the session assembled after this call is 60% themed on the
    /// habit chosen. On a settings screen the same control would be a preference
    /// with no visible consequence.
    func chooseFocus(_ habit: Habit) async {
        guard let metricsService else { return }
        await metricsService.setFocus(habit: habit)
        apply(metricsService.state)
        if focus?.habit != habit { focus = metricsService.sessionFocus }
    }

    /// Builds the session service for the length the user chose.
    ///
    /// The composition lives here rather than in the view because the tuning is
    /// no longer a constant: the Length chip has to reach `SessionBuilder`, and
    /// it can only do that through the service's `DomainTuning`.
    func makeTrainingService() -> TrainingService? {
        guard let database, let corpus = database.puzzleQueries else { return nil }
        var tuning = DomainTuning.default
        tuning.cards.sessionTargetSize = length
        return TrainingService(
            srs: database.srs,
            corpus: corpus,
            metrics: database.metrics,
            dailyLoop: database.dailyLoop,
            settings: database.settings,
            momentPositions: GameMomentPositionSource(games: database.games, moments: database.moments),
            tuning: tuning
        )
    }

    /// Mastery of one drill family, for its tile.
    func mastery(for kind: EndgameDrillKind) -> DrillMastery {
        let tuning = DomainTuning.default.curriculum
        let required = kind.isSetScored ? tuning.kpkSetSize : tuning.drillCleanStreakRequired
        let streak = database.map { Int($0.metrics.value(kind.streakMetricKey.rawValue)) } ?? 0
        return DrillMastery(cleanStreak: streak, required: required)
    }

    // MARK: Off-main read

    private struct DueSnapshot: Sendable {
        var rows: [DueCardPresentation]
        var total: Int
    }

    private nonisolated static func readDue(database: AppDatabase, now: Date) -> DueSnapshot {
        let total = (try? database.srs.dueCount(at: now)) ?? 0
        let rows = (try? database.srs.due(at: now, limit: dueRowLimit)) ?? []
        let scheduler = FSRS6()
        let floor = DomainTuning.default.curriculum.themeRatingFloor

        let presentations = rows.map { card -> DueCardPresentation in
            let puzzle = card.puzzleID.flatMap { id -> Puzzle? in
                guard let corpus = database.puzzleQueries else { return nil }
                return try? corpus.puzzle(id: id)
            }
            let theme = puzzle.map { TrainingVocabulary.primaryTheme(of: $0) }

            return DueCardPresentation(
                id: card.id,
                // "position" for a card mined from the user's own game: it has
                // no corpus theme, and inventing one would put a word in the
                // list the review itself never uses.
                concept: theme.flatMap(PuzzleConcept.noun(for:)) ?? "position",
                recall: scheduler.retrievability(card: TrainingCardBridge.cardState(from: card), now: now),
                mastery: theme.flatMap { mastery(of: $0, floor: floor, metrics: database.metrics) }
            )
        }
        return DueSnapshot(rows: presentations, total: total)
    }

    /// Solve rate for a theme, or `nil` when there is nothing to divide by.
    private nonisolated static func mastery(
        of theme: ThemeTag,
        floor: Int,
        metrics: any MetricStore
    ) -> Double? {
        let attempts = metrics.value(TrainingMetricKeys.themeAttempts(theme, ratingFloor: floor))
        guard attempts > 0 else { return nil }
        return metrics.value(TrainingMetricKeys.themeSolves(theme, ratingFloor: floor)) / attempts
    }
}
