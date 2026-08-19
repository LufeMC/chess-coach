//
//  CalibrationModel.swift
//  ChessCoach
//

import Database
import Foundation
import Observation
import TrainingCore

/// Where the calibration result is written.
///
/// Narrow on purpose: the flow needs to store four numbers and a flag, and
/// nothing in `App/Services` vends a calibration writer yet. `Database`'s own
/// repositories satisfy this through the stores in `TrainingStores.swift` with
/// no adapter.
protocol CalibrationOutcomeStore: Sendable {
    func persist(_ estimate: CalibrationEstimate, experience: ChessExperience?, at date: Date) throws
}

/// Writes the result to settings and metrics.
///
/// There is no `calibrationCompletedAt` column on `AppSettings`, and adding one
/// would mean a CloudKit-visible schema migration to store a single timestamp.
/// The metrics table is already a synced `(key, window) -> value` store — the
/// same argument `TrainingMetricKeys` makes for the training counters — so the
/// completion marker lives there.
struct StoredCalibrationOutcome: CalibrationOutcomeStore {

    /// Metric key marking that calibration has run.
    static let completedKey = "calibration.completedAt"
    /// The self-assessment, kept so a later re-test can tell "said beginner,
    /// measured 1600" from "said club, measured 1600" — the first is a user who
    /// undersold themselves, the second is a bad measurement.
    static let experienceKey = "calibration.selfAssessment"

    var settings: any AppSettingsStore
    var metrics: any MetricStore
    var tuning: DomainTuning = .default

    func persist(_ estimate: CalibrationEstimate, experience: ChessExperience?, at date: Date) throws {
        // `puzzleEstimate` has already been shifted onto the *playing* scale by
        // the combiner. The stored puzzle rating lives on the puzzle scale, so
        // the offset comes back off — storing the shifted number would move
        // every future puzzle a hundred points out of band.
        let puzzleRating = estimate.puzzleEstimate - tuning.calibration.puzzleRatingOffset

        try settings.update { stored in
            stored.userRating = estimate.rating
            stored.puzzleRating = puzzleRating
            stored.puzzleRD = estimate.puzzleSigma
            stored.currentRung = estimate.startingRung
        }

        // Each rating under its own key. These are two different scales — the
        // playing rating and the puzzle rating sit roughly an offset apart —
        // so filing the playing number under `puzzle.rating` does not merely
        // mislabel it, it reports a puzzle rating that is out of band by that
        // offset, and the rating history now plots both keys.
        try metrics.set(MetricKey.ladderRating.rawValue, value: estimate.rating, sampleCount: 1, at: date)
        try metrics.set(MetricKey.puzzleRating.rawValue, value: Double(puzzleRating), sampleCount: 1, at: date)
        try metrics.set(
            MetricKey.puzzleRatingDeviation.rawValue,
            value: estimate.puzzleSigma,
            sampleCount: 1,
            at: date
        )
        try metrics.set(Self.completedKey, value: date.timeIntervalSince1970, sampleCount: 1, at: date)
        if let experience {
            try metrics.set(
                Self.experienceKey,
                value: Double(experience.bars),
                sampleCount: 1,
                at: date
            )
        }
    }
}

/// Drives first-run calibration: one question, five games, twenty puzzles, one
/// reveal.
@MainActor
@Observable
final class CalibrationModel {

    enum Stage: Equatable {
        /// The framing line and the self-assessment question.
        case intro
        case games
        case puzzles
        case reveal(CalibrationEstimate)

        /// Which of the four steps this stage is, for the header every
        /// calibration screen carries.
        var step: CalibrationStep {
            switch self {
            case .intro: .question
            case .games: .games
            case .puzzles: .puzzles
            case .reveal: .result
            }
        }
    }

    /// Said once, up front.
    ///
    /// Duolingo's *"I'll go easy on you until we find your level."* does one
    /// specific job: it tells the user that the difficulty they are about to
    /// meet is not a judgement, so a loss in game one is information rather than
    /// a verdict. A diagnostic that announces itself as a diagnostic stops
    /// feeling like a chore — and it only works said **once**, at the start.
    /// Repeating it between phases would turn reassurance into nagging.
    static let framingLine = "Five games and twenty puzzles. I'll start easy and adjust as we go — this is a measurement, not a test."

    private(set) var stage: Stage = .intro
    private(set) var experience: ChessExperience?
    private(set) var progress = CalibrationProgress()

    /// The opponent the next calibration game is played against.
    private(set) var opponentRating: Int = CalibrationSeed.defaultOpponentRating
    /// The rating band the next calibration puzzle is drawn from.
    private(set) var puzzleRating: Int = CalibrationSeed.puzzleRating(for: nil)

    private(set) var games: [CalibrationGame] = []
    private(set) var puzzles: [PuzzleResult] = []

    private let store: (any CalibrationOutcomeStore)?
    private let drafts: (any CalibrationDraftStoring)?
    private let tuning: DomainTuning
    private let clock: @Sendable () -> Date

    /// - Parameter drafts: where an interrupted calibration is kept. Defaults
    ///   to **nil**, not to the database-backed store, and deliberately: a
    ///   dependency that silently reaches for shared on-disk state is one every
    ///   caller then holds without knowing it. When it did default to the real
    ///   store, parallel tests each constructed a model that resumed from
    ///   whatever draft another test had just written, and the calibration
    ///   suite went intermittently red with a failure that pointed at the
    ///   combiner rather than at the sharing. The app passes the real store
    ///   explicitly in `CalibrationScreen.makeFlow()`, which is also the only
    ///   place that knows whether a database was opened at all.
    init(
        store: (any CalibrationOutcomeStore)? = nil,
        drafts: (any CalibrationDraftStoring)? = nil,
        tuning: DomainTuning = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.drafts = drafts
        self.tuning = tuning
        self.clock = clock
        self.progress = CalibrationProgress(
            required: [tuning.calibration.gameCount, tuning.calibration.puzzleCount]
        )
        restore()
    }

    /// Picks up a calibration that was interrupted.
    ///
    /// The stage is derived from how many items were actually recorded rather
    /// than stored alongside them: a stage that disagreed with the answers would
    /// resume the user into the wrong phase, and the counts are the truth about
    /// how far they got. An empty draft leaves everything at its initial value.
    private func restore() {
        guard let draft = drafts?.load(), !draft.games.isEmpty || !draft.puzzles.isEmpty
                || draft.experience != nil
        else { return }

        experience = draft.experience
        opponentRating = draft.opponentRating
        puzzleRating = draft.puzzleRating
        games = draft.ladderGames
        puzzles = draft.puzzleResults

        for _ in 0..<(draft.games.count + draft.puzzles.count) { progress.recordItem() }

        if progress.isComplete {
            // Every answer is in but the result was never written — the crash
            // landed between the last puzzle and `finish()`. Finish it now
            // rather than showing a reveal the store has never seen.
            stage = .games
            finish()
        } else if progress.phase == .puzzles {
            stage = .puzzles
        } else if draft.experience != nil {
            stage = .games
        }
    }

    /// Writes the measurement so far.
    private func saveDraft() {
        drafts?.save(
            CalibrationDraft(
                experience: experience,
                opponentRating: opponentRating,
                puzzleRating: puzzleRating,
                games: games.map { .init(opponentRating: $0.opponentRating, outcome: $0.outcome) },
                puzzles: puzzles.map { .init(puzzleRating: $0.puzzleRating, score: $0.score) }
            )
        )
    }

    // MARK: Self-assessment

    func select(_ experience: ChessExperience) {
        self.experience = experience
        opponentRating = CalibrationSeed.opponentRating(for: experience)
        puzzleRating = CalibrationSeed.puzzleRating(for: experience, tuning: tuning.calibration)
        saveDraft()
    }

    /// Leaves the intro for the first game.
    func beginMeasurement() {
        guard stage == .intro else { return }
        stage = .games
    }

    // MARK: Recording

    func record(gameOutcome outcome: GameOutcome) {
        guard stage == .games else { return }
        games.append(CalibrationGame(opponentRating: Double(opponentRating), outcome: outcome))
        opponentRating = CalibrationSeed.nextOpponentRating(current: opponentRating, outcome: outcome)
        progress.recordItem()
        saveDraft()
        if progress.phase == .puzzles { stage = .puzzles }
    }

    func record(puzzleRating rating: Int, solved: Bool) {
        guard stage == .puzzles else { return }
        puzzles.append(PuzzleResult(puzzleRating: Double(rating), solved: solved))
        puzzleRating = CalibrationSeed.nextPuzzleRating(current: puzzleRating, solved: solved)
        progress.recordItem()
        saveDraft()
        if progress.isComplete { finish() }
    }

    // MARK: Result

    /// Runs the combiner and persists the outcome.
    ///
    /// Persisting here rather than on the reveal's CTA is deliberate: the
    /// measurement is finished the moment the last puzzle is answered, and a
    /// user who force-quits on the reveal screen should not be asked to sit
    /// through calibration a second time.
    func finish() {
        guard estimate == nil else { return }
        let measured = CalibrationCombiner.estimate(games: games, puzzles: puzzles, tuning: tuning)
        stage = .reveal(measured)
        try? store?.persist(measured, experience: experience, at: clock())
        // The measurement is over; keeping the draft would resume a calibration
        // that has already produced a rating.
        drafts?.clear()
    }

    /// The estimate, once measured.
    var estimate: CalibrationEstimate? {
        if case let .reveal(estimate) = stage { return estimate }
        return nil
    }
}
