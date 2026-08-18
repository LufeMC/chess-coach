import Foundation
import Testing

@testable import TrainingCore

@Suite("Card creation policy")
struct CardCreationTests {

    @Test("A solved fresh puzzle never becomes a card")
    func solvedFreshPuzzleIsNotACard() {
        // The single most important rule in the policy: turning every solved
        // puzzle into a card spends review time re-proving a skill the user
        // already has, and the queue grows without bound.
        #expect(!CardPolicy.shouldCreateCard(origin: .freshPuzzle, solved: true))
    }

    @Test("A card is earned by evidence of a gap")
    func cardsAreEarned() {
        #expect(CardPolicy.shouldCreateCard(origin: .freshPuzzle, solved: false))
        #expect(CardPolicy.shouldCreateCard(origin: .flagged, solved: true))
        #expect(CardPolicy.shouldCreateCard(origin: .flagged, solved: false))
        #expect(CardPolicy.shouldCreateCard(origin: .gameMistake, solved: true))
        #expect(CardPolicy.shouldCreateCard(origin: .gameMistake, solved: false))
    }

    @Test("The serving band is symmetric and inclusive at its edges")
    func servingBand() {
        #expect(CardPolicy.isWithinServingBand(userRating: 1200, puzzleRating: 1350))
        #expect(CardPolicy.isWithinServingBand(userRating: 1200, puzzleRating: 1050))
        #expect(!CardPolicy.isWithinServingBand(userRating: 1200, puzzleRating: 1351))
        #expect(!CardPolicy.isWithinServingBand(userRating: 1200, puzzleRating: 1049))
    }

    @Test("The daily cap admits three cards and defers the rest")
    func dailyCap() {
        let candidates = (0..<6).map {
            CardCandidate(origin: .freshPuzzle, solved: false, severity: Double(6 - $0))
        }
        let admission = CardPolicy.admitNewCards(candidates: candidates)
        #expect(admission.admitted.count == 3)
        #expect(admission.deferred.count == 3)
        #expect(admission.rejected.isEmpty)
        // Highest severity first.
        #expect(admission.admitted.map(\.severity) == [6, 5, 4])
    }

    @Test("The cap survives multiple sessions in the same day")
    func capAccountsForCardsAlreadyCreated() {
        let candidates = (0..<4).map { _ in CardCandidate(origin: .gameMistake) }
        let admission = CardPolicy.admitNewCards(candidates: candidates, createdToday: 2)
        #expect(admission.admitted.count == 1)
        #expect(admission.deferred.count == 3)

        let exhausted = CardPolicy.admitNewCards(candidates: candidates, createdToday: 3)
        #expect(exhausted.admitted.isEmpty)
        #expect(exhausted.deferred.count == 4)

        // Over-budget is not negative budget.
        let overshoot = CardPolicy.admitNewCards(candidates: candidates, createdToday: 10)
        #expect(overshoot.admitted.isEmpty)
    }

    @Test("Solved fresh puzzles are rejected outright, not merely deferred")
    func rejectedIsDistinctFromDeferred() {
        // A deferred candidate should be retried tomorrow; a rejected one never
        // should.
        let candidates = [
            CardCandidate(origin: .freshPuzzle, solved: true),
            CardCandidate(origin: .freshPuzzle, solved: true),
            CardCandidate(origin: .gameMistake)
        ]
        let admission = CardPolicy.admitNewCards(candidates: candidates)
        #expect(admission.rejected.count == 2)
        #expect(admission.admitted.count == 1)
        #expect(admission.deferred.isEmpty)
    }

    @Test("An explicitly flagged position outranks everything when the cap bites")
    func flaggedWinsThePriorityContest() {
        // Silently dropping something the user asked for is the failure mode
        // that damages trust in the deck.
        let candidates = [
            CardCandidate(origin: .freshPuzzle, solved: false, severity: 99),
            CardCandidate(origin: .gameMistake, severity: 99),
            CardCandidate(origin: .gameMistake, severity: 98),
            CardCandidate(origin: .flagged, severity: 0)
        ]
        let admission = CardPolicy.admitNewCards(candidates: candidates)
        #expect(admission.admitted.map(\.origin) == [.flagged, .gameMistake, .gameMistake])
        #expect(admission.deferred.map(\.origin) == [.freshPuzzle])
    }

    @Test("Admission is fully deterministic for identical candidates")
    func deterministicOrdering() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let candidates = (0..<5).map { _ in
            CardCandidate(origin: .gameMistake, severity: 1, createdAt: stamp)
        }
        let first = CardPolicy.admitNewCards(candidates: candidates)
        let second = CardPolicy.admitNewCards(candidates: candidates)
        #expect(first.admitted.map(\.id) == second.admitted.map(\.id))
    }
}

@Suite("Anti-memorization presentation")
struct CardPresentationTests {

    func card(
        reps: Int = 0,
        passes: Int = 0,
        generalized: Bool = false,
        siblingPassed: Bool = false,
        mirrorLegal: Bool = false
    ) -> TrainingCard {
        TrainingCard(
            state: CardState(stability: 10, difficulty: 5, state: reps == 0 ? .new : .review, reps: reps),
            origin: .freshPuzzle,
            primaryTheme: .fork,
            puzzleRating: 1200,
            consecutiveLongIntervalPasses: passes,
            isGeneralized: generalized,
            siblingPassedAtLongInterval: siblingPassed,
            mirrorIsLegal: mirrorLegal
        )
    }

    @Test("The first review shows the position as it was failed")
    func firstReviewIsAsIs() {
        #expect(CardPolicy.presentation(for: card(reps: 0)) == .asIs)
    }

    @Test("From the second review the position is transformed")
    func secondReviewIsTransformed() {
        // The failure mode: after a few reviews the user stops seeing the board
        // and starts recognising the picture, answers instantly, and every
        // signal in the system reads that as mastery.
        #expect(CardPolicy.presentation(for: card(reps: 1)) == .colorFlipped)
        #expect(CardPolicy.presentation(for: card(reps: 4)) == .colorFlipped)
    }

    @Test("Mirroring is preferred over a bare colour flip when it is legal")
    func mirrorPreferredWhenLegal() {
        // A colour flip alone leaves the verbal handle ("the knight goes to
        // f6") intact; the file mirror breaks it too.
        #expect(CardPolicy.presentation(for: card(reps: 1, mirrorLegal: true)) == .mirrored)
        #expect(CardPolicy.presentation(for: card(reps: 1, mirrorLegal: false)) == .colorFlipped)
    }

    @Test("Two long-interval passes promote the card to a theme sibling")
    func siblingPromotion() {
        let presentation = CardPolicy.presentation(for: card(reps: 5, passes: 2))
        #expect(presentation == .themeSibling(theme: .fork, ratingRange: 1100...1300))

        // One pass is not enough: a single long-interval success is still
        // ambiguous between knowing the pattern and remembering the answer.
        #expect(CardPolicy.presentation(for: card(reps: 5, passes: 1)) == .colorFlipped)
    }

    @Test("The sibling swap outranks the geometric transforms")
    func siblingOutranksMirroring() {
        let presentation = CardPolicy.presentation(for: card(reps: 5, passes: 3, mirrorLegal: true))
        guard case .themeSibling = presentation else {
            Issue.record("expected a theme sibling, got \(presentation)")
            return
        }
    }

    @Test("A generalized card keeps being perturbed until its sibling also lands")
    func generalizedKeepsWorking() {
        #expect(CardPolicy.presentation(for: card(reps: 6, passes: 3, generalized: true)) == .colorFlipped)
        #expect(CardPolicy.presentation(for: card(reps: 6, passes: 3, generalized: true, mirrorLegal: true)) == .mirrored)
    }

    @Test("Once the sibling passes at a long interval the card retires")
    func retirement() {
        #expect(CardPolicy.presentation(for: card(reps: 8, generalized: true, siblingPassed: true)) == .retire)
    }

    @Test("A sibling pass without generalization does not retire the card")
    func retirementRequiresBothFlags() {
        #expect(CardPolicy.presentation(for: card(reps: 8, siblingPassed: true)) != .retire)
    }

    @Test("The full ladder progresses in order")
    func fullProgression() {
        var subject = card(reps: 0, mirrorLegal: true)
        #expect(CardPolicy.presentation(for: subject) == .asIs)

        subject.state.reps = 1
        #expect(CardPolicy.presentation(for: subject) == .mirrored)

        subject.recordLongIntervalOutcome(rating: .good, intervalDays: 30)
        #expect(subject.consecutiveLongIntervalPasses == 1)
        #expect(CardPolicy.presentation(for: subject) == .mirrored)

        subject.recordLongIntervalOutcome(rating: .easy, intervalDays: 40)
        #expect(subject.consecutiveLongIntervalPasses == 2)
        guard case .themeSibling = CardPolicy.presentation(for: subject) else {
            Issue.record("expected promotion to a theme sibling")
            return
        }

        subject.isGeneralized = true
        #expect(CardPolicy.presentation(for: subject) == .mirrored)

        subject.siblingPassedAtLongInterval = true
        #expect(CardPolicy.presentation(for: subject) == .retire)
    }

    @Test("Only long-interval passes count, and any failure resets the streak")
    func streakAccounting() {
        var subject = card(reps: 3, passes: 1)

        // A pass at a short interval proves only short-term memory.
        subject.recordLongIntervalOutcome(rating: .good, intervalDays: 3)
        #expect(subject.consecutiveLongIntervalPasses == 1)

        subject.recordLongIntervalOutcome(rating: .good, intervalDays: 21)
        #expect(subject.consecutiveLongIntervalPasses == 2)

        subject.recordLongIntervalOutcome(rating: .again, intervalDays: 60)
        #expect(subject.consecutiveLongIntervalPasses == 0)

        // A struggle is not a pass either.
        subject.recordLongIntervalOutcome(rating: .good, intervalDays: 30)
        subject.recordLongIntervalOutcome(rating: .hard, intervalDays: 30)
        #expect(subject.consecutiveLongIntervalPasses == 0)
    }
}

@Suite("Daily session queue")
struct SessionBuilderTests {

    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let day: TimeInterval = 86_400

    func dueCard(stability: Double, daysSinceReview: Double, id: UUID = UUID()) -> TrainingCard {
        let lastReview = now.addingTimeInterval(-daysSinceReview * day)
        return TrainingCard(
            id: id,
            state: CardState(
                stability: stability,
                difficulty: 5,
                state: .review,
                due: now.addingTimeInterval(-day),
                lastReview: lastReview,
                reps: 3
            ),
            origin: .freshPuzzle,
            primaryTheme: .fork,
            puzzleRating: 1200
        )
    }

    @Test("Reviews are ordered by lowest retrievability first")
    func ordersByRetrievability() {
        // The card closest to being forgotten is worth the most, and if the
        // session is abandoned halfway the user has done the valuable half.
        let weakest = dueCard(stability: 1, daysSinceReview: 10)
        let middle = dueCard(stability: 10, daysSinceReview: 10)
        let strongest = dueCard(stability: 100, daysSinceReview: 10)

        let plan = SessionBuilder.sessionQueue(
            dueCards: [strongest, middle, weakest],
            freshCount: 0,
            targetSize: 10,
            now: now
        )

        let ids = plan.items.compactMap { item -> UUID? in
            if case let .review(card, _) = item { return card.id }
            return nil
        }
        #expect(ids == [weakest.id, middle.id, strongest.id])

        let scheduler = FSRS6()
        #expect(scheduler.retrievability(card: weakest.state, now: now)
            < scheduler.retrievability(card: strongest.state, now: now))
    }

    @Test("Lowest retrievability is not the same as most overdue")
    func retrievabilityBeatsDueDate() {
        // A high-stability card can be weeks overdue and still perfectly
        // recallable; ordering by due date would put it first.
        var veryOverdueButStable = dueCard(stability: 400, daysSinceReview: 60)
        veryOverdueButStable.state.due = now.addingTimeInterval(-40 * day)

        var barelyDueButWeak = dueCard(stability: 1.5, daysSinceReview: 4)
        barelyDueButWeak.state.due = now.addingTimeInterval(-60)

        let plan = SessionBuilder.sessionQueue(
            dueCards: [veryOverdueButStable, barelyDueButWeak],
            freshCount: 0,
            targetSize: 10,
            now: now
        )
        guard case let .review(first, _) = plan.items[0] else {
            Issue.record("expected a review first")
            return
        }
        #expect(first.id == barelyDueButWeak.id)
    }

    @Test("At most seven reviews are served, however many are due")
    func reviewCap() {
        // A session that grows without bound on a bad week is how users quit;
        // the overflow simply stays due tomorrow.
        let cards = (1...20).map { dueCard(stability: Double($0), daysSinceReview: 10) }
        let plan = SessionBuilder.sessionQueue(dueCards: cards, freshCount: 20, targetSize: 10, now: now)
        #expect(plan.reviewCount == 7)
        #expect(plan.freshCount == 3)
        #expect(plan.items.count == 10)
    }

    @Test("Fresh puzzles backfill to the target size")
    func backfill() {
        let cards = (1...3).map { dueCard(stability: Double($0), daysSinceReview: 10) }
        let plan = SessionBuilder.sessionQueue(dueCards: cards, freshCount: 20, targetSize: 10, now: now)
        #expect(plan.reviewCount == 3)
        #expect(plan.freshCount == 7)

        // Fresh slots are numbered so the caller can fetch them in one query.
        let slots = plan.items.compactMap { item -> Int? in
            if case let .fresh(slot) = item { return slot }
            return nil
        }
        #expect(slots == Array(0..<7))
    }

    @Test("Backfill is limited by the fresh puzzles actually available")
    func limitedBackfill() {
        let plan = SessionBuilder.sessionQueue(dueCards: [], freshCount: 4, targetSize: 10, now: now)
        #expect(plan.items.count == 4)
        #expect(plan.freshCount == 4)
    }

    @Test("An empty deck and no fresh puzzles produce an empty session, not a crash")
    func emptySession() {
        let plan = SessionBuilder.sessionQueue(dueCards: [], freshCount: 0, targetSize: 10, now: now)
        #expect(plan.items.isEmpty)
    }

    @Test("Retired cards are dropped from the queue and reported")
    func retiredCardsAreExcluded() {
        var retiring = dueCard(stability: 1, daysSinceReview: 10)
        retiring.isGeneralized = true
        retiring.siblingPassedAtLongInterval = true
        let normal = dueCard(stability: 5, daysSinceReview: 10)

        let plan = SessionBuilder.sessionQueue(
            dueCards: [retiring, normal], freshCount: 0, targetSize: 10, now: now
        )
        #expect(plan.reviewCount == 1)
        #expect(plan.retired == [retiring.id])
    }

    @Test("Every queued review carries the presentation it has earned")
    func itemsCarryPresentation() {
        var mirrorable = dueCard(stability: 1, daysSinceReview: 10)
        mirrorable.mirrorIsLegal = true

        let plan = SessionBuilder.sessionQueue(
            dueCards: [mirrorable], freshCount: 0, targetSize: 10, now: now
        )
        guard case let .review(_, presentation) = plan.items[0] else {
            Issue.record("expected a review")
            return
        }
        #expect(presentation == .mirrored)
    }

    @Test("Failed cards get a same-day retry appended at the end of the session")
    func relearnRetriesGoLast() {
        // Retrying straight away tests nothing — the answer was on screen a
        // second ago. The rest of the session is the only interference we have.
        let failed = dueCard(stability: 1, daysSinceReview: 10)
        let passed = dueCard(stability: 5, daysSinceReview: 10)

        let plan = SessionBuilder.sessionQueue(
            dueCards: [failed, passed], freshCount: 8, targetSize: 10, now: now
        )
        let withRetries = SessionBuilder.appendRelearnRetries(to: plan, failedCardIDs: [failed.id])

        #expect(withRetries.items.count == plan.items.count + 1)
        #expect(withRetries.relearnCount == 1)
        guard case let .relearn(card, _) = withRetries.items[withRetries.items.count - 1] else {
            Issue.record("expected the retry at the very end")
            return
        }
        #expect(card.id == failed.id)
    }

    @Test("Retrying nothing changes nothing, and unknown ids are ignored")
    func relearnEdgeCases() {
        let plan = SessionBuilder.sessionQueue(
            dueCards: [dueCard(stability: 1, daysSinceReview: 10)],
            freshCount: 0, targetSize: 10, now: now
        )
        #expect(SessionBuilder.appendRelearnRetries(to: plan, failedCardIDs: []) == plan)
        #expect(SessionBuilder.appendRelearnRetries(to: plan, failedCardIDs: [UUID()]) == plan)
    }

    @Test("A failed fresh puzzle is not retried in-session; it becomes a card instead")
    func freshFailuresAreNotRetried() {
        let plan = SessionBuilder.sessionQueue(dueCards: [], freshCount: 10, targetSize: 10, now: now)
        let withRetries = SessionBuilder.appendRelearnRetries(to: plan, failedCardIDs: [UUID()])
        #expect(withRetries.relearnCount == 0)
        #expect(CardPolicy.shouldCreateCard(origin: .freshPuzzle, solved: false))
    }
}
