//
//  CalibrationDraftStore.swift
//  ChessCoach
//

import Database
import Foundation
import TrainingCore

/// A calibration in progress, in the shape the flow needs to pick it back up.
///
/// Deliberately its own type rather than the `TrainingCore` value types: those
/// describe a *finished* measurement, while this describes a half-finished one,
/// and the two evolve for different reasons. It is stored as a blob owned by
/// this file alone, so adding a phase to calibration never becomes a schema
/// migration.
struct CalibrationDraft: Codable, Equatable, Sendable {

    struct Game: Codable, Equatable, Sendable {
        var opponentRating: Double
        var outcome: TrainingCore.GameOutcome
    }

    struct Puzzle: Codable, Equatable, Sendable {
        var puzzleRating: Double
        var score: Double
    }

    var experience: ChessExperience?
    var opponentRating: Int
    var puzzleRating: Int
    var games: [Game]
    var puzzles: [Puzzle]

    var ladderGames: [CalibrationGame] {
        games.map { CalibrationGame(opponentRating: $0.opponentRating, outcome: $0.outcome) }
    }

    var puzzleResults: [PuzzleResult] {
        puzzles.map { PuzzleResult(puzzleRating: $0.puzzleRating, score: $0.score) }
    }
}

/// Where an unfinished calibration is kept between launches.
protocol CalibrationDraftStoring: Sendable {
    func load() -> CalibrationDraft?
    func save(_ draft: CalibrationDraft)
    func clear()
}

/// The database-backed store.
///
/// Every operation swallows its error on purpose. Calibration must run whether
/// or not the draft can be written: failing to save progress costs the user a
/// repeated diagnostic, but failing *loudly* would block the one flow that has
/// to complete before the app is usable at all.
struct DatabaseCalibrationDraftStore: CalibrationDraftStoring {
    let drafts: CalibrationDraftRepository

    init?(database: AppDatabase? = AppDatabase.sharedIfAvailable) {
        guard let database else { return nil }
        drafts = database.calibrationDrafts
    }

    func load() -> CalibrationDraft? {
        guard
            let row = try? drafts.current(),
            let data = row.payload.data(using: .utf8),
            let draft = try? JSONDecoder().decode(CalibrationDraft.self, from: data)
        else { return nil }
        return draft
    }

    func save(_ draft: CalibrationDraft) {
        guard
            let data = try? JSONEncoder().encode(draft),
            let payload = String(data: data, encoding: .utf8)
        else { return }
        try? drafts.save(payload: payload)
    }

    func clear() {
        try? drafts.clear()
    }
}

/// In-memory store for previews and tests.
final class InMemoryCalibrationDraftStore: CalibrationDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var draft: CalibrationDraft?

    init(draft: CalibrationDraft? = nil) {
        self.draft = draft
    }

    func load() -> CalibrationDraft? { lock.withLock { draft } }
    func save(_ draft: CalibrationDraft) { lock.withLock { self.draft = draft } }
    func clear() { lock.withLock { draft = nil } }
}
