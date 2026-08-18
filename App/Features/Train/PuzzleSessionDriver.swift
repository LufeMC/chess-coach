//
//  PuzzleSessionDriver.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// The slice of `TrainingService` the Train screen actually uses.
///
/// `TrainingService` is the real implementation and this protocol adds no
/// behaviour — it exists so the screen's view model can be driven by a fake in
/// tests without a database, a puzzle corpus or an engine. It follows the
/// convention already set by `TrainingStores.swift`: depend on the narrowest
/// description of what is needed, and let the concrete type conform with no
/// adapter beyond renaming.
@MainActor
protocol PuzzleSessionDriver: AnyObject {

    /// Items currently queued. Grows when same-day retries are appended, which
    /// is why the UI reads it after every completion rather than once.
    var queueCount: Int { get }

    /// Zero-based index of the item the service is serving.
    var currentIndex: Int { get }

    /// The item being served, or `nil` when the queue is exhausted.
    var itemOnScreen: SessionItemPlan? { get }

    /// The solve machine for that item, with its setup move already played.
    var solveMachine: PuzzleSolveMachine? { get }

    /// True once every item has been answered.
    var isSessionFinished: Bool { get }

    /// Set when the session could not be built at all.
    var loadFailure: String? { get }

    /// Live puzzle rating, so the summary can report the session's delta.
    var puzzleRating: Double { get }

    func startSession(focus: WeeklyFocus?) async

    /// Offers a user move. The service grades, persists and advances.
    @discardableResult
    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult

    /// Reveals the expected move. The attempt is already lost.
    @discardableResult
    func revealHint() -> String?

    /// Abandons the current item. Counts as a failure.
    func skipCurrent() async
}

extension TrainingService: PuzzleSessionDriver {

    var queueCount: Int { session.items.count }

    var currentIndex: Int { progress.done }

    var itemOnScreen: SessionItemPlan? { currentItem }

    var solveMachine: PuzzleSolveMachine? { machine }

    var isSessionFinished: Bool { phase == .finished }

    var loadFailure: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    var puzzleRating: Double { summary.puzzleRating.rating }

    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult {
        await play(uci: uci)
    }

    func revealHint() -> String? { hint() }

    func skipCurrent() async { await skip() }
}
