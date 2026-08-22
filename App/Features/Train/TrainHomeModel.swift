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

// MARK: - Calculation copy

/// The calculation card's words.
///
/// Pulled out of the view because one of them is load-bearing rather than
/// decorative: when the corpus holds nothing above the user, the card has to say
/// that in so many words. The alternative a UI reaches for by default — hide the
/// card, or leave the button up and let the session come back empty — is the app
/// serving ordinary puzzles under the calculation label, or promising a set it
/// cannot produce. A function returning a string can be tested; a `private var`
/// in a `View` cannot.
enum CalculationCopy {

    /// Names the step and its cost.
    ///
    /// Both numbers come from what the corpus can actually serve, never from the
    /// configured set size — the button is read before it is tapped, and a set
    /// that arrives two puzzles long after saying three has spent the one thing
    /// the price exists to buy.
    static func title(puzzles: Int, minutes: Int) -> String {
        let noun = puzzles == 1 ? "1 puzzle" : "\(puzzles) puzzles"
        return "Calculation · \(noun) · ~\(minutes) min"
    }

    /// What the set is for, and the two ways it differs from the daily one.
    ///
    /// The difficulty is stated as a distance rather than as an adjective:
    /// "harder" is a feeling and "200–300 points above you" is a fact the user
    /// can check against their own rating. The absence of a clock is stated
    /// outright because the daily set has trained the opposite expectation — it
    /// grades anything under ten seconds as recognition — so silence here would
    /// be read as the same rules applying.
    static func offer(offsetLabel: String, minutesPerPuzzle: Int) -> String {
        "Rated \(offsetLabel) points above you, picked for the longest lines in that band. "
            + "These are meant to be worked out rather than recognised — there is no clock, and "
            + "\(minutesPerPuzzle) minutes on one position is the point."
    }

    /// Why there is nothing to offer.
    ///
    /// Names the band in absolute ratings. "No puzzles available" would leave
    /// the user guessing at a rule nobody has told them, and the rule *is* the
    /// explanation: this set only ever draws from above. The last sentence is
    /// there because the card sits directly under the one the user came for, and
    /// an unexplained failure next to it reads as training being broken.
    static func emptyBand(_ band: ClosedRange<Int>) -> String {
        "The corpus holds no puzzles rated \(band.lowerBound)–\(band.upperBound), which is the only band "
            + "this set draws from. Your daily set is unaffected."
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
    /// How many calculation puzzles the corpus can actually serve, capped at the
    /// set size.
    ///
    /// Read before the card is drawn rather than discovered inside the session,
    /// because the card names a count and a cost and both have to be true when
    /// they are read. Zero is a real answer — a user whose rating has passed the
    /// top of the corpus has no band above them — and the card says so instead
    /// of quietly offering a set it would have to fill from the ordinary band.
    private(set) var calculationSupply = 0
    private(set) var promotion: Promotion?
    /// What the sets have covered so far, in catalogue order.
    private(set) var covered: [CoveredConcept] = []
    /// The concept the next set will open with, resolved the same way the
    /// session resolves it.
    ///
    /// Read here so the card can price what it is selling. `10 puzzles` was
    /// never the whole set — a lesson and its exercise come first — and a user
    /// who budgeted four minutes met a lesson, an exercise, ten puzzles and
    /// sometimes a twenty-move drill.
    private(set) var nextConcept: ConceptScheduler.Selection?
    private(set) var isMeasuring = false
    private var puzzleRating = 1000.0

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

    /// Roughly how long the set takes, end to end.
    ///
    /// Twenty-four seconds a puzzle is the figure Today already prices its own
    /// CTA with — ten puzzles, four minutes — and the concept slot is added on
    /// top rather than folded into it, because reading a lesson and playing its
    /// exercise is exactly the part the old promise left out.
    var estimatedMinutes: Int {
        let puzzles = Double(length) * 0.4
        let concept: Double
        switch nextConcept {
        case .none: concept = 0
        case let .some(selection): concept = selection.teachFirst ? 2 : 1
        }
        return max(1, Int((puzzles + concept).rounded()))
    }

    // MARK: Calculation set

    /// The absolute rating band the calculation set draws from.
    ///
    /// Exposed so the card can name it when it comes back empty. "No puzzles
    /// available" would leave the user guessing at a rule they have never been
    /// told; `1750–1850` is the whole explanation in two numbers.
    var calculationBand: ClosedRange<Int> {
        TrainingVocabulary.calculationBand(userPuzzleRating: Int(puzzleRating.rounded()))
    }

    /// How far above the user that band sits, as the card phrases it.
    var calculationOffsetLabel: String {
        let tuning = DomainTuning.default.calculation
        return "\(tuning.bandOffset)–\(tuning.bandOffset + tuning.bandWidth)"
    }

    /// What the calculation set costs, priced off what can actually be served.
    ///
    /// Multiplied by ``calculationSupply`` rather than by the configured set
    /// size, so a band that can only fill two slots is priced at two puzzles'
    /// worth of minutes rather than three. The button says both numbers, and
    /// they have to agree with each other and with the queue that follows.
    var calculationMinutes: Int {
        let perPuzzle = DomainTuning.default.calculation.minutesPerPuzzle
        return max(1, Int((Double(calculationSupply) * perPuzzle).rounded()))
    }

    /// The per-puzzle budget, which is the number the copy quotes.
    ///
    /// A budget and not a limit: nothing in the session counts it down. It is
    /// quoted because "take your time" is advice nobody can act on and "spend
    /// four minutes on one position" is an instruction they can.
    var calculationMinutesPerPuzzle: Int {
        max(1, Int(DomainTuning.default.calculation.minutesPerPuzzle.rounded()))
    }

    /// Whether the calculation set can be offered at all.
    var canStartCalculation: Bool { canStartSession && calculationSupply > 0 }

    // MARK: Loading

    func load() async {
        await prepare()
        await measure()
    }

    /// Everything the screen needs before it can open a session.
    ///
    /// Split from the curriculum recompute because a leak tapped on Profile
    /// routes straight into a session, and `measure()` replays up to twenty
    /// games. Waiting for it left the user looking at the Train home for
    /// seconds after tapping a button that promised a session — the stored
    /// focus read here is enough to build one, and the recompute only refines
    /// it.
    func prepare() async {
        guard !AppModel.isRunningTests, let database else { return }

        restorePreferences(from: database)
        await loadCovered(from: database)

        // Both reads share one hop off the main actor. They are indexed
        // single-statement queries either way, and two detached tasks to run two
        // of them is two continuations for no gain.
        let rating = Int(puzzleRating.rounded())
        let snapshot = await Task.detached(priority: .userInitiated) {
            (
                due: Self.readDue(database: database, now: Date()),
                calculation: Self.calculationSupply(database: database, userPuzzleRating: rating)
            )
        }.value

        withAnimation(Motion.standard) {
            due = snapshot.due.rows
            dueCount = snapshot.due.total
            calculationSupply = snapshot.calculation
        }
    }

    /// One concept and how far it has got.
    struct CoveredConcept: Identifiable, Sendable, Hashable {
        var concept: TrainingConcept
        var isTaught: Bool
        var timesSeen: Int
        var timesCorrect: Int
        /// The clean streak, for a concept whose exercise is a drill.
        ///
        /// A drill runs on its own screen after the set, so nothing ever calls
        /// `recordAttempt` for it and `timesCorrect` stays at zero forever —
        /// the row read `0 of 3` at a user who had passed every run. The streak
        /// is what the curriculum gates on and the only honest number here.
        var drillMastery: DrillMastery?

        var id: String { concept.id }

        /// `"3 of 4"`, `"1 of 2 clean sets"`, or nil before the first attempt.
        var record: String? {
            if let drillMastery { return drillMastery.label }
            guard timesSeen > 0 else { return nil }
            return "\(timesCorrect) of \(timesSeen)"
        }
    }

    /// The whole catalogue, not just what the rating has unlocked.
    ///
    /// The list is a record of ground covered, and "12 more to come" is a truer
    /// thing to show than a list that silently grows as the rating climbs —
    /// which would make the user's progress look like it was going backwards
    /// every time a new tier opened.
    private func loadCovered(from database: AppDatabase) async {
        let rating = Int(puzzleRating.rounded())
        let loaded = await Task.detached(priority: .utility) { () -> ([CoveredConcept], ConceptScheduler.Selection?) in
            let all = (try? database.concepts.all()) ?? []
            let stored = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let required = DomainTuning.default.curriculum.drillCleanStreakRequired
            let rows = TrainingConcept.catalogue.map { concept -> CoveredConcept in
                let progress = stored[concept.id]
                var drillMastery: DrillMastery?
                if case let .drill(kind) = concept.exercise {
                    drillMastery = DrillMastery(
                        cleanStreak: Int(database.metrics.value(kind.streakMetricKey.rawValue)),
                        required: required,
                        countsSets: kind.isSetScored
                    )
                }
                return CoveredConcept(
                    concept: concept,
                    isTaught: progress?.introducedAt != nil,
                    timesSeen: progress?.timesSeen ?? 0,
                    timesCorrect: progress?.timesCorrect ?? 0,
                    drillMastery: drillMastery
                )
            }

            // The same question the session asks, asked a screen earlier so the
            // card can say what the set contains. Answered from the same rows
            // and the same scheduler, so the two cannot drift apart and promise
            // an opening that turns out to be an endgame.
            let states = Dictionary(
                all.map {
                    (
                        $0.id,
                        ConceptScheduler.State(
                            id: $0.id,
                            isIntroduced: $0.introducedAt != nil,
                            timesSeen: $0.timesSeen,
                            lastSeenAt: $0.lastSeenAt
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            let lastFamily = all
                .compactMap { row -> (Date, TrainingConcept.Family)? in
                    guard let seenAt = row.lastSeenAt,
                        let concept = TrainingConcept.concept(id: row.id)
                    else { return nil }
                    return (seenAt, concept.family)
                }
                .max { $0.0 < $1.0 }?
                .1
            return (rows, ConceptScheduler.next(rating: rating, states: states, lastFamily: lastFamily))
        }.value

        withAnimation(Motion.standard) {
            covered = loaded.0
            nextConcept = loaded.1
        }
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
        if let settings = try? database.settings.current() {
            rung = settings.currentRung
            puzzleRating = settings.puzzleRating
        }
        focus = MetricsService.storedFocus(metrics: database.metrics, settings: database.settings)
    }

    /// Recomputes the curriculum so the focus chip and the promotion row are
    /// describing the same instant as Today and Profile.
    func measure() async {
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

    /// Builds the service for the calculation set.
    ///
    /// The shipping tuning, untouched. The Length chip is a promise about how
    /// long *today's set* takes and has nothing to say about this one — the
    /// calculation set's size is `DomainTuning.calculation.setSize`, and letting
    /// a length of 15 reach it would serve fifteen puzzles rated 200 points
    /// above the user under a button that said three.
    func makeCalculationService() -> TrainingService? {
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

    /// Mastery of one drill family, for its tile.
    ///
    /// The requirement is the curriculum's, for every family. KPK used to be
    /// counted against `kpkSetSize` — the number of *positions* in one set —
    /// while the gate it feeds counts clean *sets*, so a user who had cleared
    /// half the gate would have been shown `1 of 6` and told to play six clean
    /// sets, or thirty-six positions, for a gate that asks for two.
    func mastery(for kind: EndgameDrillKind) -> DrillMastery {
        let required = DomainTuning.default.curriculum.drillCleanStreakRequired
        let streak = database.map { Int($0.metrics.value(kind.streakMetricKey.rawValue)) } ?? 0
        return DrillMastery(cleanStreak: streak, required: required, countsSets: kind.isSetScored)
    }

    // MARK: Off-main read

    private struct DueSnapshot: Sendable {
        var rows: [DueCardPresentation]
        var total: Int
    }

    /// How many calculation puzzles the corpus holds above the user, capped at
    /// the set size.
    ///
    /// A `COUNT` over the raised band rather than a fetch of the puzzles
    /// themselves: it rides the same `puzzle_rating` index the serving query
    /// does, and the card needs a number, not positions. It deliberately ignores
    /// the recently-served exclusion window — reproducing that here would mean
    /// building the same several-hundred-id `IN` list twice per appearance of
    /// this screen, and the residual case it would catch (a band whose every
    /// puzzle was served this fortnight) is answered honestly by the session's
    /// own empty-band message rather than silently.
    private nonisolated static func calculationSupply(database: AppDatabase, userPuzzleRating: Int) -> Int {
        guard let corpus = database.puzzleQueries else { return 0 }
        let band = TrainingVocabulary.calculationBand(userPuzzleRating: userPuzzleRating)
        let available = (try? corpus.count(ratingRange: band)) ?? 0
        return min(available, DomainTuning.default.calculation.setSize)
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
                // A card mined from the user's own game has no corpus theme,
                // and inventing one would put a word in the list the review
                // itself never uses. Naming where it came from is both true and
                // the most interesting thing about it — and it stops the row
                // sharing the word "position" with the concept slot's header.
                concept: theme.flatMap(PuzzleConcept.noun(for:)) ?? "from your own game",
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
