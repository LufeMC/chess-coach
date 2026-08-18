//
//  SchedulerProtocol.swift
//  TrainingCore
//

import Foundation

/// The spaced-repetition scheduler, behind a seam.
///
/// FSRS is a moving target — FSRS-4.5, 5 and 6 all changed the equations, and
/// a future build may fit per-user weights or switch algorithm entirely. Every
/// call site in the app talks to this protocol so that swap is a one-line
/// change in the composition root rather than a search-and-replace.
///
/// Implementations must be pure: same inputs, same outputs, no clock reads
/// (the caller passes `now`), no storage.
public protocol SchedulerProtocol: Sendable {

    /// Applies a review to a card and returns the updated state.
    ///
    /// - Parameters:
    ///   - card: The card's state *before* the review.
    ///   - rating: The grade, normally produced by ``AutoGrader``.
    ///   - now: The moment of the review. Injected rather than read from the
    ///     clock so the whole scheduler is deterministic under test.
    /// - Returns: A new state with updated stability, difficulty, lifecycle
    ///   state, counters, and the next due date.
    func nextReview(card: CardState, rating: ReviewRating, now: Date) -> CardState

    /// Probability the user would recall the card right now, in `0...1`.
    ///
    /// Used to order a session (lowest first — the cards closest to being
    /// forgotten are worth the most) and to draw the "memory strength" UI.
    func retrievability(card: CardState, now: Date) -> Double
}
