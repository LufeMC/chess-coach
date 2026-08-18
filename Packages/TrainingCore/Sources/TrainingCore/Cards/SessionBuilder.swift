//
//  SessionBuilder.swift
//  TrainingCore
//

import Foundation

/// One item in a daily session.
public enum SessionItem: Sendable, Hashable {
    /// A due card, with the presentation it has earned.
    case review(card: TrainingCard, presentation: CardPresentation)
    /// A slot to be filled with a fresh puzzle from the corpus. The associated
    /// value is the slot's index, so the caller can fetch `n` puzzles in one
    /// query rather than one at a time.
    case fresh(slot: Int)
    /// A same-day retry of a card failed earlier in this session.
    case relearn(card: TrainingCard, presentation: CardPresentation)
}

/// A built session.
public struct SessionPlan: Sendable, Hashable {

    public var items: [SessionItem]

    /// Cards excluded because the policy retired them. The caller should mark
    /// these done rather than re-queue them tomorrow.
    public var retired: [TrainingCard.ID]

    public init(items: [SessionItem] = [], retired: [TrainingCard.ID] = []) {
        self.items = items
        self.retired = retired
    }

    public var reviewCount: Int {
        items.reduce(into: 0) { count, item in
            if case .review = item { count += 1 }
        }
    }

    public var freshCount: Int {
        items.reduce(into: 0) { count, item in
            if case .fresh = item { count += 1 }
        }
    }

    public var relearnCount: Int {
        items.reduce(into: 0) { count, item in
            if case .relearn = item { count += 1 }
        }
    }
}

/// Builds the daily session queue.
public enum SessionBuilder {

    /// Assembles a session: due cards first, backfilled with fresh puzzles.
    ///
    /// - Parameters:
    ///   - dueCards: Every card whose due date has passed. Order is ignored;
    ///     this function imposes its own.
    ///   - freshCount: How many fresh puzzles are available to backfill with.
    ///   - targetSize: Total items wanted. Defaults to
    ///     ``DomainTuning/Cards/sessionTargetSize``.
    ///
    /// **Reviews are ordered by lowest retrievability first** — the cards
    /// closest to being forgotten go first. Two reasons, and the second is the
    /// one that matters: a review is worth the most right at the edge of
    /// forgetting (that is the spacing effect the whole algorithm is built on),
    /// and if the session is abandoned halfway the user has still done the
    /// highest-value half. Ordering by due date instead would put the most
    /// overdue card first, which correlates but is not the same thing — a card
    /// with high stability can be weeks overdue and still perfectly recallable.
    ///
    /// At most ``DomainTuning/Cards/maxReviewsPerSession`` reviews are served,
    /// even when more are due. A session that grows without bound on a bad
    /// week is how users quit; the overflow simply stays due tomorrow.
    public static func sessionQueue(
        dueCards: [TrainingCard],
        freshCount: Int,
        targetSize: Int = DomainTuning.default.cards.sessionTargetSize,
        now: Date = Date(),
        scheduler: any SchedulerProtocol = FSRS6(),
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> SessionPlan {
        var retired: [TrainingCard.ID] = []
        var candidates: [(card: TrainingCard, presentation: CardPresentation, retrievability: Double)] = []

        for card in dueCards {
            let presentation = CardPolicy.presentation(for: card, tuning: tuning)
            if case .retire = presentation {
                retired.append(card.id)
                continue
            }
            candidates.append((card, presentation, scheduler.retrievability(card: card.state, now: now)))
        }

        candidates.sort { lhs, rhs in
            if lhs.retrievability != rhs.retrievability { return lhs.retrievability < rhs.retrievability }
            // Deterministic tie-breaks: more overdue first, then by id. Without
            // these, two cards with identical retrievability would order
            // arbitrarily and the session would not be reproducible in a test.
            if lhs.card.state.due != rhs.card.state.due { return lhs.card.state.due < rhs.card.state.due }
            return lhs.card.id.uuidString < rhs.card.id.uuidString
        }

        let reviewSlots = min(tuning.maxReviewsPerSession, max(0, targetSize))
        let reviews = candidates.prefix(reviewSlots)

        var items: [SessionItem] = reviews.map { .review(card: $0.card, presentation: $0.presentation) }

        let backfill = min(max(0, targetSize - items.count), max(0, freshCount))
        for slot in 0..<backfill {
            items.append(.fresh(slot: slot))
        }

        return SessionPlan(items: items, retired: retired)
    }

    /// Appends a same-day retry for every card failed during the session.
    ///
    /// The retry goes at the *end*, not immediately after the failure. Retrying
    /// straight away tests nothing — the answer is still on screen a second
    /// ago. Pushing it behind the rest of the session inserts the only
    /// interference this app can cheaply create, so the retry is at least a
    /// weak retrieval rather than an echo. It also gives FSRS's short-term
    /// stability path something meaningful to score.
    ///
    /// Cards not present as reviews in the plan are ignored: a failed *fresh*
    /// puzzle becomes a new card through ``CardPolicy/admitNewCards(candidates:createdToday:tuning:)``
    /// and is not retried in the same session.
    public static func appendRelearnRetries(
        to plan: SessionPlan,
        failedCardIDs: [TrainingCard.ID]
    ) -> SessionPlan {
        guard !failedCardIDs.isEmpty else { return plan }
        let failed = Set(failedCardIDs)

        var updated = plan
        for item in plan.items {
            guard case let .review(card, presentation) = item, failed.contains(card.id) else { continue }
            updated.items.append(.relearn(card: card, presentation: presentation))
        }
        return updated
    }
}
