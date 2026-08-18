//
//  CardPolicy.swift
//  TrainingCore
//

import Foundation

/// How a card should be shown this time round.
///
/// See ``CardPolicy/presentation(for:tuning:)`` for the reasoning; the short
/// version is that a chess SRS card has a failure mode flashcards do not, and
/// these cases are the countermeasure.
public enum CardPresentation: Sendable, Hashable {

    /// Show the stored position exactly as it is.
    case asIs

    /// Swap colours (and side to move) so the user solves the same pattern from
    /// the other side of the board.
    case colorFlipped

    /// Colour-flipped *and* mirrored left-to-right. Strictly stronger than
    /// ``colorFlipped``; only offered when the mirror keeps the position legal.
    case mirrored

    /// Replace the position entirely with a different puzzle on the same theme
    /// in the given rating range.
    case themeSibling(theme: ThemeTag, ratingRange: ClosedRange<Int>)

    /// The pattern is learned. Stop reviewing it.
    case retire
}

/// A candidate card, before the daily cap has had its say.
public struct CardCandidate: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var origin: CardOrigin
    /// Whether the attempt that produced this candidate was solved. Only
    /// meaningful for ``CardOrigin/freshPuzzle``.
    public var solved: Bool
    /// How much this candidate is worth learning from. For a game mistake this
    /// is the expected-points swing; for a puzzle, anything the caller prefers
    /// to rank by. Higher wins.
    public var severity: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        origin: CardOrigin,
        solved: Bool = false,
        severity: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.origin = origin
        self.solved = solved
        self.severity = severity
        self.createdAt = createdAt
    }
}

/// The result of running the daily new-card cap.
public struct NewCardAdmission: Sendable, Hashable {
    /// Candidates that become cards today.
    public var admitted: [CardCandidate]
    /// Candidates that did not — either they never qualified, or the cap bit.
    public var deferred: [CardCandidate]
    /// Candidates rejected outright by the card-creation rule (a solved fresh
    /// puzzle). These will never become cards and should not be retried.
    public var rejected: [CardCandidate]

    public init(admitted: [CardCandidate] = [], deferred: [CardCandidate] = [], rejected: [CardCandidate] = []) {
        self.admitted = admitted
        self.deferred = deferred
        self.rejected = rejected
    }
}

/// Decides which positions become cards, and how a card is presented.
public enum CardPolicy {

    // MARK: - Card creation

    /// Whether a puzzle at `puzzleRating` is inside the fresh-serving band for
    /// a user at `userRating`.
    ///
    /// This governs *serving*, not card creation. It is here because the two
    /// rules are easy to confuse and the distinction is the whole point of the
    /// section below.
    public static func isWithinServingBand(
        userRating: Int,
        puzzleRating: Int,
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> Bool {
        abs(puzzleRating - userRating) <= tuning.freshServingBand
    }

    /// Whether an attempt should produce a card.
    ///
    /// **A solved fresh puzzle never becomes a card.** This is the single most
    /// important rule in the card policy and the one every puzzle app gets
    /// wrong. A puzzle served at the user's own rating that they solved is, by
    /// construction, a thing they can already do — turning it into a card
    /// spends the user's scarcest resource (review time) re-proving a skill,
    /// while the review queue grows without bound and the app becomes a chore.
    ///
    /// A card is earned by evidence of a *gap*:
    /// - the user failed the puzzle,
    /// - the user explicitly flagged the position, or
    /// - the position came from a mistake in one of the user's own games.
    public static func shouldCreateCard(origin: CardOrigin, solved: Bool) -> Bool {
        switch origin {
        case .freshPuzzle:
            return !solved
        case .flagged, .gameMistake:
            return true
        }
    }

    /// Applies the daily new-card cap.
    ///
    /// - Parameters:
    ///   - candidates: Everything that happened today that could become a card.
    ///   - createdToday: New cards already created today, so the cap survives
    ///     multiple sessions in one day.
    ///
    /// Ordering when the cap bites, highest priority first:
    /// 1. **flagged** — an explicit user request. Silently dropping something
    ///    the user asked for is the one failure mode that damages trust in the
    ///    deck, so it never loses to an inferred candidate.
    /// 2. **gameMistake** — a mistake from the user's own game is more
    ///    motivating and more transferable than a corpus puzzle.
    /// 3. **freshPuzzle** (failed) — plentiful; there will be more tomorrow.
    ///
    /// Within a tier, higher ``CardCandidate/severity`` first, then oldest
    /// first, then by id so the result is fully deterministic.
    public static func admitNewCards(
        candidates: [CardCandidate],
        createdToday: Int = 0,
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> NewCardAdmission {
        var rejected: [CardCandidate] = []
        var eligible: [CardCandidate] = []
        for candidate in candidates {
            if shouldCreateCard(origin: candidate.origin, solved: candidate.solved) {
                eligible.append(candidate)
            } else {
                rejected.append(candidate)
            }
        }

        eligible.sort { lhs, rhs in
            let lp = priority(lhs.origin), rp = priority(rhs.origin)
            if lp != rp { return lp < rp }
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let remaining = max(0, tuning.newCardsPerDay - createdToday)
        let cut = min(remaining, eligible.count)
        return NewCardAdmission(
            admitted: Array(eligible[..<cut]),
            deferred: Array(eligible[cut...]),
            rejected: rejected
        )
    }

    private static func priority(_ origin: CardOrigin) -> Int {
        switch origin {
        case .flagged: return 0
        case .gameMistake: return 1
        case .freshPuzzle: return 2
        }
    }

    // MARK: - Anti-memorization

    /// How this card should be presented on its next review.
    ///
    /// ## The failure mode this exists to prevent
    ///
    /// Spaced repetition assumes the card tests a *concept*. A chess puzzle
    /// card does not: it tests a specific position with a specific answer, and
    /// the answer is a short string of moves. After three or four reviews the
    /// user stops seeing the board and starts recognising the picture —
    /// "ah, the one where the knight goes to f6". They then answer instantly,
    /// the auto-grader reads that as `.easy`, FSRS pushes the interval out, and
    /// every signal in the system says the pattern is mastered. Meanwhile the
    /// user still hangs the same fork in a real game, because what they
    /// actually learned was a mnemonic for one photograph.
    ///
    /// This is the documented reason SRS-for-chess decks feel productive and
    /// don't transfer. The counter is a ladder of increasingly aggressive
    /// perturbations, each of which preserves the tactical idea while
    /// destroying the surface memory:
    ///
    /// 1. **First review: as-is.** The user has seen the position once and
    ///    failed it; changing it immediately tests something they were never
    ///    taught.
    /// 2. **From the second review: colour-flipped**, and file-mirrored too
    ///    when castling rights allow. Same idea, different picture. Mirroring
    ///    is preferred where legal because it also breaks the "the knight goes
    ///    to f6" verbal handle, which a colour flip alone leaves intact.
    /// 3. **After two consecutive passes at an interval ≥ 21 days: swap for a
    ///    theme sibling** — a different puzzle, same primary theme, ±100
    ///    rating. This is the real test. Two long-interval passes mean the
    ///    surface memory has had time to decay, so if the sibling also lands,
    ///    what transferred was the pattern. The original is marked generalized.
    /// 4. **After the sibling also passes at a long interval: retire.** The
    ///    concept is learned. Continuing to review it is pure cost.
    public static func presentation(
        for card: TrainingCard,
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> CardPresentation {
        // Retirement is checked first: it ends the card, and nothing below can
        // apply to a card that is finished.
        if card.isGeneralized && card.siblingPassedAtLongInterval {
            return .retire
        }

        // Promotion to a sibling outranks the geometric transforms, because it
        // subsumes them — a different position is a stronger perturbation than
        // a mirrored one.
        if !card.isGeneralized,
           card.consecutiveLongIntervalPasses >= tuning.longIntervalPassesBeforeSibling {
            let radius = tuning.siblingRatingRadius
            return .themeSibling(
                theme: card.primaryTheme,
                ratingRange: (card.puzzleRating - radius)...(card.puzzleRating + radius)
            )
        }

        // A card already swapped to its sibling keeps being perturbed while it
        // works toward the long-interval pass that retires it.
        guard card.state.reps > tuning.reviewsBeforeTransform - 1 else {
            return .asIs
        }
        return card.mirrorIsLegal ? .mirrored : .colorFlipped
    }
}
