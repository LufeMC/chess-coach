//
//  CardState.swift
//  TrainingCore
//

import Foundation

/// The four-point grading scale FSRS is defined against.
///
/// The user never sees these. There are no rating buttons in this app — the
/// grade is derived from what the user did (see ``AutoGrader``). Self-grading
/// is a known drop-off point in SRS apps and, for chess, the user is a poor
/// judge of whether they *recognised* a pattern or *calculated* it.
public enum ReviewRating: Int, Sendable, Hashable, Codable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    /// Clamps an arbitrary integer into the scale, for values that crossed a
    /// storage or sync boundary.
    public init(clamping raw: Int) {
        self = ReviewRating(rawValue: min(max(raw, 1), 4)) ?? .good
    }

    /// `.again` is the only failing grade.
    public var isLapse: Bool { self == .again }
}

/// Where a card sits in its learning lifecycle.
public enum SRSState: String, Sendable, Hashable, Codable, CaseIterable {
    /// Never reviewed.
    case new
    /// First exposure did not stick; being cycled inside the session.
    case learning
    /// Graduated. Scheduled by the forgetting curve.
    case review
    /// A graduated card that was failed and is being re-learned.
    case relearning
}

/// Everything the scheduler needs to know about one card.
///
/// A pure value type with no identity: the card's identity, position, theme and
/// provenance live in ``TrainingCard``. Keeping the scheduler's input this
/// small is what lets FSRS be tested from literals and swapped wholesale.
public struct CardState: Sendable, Hashable, Codable {

    /// Memory stability, in days: the interval at which recall probability
    /// falls to ``DomainTuning/SRS/desiredRetention``'s reference point of 90%.
    public var stability: Double

    /// Intrinsic difficulty on FSRS's 1...10 scale. Higher means the card's
    /// stability grows more slowly on every successful recall.
    public var difficulty: Double

    public var state: SRSState

    /// When the card should next be shown.
    public var due: Date

    /// When it was last shown, or `nil` for a new card.
    public var lastReview: Date?

    /// Total reviews, successful or not.
    public var reps: Int

    /// Times a graduated card has been failed. Drives both the FSRS post-lapse
    /// path and the coaching UI's "this one keeps catching you".
    public var lapses: Int

    public init(
        stability: Double = 0,
        difficulty: Double = 0,
        state: SRSState = .new,
        due: Date = .distantPast,
        lastReview: Date? = nil,
        reps: Int = 0,
        lapses: Int = 0
    ) {
        self.stability = stability
        self.difficulty = difficulty
        self.state = state
        self.due = due
        self.lastReview = lastReview
        self.reps = reps
        self.lapses = lapses
    }

    /// A card that has never been reviewed, due immediately.
    public static func new(due: Date) -> CardState {
        CardState(state: .new, due: due)
    }

    /// Days between the last review and `date`, never negative.
    ///
    /// Fractional rather than whole days: a same-day repeat and a next-morning
    /// review are very different events, and rounding them together would let
    /// a session's own retries take the long-term stability path.
    public func elapsedDays(at date: Date) -> Double {
        guard let lastReview else { return 0 }
        return max(0, date.timeIntervalSince(lastReview) / 86_400)
    }

    /// Days between the last review and the scheduled due date — the interval
    /// the card actually earned. Zero for a card that has never graduated.
    public var scheduledIntervalDays: Double {
        guard let lastReview else { return 0 }
        return max(0, due.timeIntervalSince(lastReview) / 86_400)
    }
}
