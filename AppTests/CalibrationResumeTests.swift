import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// A store that cannot write.
///
/// Application Support going read-only is rare and total: the write throws, the
/// completion marker is never recorded, and the calibration gate reopens on the
/// next launch. The draft is the only thing standing between that and a second
/// full hour of games and puzzles.
private struct FailingOutcomeStore: CalibrationOutcomeStore {
    struct WriteFailed: Error {}

    func persist(_ estimate: CalibrationEstimate, experience: ChessExperience?, at date: Date) throws {
        throw WriteFailed()
    }
}

/// Calibration gates the entire app, runs once, and is the first thing a new
/// install does — so losing it to a force-quit or an interrupting phone call is
/// the worst first impression the app can make. These pin that it survives.
@Suite("Calibration resume")
@MainActor
struct CalibrationResumeTests {

    private func model(
        drafts: any CalibrationDraftStoring,
        store: (any CalibrationOutcomeStore)? = nil
    ) -> CalibrationModel {
        CalibrationModel(store: store, drafts: drafts, clock: { Date(timeIntervalSince1970: 1_760_000_000) })
    }

    @Test("A fresh install starts at the intro with nothing restored")
    func emptyDraftStartsClean() {
        let subject = model(drafts: InMemoryCalibrationDraftStore())

        #expect(subject.games.isEmpty)
        #expect(subject.puzzles.isEmpty)
        #expect(subject.experience == nil)
    }

    @Test("Games answered before an interruption are still there")
    func gamesSurvive() {
        let drafts = InMemoryCalibrationDraftStore()
        let first = model(drafts: drafts)
        first.select(.playsRegularly)
        first.beginMeasurement()
        first.record(gameOutcome: .win)
        first.record(gameOutcome: .loss)

        // The process dies here. A new model is built from the same store.
        let resumed = model(drafts: drafts)

        #expect(resumed.games.count == 2)
        #expect(resumed.experience == .playsRegularly)
        #expect(resumed.opponentRating == first.opponentRating)
    }

    @Test("A resumed calibration lands in the phase it left off in")
    func resumesIntoTheRightPhase() {
        let drafts = InMemoryCalibrationDraftStore()
        let first = model(drafts: drafts)
        first.select(.knowsTheMoves)
        first.beginMeasurement()
        for _ in 0..<DomainTuning.default.calibration.gameCount {
            first.record(gameOutcome: .draw)
        }
        first.record(puzzleRating: 900, solved: true)

        let resumed = model(drafts: drafts)

        // Past the games, into the puzzles — not back at game one.
        #expect(resumed.puzzles.count == 1)
        #expect(resumed.games.count == DomainTuning.default.calibration.gameCount)
        if case .puzzles = resumed.stage {} else {
            Issue.record("expected to resume into the puzzle phase, got \(resumed.stage)")
        }
    }

    @Test("A crash between the last answer and the result still produces one")
    func completesAnUnfinishedMeasurement() {
        // The nastiest interruption: every answer is in, but the process died
        // before the estimate was written. Resuming must finish the
        // measurement rather than show a reveal nothing ever stored.
        let tuning = DomainTuning.default
        let drafts = InMemoryCalibrationDraftStore(
            draft: CalibrationDraft(
                experience: .competitive,
                opponentRating: 1_400,
                puzzleRating: 1_350,
                games: Array(
                    repeating: .init(opponentRating: 1_400, outcome: .win),
                    count: tuning.calibration.gameCount
                ),
                puzzles: Array(
                    repeating: .init(puzzleRating: 1_350, score: 1),
                    count: tuning.calibration.puzzleCount
                )
            )
        )

        let resumed = model(drafts: drafts)

        #expect(resumed.estimate != nil, "a complete draft must produce an estimate on resume")
        #expect(drafts.load() == nil, "a finished measurement must not stay resumable")
    }

    /// The counter alone says nothing happened to the game that was going,
    /// which is the one reading that is false.
    @Test("A resumed calibration knows it was resumed")
    func resumeIsFlagged() {
        let drafts = InMemoryCalibrationDraftStore()
        let first = model(drafts: drafts)
        first.select(.playsRegularly)
        first.beginMeasurement()
        first.record(gameOutcome: .win)
        #expect(!first.didResume, "a calibration that was never interrupted has nothing to say")

        let resumed = model(drafts: drafts)
        #expect(resumed.didResume)

        resumed.acknowledgeResume()
        #expect(!resumed.didResume, "the notice is said once, not before every game")
    }

    /// A failed write used to clear the draft anyway, so the user finished
    /// calibration, used the app, and met all five games again on the next
    /// launch with nothing having warned them.
    @Test("A result that could not be written keeps the draft")
    func failedWriteKeepsTheDraft() {
        let tuning = DomainTuning.default
        let drafts = InMemoryCalibrationDraftStore()
        let subject = model(drafts: drafts, store: FailingOutcomeStore())
        subject.select(.playsRegularly)
        subject.beginMeasurement()
        for _ in 0..<tuning.calibration.gameCount { subject.record(gameOutcome: .win) }
        for _ in 0..<tuning.calibration.puzzleCount { subject.record(puzzleRating: 1_200, solved: true) }

        #expect(subject.estimate != nil, "the reveal still happens; only the write failed")
        #expect(!subject.resultWasSaved)
        #expect(drafts.load() != nil, "the answers are the only copy left of the measurement")
    }

    @Test("Finishing clears the draft")
    func finishClearsTheDraft() {
        let tuning = DomainTuning.default
        let drafts = InMemoryCalibrationDraftStore()
        let subject = model(drafts: drafts)
        subject.select(.new)
        subject.beginMeasurement()
        for _ in 0..<tuning.calibration.gameCount { subject.record(gameOutcome: .loss) }
        for _ in 0..<tuning.calibration.puzzleCount { subject.record(puzzleRating: 700, solved: false) }

        #expect(subject.estimate != nil)
        #expect(drafts.load() == nil)
    }
}
