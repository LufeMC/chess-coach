//
//  TrainingCard.swift
//  TrainingCore
//

import Foundation

/// A puzzle theme, as a loosely-typed string.
///
/// The puzzle corpus owns the real theme vocabulary (65 of them at last count)
/// and this package deliberately does not depend on it. A `String`-backed
/// wrapper gives call sites spell-checked constants for the themes the
/// curriculum actually names, while any other theme still round-trips intact.
public struct ThemeTag: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }

    // The five themes rung 2 gates on.
    public static let fork: ThemeTag = "fork"
    public static let pin: ThemeTag = "pin"
    public static let skewer: ThemeTag = "skewer"
    public static let discoveredAttack: ThemeTag = "discoveredAttack"
    public static let backRankMate: ThemeTag = "backRankMate"
}

/// Why a card exists.
///
/// Provenance is not bookkeeping here — it decides whether the card should have
/// been created at all, and which candidate wins when the daily cap bites.
public enum CardOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    /// Served from the puzzle corpus as part of a daily session.
    case freshPuzzle
    /// The user explicitly asked to keep this position.
    case flagged
    /// Mined from a mistake in one of the user's own games.
    case gameMistake
}

/// A card in the user's deck: the scheduler's ``CardState`` plus everything the
/// card *policy* needs (provenance, theme, and the anti-memorization ladder).
public struct TrainingCard: Sendable, Hashable, Identifiable, Codable {

    public var id: UUID

    /// FSRS scheduling state.
    public var state: CardState

    public var origin: CardOrigin

    /// The theme the card is primarily teaching. Used to find a sibling
    /// position once the original has been generalized.
    public var primaryTheme: ThemeTag

    /// Rating of the underlying puzzle, used to bound the sibling search.
    public var puzzleRating: Int

    /// Consecutive `.good`/`.easy` reviews taken at an interval at or above
    /// ``DomainTuning/Cards/longIntervalDays``. Reset by any failure.
    public var consecutiveLongIntervalPasses: Int

    /// The original pattern has been judged generalized and the card's position
    /// has been swapped for a theme sibling.
    public var isGeneralized: Bool

    /// The sibling position has itself passed at a long interval.
    public var siblingPassedAtLongInterval: Bool

    /// Whether a left-right file mirror keeps the position legal.
    ///
    /// Mirroring swaps the a-file with the h-file, which moves the king off e1
    /// and swaps the rooks — so it is only sound when neither side still has
    /// castling rights, or when the rights survive the swap. The caller (which
    /// has the actual board) decides; this package only records the answer.
    public var mirrorIsLegal: Bool

    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        state: CardState = CardState(),
        origin: CardOrigin,
        primaryTheme: ThemeTag,
        puzzleRating: Int,
        consecutiveLongIntervalPasses: Int = 0,
        isGeneralized: Bool = false,
        siblingPassedAtLongInterval: Bool = false,
        mirrorIsLegal: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.state = state
        self.origin = origin
        self.primaryTheme = primaryTheme
        self.puzzleRating = puzzleRating
        self.consecutiveLongIntervalPasses = consecutiveLongIntervalPasses
        self.isGeneralized = isGeneralized
        self.siblingPassedAtLongInterval = siblingPassedAtLongInterval
        self.mirrorIsLegal = mirrorIsLegal
        self.createdAt = createdAt
    }

    /// Advances the anti-memorization counter after a review.
    ///
    /// A pass only counts toward generalization if it happened at a *long*
    /// interval, because a pass at a three-day interval is not evidence of
    /// anything except short-term memory. Any failure resets the streak: the
    /// card demonstrably is not generalized.
    public mutating func recordLongIntervalOutcome(
        rating: ReviewRating,
        intervalDays: Double,
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) {
        guard rating != .again, rating != .hard else {
            consecutiveLongIntervalPasses = 0
            return
        }
        if intervalDays >= tuning.longIntervalDays {
            consecutiveLongIntervalPasses += 1
        }
    }
}

/// One attempt at a card or a fresh puzzle, as the app observes it.
///
/// This is the bridge between the UI and both ``AutoGrader`` and
/// ``CardPolicy``: everything either of them needs about "what just happened"
/// is in here, and nothing else.
public struct PuzzleAttempt: Sendable, Hashable {

    /// The user played the complete solution line.
    public var correct: Bool
    public var usedHint: Bool
    public var retried: Bool
    public var latencyMs: Double
    public var bandMedianLatencyMs: Double

    public init(
        correct: Bool,
        usedHint: Bool = false,
        retried: Bool = false,
        latencyMs: Double = 0,
        bandMedianLatencyMs: Double = 0
    ) {
        self.correct = correct
        self.usedHint = usedHint
        self.retried = retried
        self.latencyMs = latencyMs
        self.bandMedianLatencyMs = bandMedianLatencyMs
    }

    /// The FSRS grade this attempt earns.
    public func rating(tuning: DomainTuning.Grading = DomainTuning.default.grading) -> ReviewRating {
        AutoGrader.grade(
            correct: correct,
            usedHint: usedHint,
            retried: retried,
            latencyMs: latencyMs,
            bandMedianLatencyMs: bandMedianLatencyMs,
            tuning: tuning
        )
    }
}
