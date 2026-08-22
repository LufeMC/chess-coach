//
//  PuzzleSessionDriver.swift
//  ChessCoach
//

import Database
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

    /// Glicko's uncertainty about that rating, in rating points.
    ///
    /// Reported alongside it because a delta without it is not a measurement. A
    /// new user carries a deviation of 350, where one session moves the number
    /// by a hundred points for reasons that have nothing to do with how they
    /// played, and a signed `+12` on that footing invites reading noise as
    /// progress.
    var puzzleRatingDeviation: Double { get }

    func startSession(focus: WeeklyFocus?) async

    /// Builds the calculation set instead of the daily queue.
    ///
    /// Its own call rather than a parameter on ``startSession(focus:)`` so a
    /// screen cannot open one and get the other: the two queues are drawn from
    /// different bands and only one of them touches the review deck.
    func startCalculationSet() async

    /// Starts the latency clock for the item on screen.
    ///
    /// The service cannot know this for itself. It grades, persists and
    /// advances in one call, so the moment it starts serving item *n+1* is the
    /// moment the user submitted item *n* — with the verdict banner for *n*
    /// still up, and, for the first item of a set, with a concept lesson and
    /// its exercise still to come. Every latency therefore carried the previous
    /// banner's reading time, and the first review of any set that opened with
    /// a lesson carried the whole lesson. `AutoGrader` reads those numbers
    /// absolutely (`.easy` under ten seconds) and relatively (`.hard` past
    /// twice the band median), so the grades were biased slow and the median
    /// they are measured against was polluted by the same inflation.
    ///
    /// Called when the position actually becomes solvable — after the setup
    /// move has animated in — so what is measured is time spent thinking.
    func markItemShown()

    /// Offers a user move. The service grades, persists and advances.
    @discardableResult
    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult

    /// Reveals the expected move. The attempt is already lost.
    @discardableResult
    func revealHint() -> String?

    /// Abandons the current item. Counts as a failure.
    func skipCurrent() async

    /// Withdraws the same-day retry for a card whose answer the engine went on
    /// to rate as no better than the move the user played.
    func creditEquivalentAnswer(cardID: SRSCard.ID)
}

extension PuzzleSessionDriver {
    /// Nothing to withdraw. Default so a driver with no queue of its own — the
    /// test doubles — keeps compiling and keeps behaving exactly as before.
    func creditEquivalentAnswer(cardID: SRSCard.ID) {}
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

    var puzzleRatingDeviation: Double { summary.puzzleRating.deviation }

    func markItemShown() { startLatencyClock() }

    func offer(uci: String) async -> PuzzleSolveMachine.MoveResult {
        await play(uci: uci)
    }

    func revealHint() -> String? { hint() }

    func skipCurrent() async { await skip() }
}
