//
//  SessionAssembler.swift
//  ChessCoach
//

import Database
import Foundation
import TrainingCore

// MARK: - Solvable item

/// A position the user can be asked to solve, independent of where it came from.
///
/// Corpus puzzles and positions mined from the user's own games differ in one
/// way that matters — a corpus puzzle opens with the opponent's setup move and a
/// mined position does not — and in no other way the training loop cares about.
/// Unifying them here is what lets one solve machine, one grader and one
/// scheduler serve both.
struct SolvableItem: Sendable, Hashable {

    enum Backing: Sendable, Hashable {
        case corpusPuzzle(id: Puzzle.ID)
        /// A position lifted from a game. The `Moment` row it came from, when
        /// known, so the card can link back to the coaching text.
        case momentPosition(momentID: UUID?)
    }

    var backing: Backing
    /// FEN as stored: for a corpus puzzle, the position *before* the setup move.
    var fen: String
    /// UCI line as stored, setup move first for a corpus puzzle.
    var line: [String]
    var opponentMovesFirst: Bool
    var rating: Int
    var primaryTheme: ThemeTag

    init(
        backing: Backing,
        fen: String,
        line: [String],
        opponentMovesFirst: Bool,
        rating: Int,
        primaryTheme: ThemeTag
    ) {
        self.backing = backing
        self.fen = fen
        self.line = line
        self.opponentMovesFirst = opponentMovesFirst
        self.rating = rating
        self.primaryTheme = primaryTheme
    }

    init(puzzle: Puzzle) {
        self.init(
            backing: .corpusPuzzle(id: puzzle.id),
            fen: puzzle.fen,
            line: puzzle.moveList,
            opponentMovesFirst: true,
            rating: puzzle.rating,
            primaryTheme: TrainingVocabulary.primaryTheme(of: puzzle)
        )
    }

    var puzzleID: Puzzle.ID? {
        if case let .corpusPuzzle(id) = backing { return id }
        return nil
    }
}

// MARK: - Presented puzzle

/// A ``SolvableItem`` with its anti-memorization transform already applied.
///
/// The transform is applied to the FEN **and** to every move in the line. Doing
/// only the first would be a silent correctness bug: the board would look right
/// and every answer would be judged against the untransformed solution.
struct PresentedPuzzle: Sendable, Hashable {

    var item: SolvableItem
    var transform: BoardTransform
    /// Transformed FEN.
    var fen: String
    /// Transformed line.
    var line: [String]

    init?(item: SolvableItem, transform: BoardTransform) {
        guard
            let fen = transform.apply(toFEN: item.fen),
            let line = transform.apply(toUCILine: item.line)
        else { return nil }
        self.item = item
        self.transform = transform
        self.fen = fen
        self.line = line
    }

    /// Falls back to showing the position untransformed rather than dropping it.
    ///
    /// A transform that will not apply is a data problem, not a reason to serve
    /// the user nine puzzles instead of ten.
    init(item: SolvableItem, preferring transform: BoardTransform) {
        if let presented = PresentedPuzzle(item: item, transform: transform) {
            self = presented
        } else {
            self.item = item
            self.transform = .identity
            self.fen = item.fen
            self.line = item.line
        }
    }

    func machine(retryPolicy: PuzzleSolveMachine.RetryPolicy = .endOnFirstMistake) -> PuzzleSolveMachine? {
        PuzzleSolveMachine(
            fen: fen,
            line: line,
            opponentMovesFirst: item.opponentMovesFirst,
            retryPolicy: retryPolicy
        )
    }
}

// MARK: - Session plan

/// One entry in today's queue.
struct SessionItemPlan: Sendable, Hashable, Identifiable {

    enum Kind: Sendable, Hashable {
        case review(cardID: SRSCard.ID)
        /// The same-day retry appended after a failure.
        case relearn(cardID: SRSCard.ID)
        case fresh

        var cardID: SRSCard.ID? {
            switch self {
            case let .review(id), let .relearn(id): return id
            case .fresh: return nil
            }
        }

        var isReview: Bool {
            switch self {
            case .review, .relearn: return true
            case .fresh: return false
            }
        }
    }

    var id: UUID
    var kind: Kind
    var presented: PresentedPuzzle
    /// Whether this slot was filled from the weekly focus habit's themes.
    var isFocusThemed: Bool

    init(id: UUID = UUID(), kind: Kind, presented: PresentedPuzzle, isFocusThemed: Bool = false) {
        self.id = id
        self.kind = kind
        self.presented = presented
        self.isFocusThemed = isFocusThemed
    }

    var retryPolicy: PuzzleSolveMachine.RetryPolicy {
        // A relearn item exists precisely to give the user another go at
        // something they just failed; ending it on the first slip would make it
        // identical to the review that already failed.
        if case .relearn = kind { return .allowRetries(1) }
        return .endOnFirstMistake
    }
}

/// The assembled session.
struct AssembledSession: Sendable, Hashable {
    var items: [SessionItemPlan]
    /// Cards the policy retired. The caller marks these done rather than
    /// re-queueing them tomorrow.
    var retired: [SRSCard.ID]
    var mix: DrillMix

    init(items: [SessionItemPlan] = [], retired: [SRSCard.ID] = [], mix: DrillMix = DrillMix(focusThemed: 0, dueOrGeneral: 0)) {
        self.items = items
        self.retired = retired
        self.mix = mix
    }
}

// MARK: - Assembler

/// Builds today's queue from already-fetched material.
///
/// Pure on purpose: every I/O decision (how many puzzles to fetch, from which
/// band, with which theme mask) is made by the caller *using this type's own
/// sizing helpers*, so the assembly rule itself can be tested from literals.
enum SessionAssembler {

    /// Everything the assembler needs, already loaded.
    struct Inputs: Sendable {
        var dueCards: [TrainingCard]
        /// The position behind each due card.
        var positions: [TrainingCard.ID: SolvableItem]
        /// Theme-sibling replacements for the cards whose presentation asked for
        /// one. A card with no sibling available is shown as-is.
        var siblings: [TrainingCard.ID: Puzzle]
        /// Fresh puzzles drawn from the focus habit's themes, best first.
        var focusThemedPuzzles: [Puzzle]
        /// Fresh puzzles with no theme filter.
        var generalPuzzles: [Puzzle]
        var focus: WeeklyFocus?
        var now: Date

        init(
            dueCards: [TrainingCard] = [],
            positions: [TrainingCard.ID: SolvableItem] = [:],
            siblings: [TrainingCard.ID: Puzzle] = [:],
            focusThemedPuzzles: [Puzzle] = [],
            generalPuzzles: [Puzzle] = [],
            focus: WeeklyFocus? = nil,
            now: Date = Date()
        ) {
            self.dueCards = dueCards
            self.positions = positions
            self.siblings = siblings
            self.focusThemedPuzzles = focusThemedPuzzles
            self.generalPuzzles = generalPuzzles
            self.focus = focus
            self.now = now
        }
    }

    /// How many fresh puzzles the session will want, given the cards that are
    /// due.
    ///
    /// Asks `SessionBuilder` rather than re-deriving `targetSize - reviews`, so
    /// the review cap and the target size stay owned by the package that
    /// documents them.
    static func freshSlotCount(
        dueCards: [TrainingCard],
        targetSize: Int = DomainTuning.default.cards.sessionTargetSize,
        now: Date = Date(),
        scheduler: any SchedulerProtocol = FSRS6(),
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> Int {
        SessionBuilder.sessionQueue(
            dueCards: dueCards,
            freshCount: targetSize,
            targetSize: targetSize,
            now: now,
            scheduler: scheduler,
            tuning: tuning
        ).freshCount
    }

    /// The 60/40 split of the fresh slots.
    static func mix(
        freshSlots: Int,
        focus: WeeklyFocus?,
        tuning: DomainTuning.Focus = DomainTuning.default.focus
    ) -> DrillMix {
        FocusSelector.drillMix(totalPuzzles: freshSlots, focus: focus, tuning: tuning)
    }

    /// Assembles the queue.
    static func assemble(
        _ inputs: Inputs,
        targetSize: Int = DomainTuning.default.cards.sessionTargetSize,
        scheduler: any SchedulerProtocol = FSRS6(),
        tuning: DomainTuning = .default
    ) -> AssembledSession {

        // Fresh slots are ordered focus-themed first so that a session the user
        // abandons halfway still contains the week's work. The 60/40 split is
        // about what a *complete* session holds; putting the focus puzzles
        // second would quietly turn it into 0/100 for anyone who stops early.
        let available = inputs.focusThemedPuzzles.count + inputs.generalPuzzles.count

        let plan = SessionBuilder.sessionQueue(
            dueCards: inputs.dueCards,
            freshCount: available,
            targetSize: targetSize,
            now: inputs.now,
            scheduler: scheduler,
            tuning: tuning.cards
        )

        let planWithRetries = plan
        let mix = mix(freshSlots: planWithRetries.freshCount, focus: inputs.focus, tuning: tuning.focus)

        var focusPool = inputs.focusThemedPuzzles[...]
        var generalPool = inputs.generalPuzzles[...]
        var focusRemaining = mix.focusThemed

        var items: [SessionItemPlan] = []
        items.reserveCapacity(planWithRetries.items.count)

        for entry in planWithRetries.items {
            switch entry {
            case let .review(card, presentation):
                guard let item = presentedItem(for: card, presentation: presentation, inputs: inputs) else { continue }
                items.append(SessionItemPlan(kind: .review(cardID: card.id), presented: item))

            case let .relearn(card, presentation):
                guard let item = presentedItem(for: card, presentation: presentation, inputs: inputs) else { continue }
                items.append(SessionItemPlan(kind: .relearn(cardID: card.id), presented: item))

            case .fresh:
                let wantsFocus = focusRemaining > 0 && !focusPool.isEmpty
                let puzzle: Puzzle?
                if wantsFocus {
                    puzzle = focusPool.popFirst()
                    focusRemaining -= 1
                } else if let general = generalPool.popFirst() {
                    puzzle = general
                } else {
                    // The focus pool is the fallback for the general pool and
                    // vice versa: an under-stocked rating band should shrink the
                    // session, not empty it.
                    puzzle = focusPool.popFirst()
                }
                guard let puzzle else { continue }
                items.append(
                    SessionItemPlan(
                        kind: .fresh,
                        presented: PresentedPuzzle(item: SolvableItem(puzzle: puzzle), preferring: .identity),
                        isFocusThemed: wantsFocus
                    )
                )
            }
        }

        return AssembledSession(items: items, retired: planWithRetries.retired, mix: mix)
    }

    /// Appends same-day retries for the cards failed during this session.
    static func appendingRelearnRetries(
        to session: AssembledSession,
        failedCardIDs: [SRSCard.ID]
    ) -> AssembledSession {
        guard !failedCardIDs.isEmpty else { return session }
        let failed = Set(failedCardIDs)

        var updated = session
        for item in session.items {
            guard case let .review(cardID) = item.kind, failed.contains(cardID) else { continue }
            // Same position, same transform: the retry tests recall of the thing
            // that was just missed, not a fresh perturbation of it.
            updated.items.append(
                SessionItemPlan(kind: .relearn(cardID: cardID), presented: item.presented, isFocusThemed: item.isFocusThemed)
            )
        }
        return updated
    }

    /// Resolves a card's presentation into a concrete position.
    private static func presentedItem(
        for card: TrainingCard,
        presentation: CardPresentation,
        inputs: Inputs
    ) -> PresentedPuzzle? {
        if case .themeSibling = presentation {
            if let sibling = inputs.siblings[card.id] {
                // A sibling is a position the user has never seen, so it is
                // shown untransformed — perturbing it would test something they
                // were never taught.
                return PresentedPuzzle(item: SolvableItem(puzzle: sibling), preferring: .identity)
            }
            // No sibling in the corpus for this theme and band. Falling back to
            // the original is better than skipping the card: the user still gets
            // the review, just without the generalization test, and the ladder
            // will ask again next time.
            guard let item = inputs.positions[card.id] else { return nil }
            let transform = BoardTransform.resolved(
                for: card.mirrorIsLegal ? .mirrored : .colorFlipped,
                fen: item.fen
            )
            return PresentedPuzzle(item: item, preferring: transform)
        }

        guard let item = inputs.positions[card.id] else { return nil }
        let transform = BoardTransform.resolved(for: presentation, fen: item.fen)
        return PresentedPuzzle(item: item, preferring: transform)
    }
}
