//
//  CardLadder.swift
//  ChessCoach
//

import Database
import Foundation
import TrainingCore

/// Where a card sits on the anti-memorization ladder.
///
/// ## Why this is derived rather than stored
///
/// `TrainingCore.TrainingCard` carries three ladder counters
/// (`consecutiveLongIntervalPasses`, `isGeneralized`,
/// `siblingPassedAtLongInterval`) that the `srsCards` table has no columns for.
/// Adding them would mean a CloudKit-visible schema migration for state that is
/// already implied, exactly and deterministically, by the review log the table
/// *does* keep.
///
/// So they are replayed from `reviewLogs` instead. That has a second benefit
/// worth stating: the counters can never drift out of sync with the history
/// they are supposed to summarise, because they are not a second copy of it.
struct CardLadderState: Sendable, Hashable {

    var consecutiveLongIntervalPasses: Int = 0
    var isGeneralized: Bool = false
    var siblingPassedAtLongInterval: Bool = false

    /// Replays a card's review history.
    ///
    /// The ladder, restated as a walk over the log:
    ///
    /// 1. Count consecutive passing reviews that happened after a **long real
    ///    gap**. Any `.again` or `.hard` resets the count — the card
    ///    demonstrably is not generalized.
    /// 2. When the count reaches
    ///    ``DomainTuning/Cards/longIntervalPassesBeforeSibling``, the *next*
    ///    presentation is a theme sibling. Until that review actually happens
    ///    the card is not yet generalized: `CardPolicy.presentation(for:)` keys
    ///    the sibling swap off `!isGeneralized && count >= threshold`, so
    ///    reporting `isGeneralized` early would skip the sibling entirely.
    /// 3. The review after that one *was* the sibling, so from then on the card
    ///    is generalized and further long-interval passes retire it.
    ///
    /// **Long is measured by elapsed time, not by the scheduled interval.**
    /// `ReviewLog` carries both, and `elapsedDays` is the unambiguous one: what
    /// makes a pass evidence of a learned pattern rather than a remembered
    /// answer is that a real fortnight went by, regardless of what the scheduler
    /// had planned or which build wrote the row.
    static func derive(
        from reviews: [ReviewLog],
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> CardLadderState {
        var state = CardLadderState()
        var awaitingSibling = false
        var siblingServed = false

        for review in reviews.sorted(by: { $0.reviewedAt < $1.reviewedAt }) {
            let rating = TrainingCore.ReviewRating(clamping: review.rating)
            let isLong = review.elapsedDays >= tuning.longIntervalDays

            if siblingServed {
                if rating == .again || rating == .hard { continue }
                if isLong { state.siblingPassedAtLongInterval = true }
                continue
            }

            if awaitingSibling {
                // This review is the one that was served as a sibling, whatever
                // its outcome — the swap happens on presentation, not on
                // success.
                awaitingSibling = false
                siblingServed = true
                if rating != .again, rating != .hard, isLong {
                    state.siblingPassedAtLongInterval = true
                }
                continue
            }

            guard rating != .again, rating != .hard else {
                state.consecutiveLongIntervalPasses = 0
                continue
            }
            if isLong { state.consecutiveLongIntervalPasses += 1 }
            if state.consecutiveLongIntervalPasses >= tuning.longIntervalPassesBeforeSibling {
                awaitingSibling = true
            }
        }

        if siblingServed {
            state.isGeneralized = true
            state.consecutiveLongIntervalPasses = 0
        }
        return state
    }
}

// MARK: - SRSCard ⇄ TrainingCard

/// Translates between the stored card row and the scheduler's card model.
enum TrainingCardBridge {

    /// Everything the row itself cannot answer.
    struct Context: Sendable, Hashable {
        /// FEN the card is shown from; decides whether a mirror is legal.
        var fen: String?
        /// Rating of the underlying puzzle, used to bound the sibling search.
        var puzzleRating: Int
        var primaryTheme: ThemeTag
        var ladder: CardLadderState

        init(fen: String?, puzzleRating: Int, primaryTheme: ThemeTag, ladder: CardLadderState) {
            self.fen = fen
            self.puzzleRating = puzzleRating
            self.primaryTheme = primaryTheme
            self.ladder = ladder
        }
    }

    static func trainingCard(from row: SRSCard, context: Context) -> TrainingCard {
        TrainingCard(
            id: row.id,
            state: cardState(from: row),
            origin: origin(of: row),
            primaryTheme: context.primaryTheme,
            puzzleRating: context.puzzleRating,
            consecutiveLongIntervalPasses: context.ladder.consecutiveLongIntervalPasses,
            isGeneralized: context.ladder.isGeneralized,
            siblingPassedAtLongInterval: context.ladder.siblingPassedAtLongInterval,
            mirrorIsLegal: context.fen.map { BoardTransform.mirrored.isLegal(for: $0) } ?? false,
            createdAt: row.lastReview ?? row.due
        )
    }

    static func cardState(from row: SRSCard) -> CardState {
        CardState(
            stability: row.stability,
            difficulty: row.difficulty,
            state: TrainingCore.SRSState(rawValue: row.state) ?? .new,
            due: row.due,
            lastReview: row.lastReview,
            reps: row.reps,
            lapses: row.lapses
        )
    }

    /// Writes a scheduler result back onto the stored row.
    static func apply(_ state: CardState, to row: SRSCard) -> SRSCard {
        var updated = row
        updated.stability = state.stability
        updated.difficulty = state.difficulty
        updated.state = state.state.rawValue
        updated.due = state.due
        updated.lastReview = state.lastReview
        updated.reps = state.reps
        updated.lapses = state.lapses
        return updated
    }

    /// A card's provenance, inferred from its kind.
    ///
    /// The row records what the card is *backed by*, not why it exists, but the
    /// two are one-to-one in practice: a corpus-backed card only ever gets
    /// created because the user failed or flagged the puzzle (see
    /// `CardPolicy.shouldCreateCard`), and a position-backed card only ever
    /// comes from a mistake in the user's own game.
    static func origin(of row: SRSCard) -> CardOrigin {
        switch row.cardKind {
        case .momentPosition: return .gameMistake
        case .puzzle, .none: return .freshPuzzle
        }
    }

    /// `TrainingCore`'s grade as the storage enum.
    static func storedRating(_ rating: TrainingCore.ReviewRating) -> Database.ReviewRating {
        Database.ReviewRating(clamping: rating.rawValue)
    }

    /// `TrainingCore`'s lifecycle state as the storage enum.
    static func storedState(_ state: TrainingCore.SRSState) -> Database.SRSState {
        Database.SRSState(rawValue: state.rawValue) ?? .new
    }
}
