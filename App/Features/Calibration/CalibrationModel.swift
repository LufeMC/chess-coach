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
        try settings.update { stored in
            stored.userRating = estimate.rating
            // `puzzleEstimate` has already been shifted onto the *playing*
            // scale by the combiner. The stored puzzle rating lives on the
            // puzzle scale, so the offset is taken back off — storing the
            // shifted number would move every future puzzle a hundred points
            // out of band.
            stored.puzzleRating = estimate.puzzleEstimate - tuning.calibration.puzzleRatingOffset
            stored.puzzleRD = estimate.puzzleSigma
            stored.currentRung = estimate.startingRung
        }

        try metrics.set(MetricKey.puzzleRating.rawValue, value: estimate.rating, sampleCount: 1, at: date)
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
    private let tuning: DomainTuning
    private let clock: @Sendable () -> Date

    init(
        store: (any CalibrationOutcomeStore)? = nil,
        tuning: DomainTuning = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.tuning = tuning
        self.clock = clock
        self.progress = CalibrationProgress(
            required: [tuning.calibration.gameCount, tuning.calibration.puzzleCount]
        )
    }

    // MARK: Self-assessment

    func select(_ experience: ChessExperience) {
        self.experience = experience
        opponentRating = CalibrationSeed.opponentRating(for: experience)
        puzzleRating = CalibrationSeed.puzzleRating(for: experience, tuning: tuning.calibration)
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
        if progress.phase == .puzzles { stage = .puzzles }
    }

    func record(puzzleRating rating: Int, solved: Bool) {
        guard stage == .puzzles else { return }
        puzzles.append(PuzzleResult(puzzleRating: Double(rating), solved: solved))
        puzzleRating = CalibrationSeed.nextPuzzleRating(current: puzzleRating, solved: solved)
        progress.recordItem()
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
    }

    /// The estimate, once measured.
    var estimate: CalibrationEstimate? {
        if case let .reveal(estimate) = stage { return estimate }
        return nil
    }
}
