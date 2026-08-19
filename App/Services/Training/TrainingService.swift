//
//  TrainingService.swift
//  ChessCoach
//

import Database
import Foundation
import Observation
import TrainingCore

/// Runs the daily training session.
///
/// ## Why `@MainActor @Observable` and not an `actor`
///
/// Everything this type coordinates is *user-paced*: one puzzle on screen, one
/// move at a time, each event triggered by a tap. The domain work it does per
/// event — an `AutoGrader` grade, one FSRS update, one Glicko update — is
/// arithmetic measured in microseconds, and the storage underneath is GRDB,
/// which already serialises its own access and is `Sendable`.
///
/// An `actor` would buy nothing and cost something real: every read the board
/// view makes (`currentItem`, `phase`, `machine.board`) would become an `await`,
/// which in SwiftUI means the position arrives a frame after the tap. So the
/// session state lives on the main actor where the views are, and the only thing
/// pushed off it is I/O — the session load and the per-item persistence — via
/// `nonisolated` statics that take their dependencies as parameters and
/// therefore genuinely run on the cooperative pool.
@MainActor
@Observable
final class TrainingService {

    // MARK: Phase

    enum Phase: Equatable {
        case idle
        case loading
        case solving
        case finished
        case failed(String)
    }

    /// What the user did today, for the summary screen.
    struct Summary: Sendable, Equatable {
        var attempted = 0
        var solved = 0
        var hinted = 0
        var newCards = 0
        var puzzleRating: GlickoRating = .start()
    }

    // MARK: Dependencies

    private nonisolated let srs: any SRSCardStore
    private nonisolated let corpus: any PuzzleCorpus
    private nonisolated let metrics: any MetricStore
    private nonisolated let dailyLoop: any DailyLoopStore
    private nonisolated let settings: any AppSettingsStore
    private nonisolated let momentPositions: any MomentPositionSource
    private nonisolated let scheduler: any SchedulerProtocol
    private nonisolated let tuning: DomainTuning
    private nonisolated let clock: @Sendable () -> Date

    init(
        srs: any SRSCardStore,
        corpus: any PuzzleCorpus,
        metrics: any MetricStore,
        dailyLoop: any DailyLoopStore,
        settings: any AppSettingsStore,
        momentPositions: any MomentPositionSource = EmptyMomentPositionSource(),
        scheduler: any SchedulerProtocol = FSRS6(),
        tuning: DomainTuning = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.srs = srs
        self.corpus = corpus
        self.metrics = metrics
        self.dailyLoop = dailyLoop
        self.settings = settings
        self.momentPositions = momentPositions
        self.scheduler = scheduler
        self.tuning = tuning
        self.clock = clock
    }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var session = AssembledSession()
    private(set) var itemIndex = 0
    private(set) var machine: PuzzleSolveMachine?
    private(set) var summary = Summary()
    /// The focus the session was built against, for the header UI.
    private(set) var focus: WeeklyFocus?
    /// Set when the last user move was rejected as wrong, for the shake/undo UI.
    private(set) var lastRejection: String?

    /// Positions the user asked to keep. Only meaningful until the session ends.
    private var flaggedItemIDs: Set<UUID> = []
    /// Cards failed in this session, so retries can be appended once.
    private var failedCardIDs: [SRSCard.ID] = []
    private var retriesAppended = false
    /// Candidates for new cards, keyed by the candidate id the policy sorts on.
    private var pendingCandidates: [UUID: PendingCandidate] = [:]
    private var itemStartedAt: Date?

    var currentItem: SessionItemPlan? {
        session.items.indices.contains(itemIndex) ? session.items[itemIndex] : nil
    }

    var progress: (done: Int, total: Int) {
        (min(itemIndex, session.items.count), session.items.count)
    }

    // MARK: Session lifecycle

    /// Builds and starts today's session.
    func startSession(focus: WeeklyFocus?) async {
        guard phase != .loading else { return }
        phase = .loading
        self.focus = focus

        let now = clock()
        do {
            let loaded = try await Self.loadSession(
                srs: srs,
                corpus: corpus,
                metrics: metrics,
                settings: settings,
                momentPositions: momentPositions,
                scheduler: scheduler,
                tuning: tuning,
                focus: focus,
                now: now
            )
            session = loaded.session
            summary.puzzleRating = loaded.rating
            itemIndex = 0
            flaggedItemIDs = []
            failedCardIDs = []
            retriesAppended = false
            pendingCandidates = [:]

            // Retired cards must be taken out of rotation or they come back
            // tomorrow forever. Pushing the due date out is preferred to
            // deleting: the review history is the evidence the ladder was
            // completed, and deleting it would make the card look brand new if
            // the same puzzle is ever served again.
            try? await Self.retire(cardIDs: loaded.session.retired, srs: srs, now: now)

            phase = session.items.isEmpty ? .finished : .solving
            beginCurrentItem()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func beginCurrentItem() {
        guard let item = currentItem else {
            phase = .finished
            machine = nil
            return
        }
        var built = item.presented.machine(retryPolicy: item.retryPolicy)
        built?.start()
        machine = built
        itemStartedAt = clock()
        lastRejection = nil

        // A line that will not replay is a corrupt row, not a user failure.
        // Skip it silently rather than scoring the user for our data.
        if built == nil || built?.phase == .ready {
            advance()
        }
    }

    // MARK: Solving

    /// Offers a user move for the current item.
    @discardableResult
    func play(uci: String) async -> PuzzleSolveMachine.MoveResult {
        guard phase == .solving, var current = machine else { return .illegal }
        let result = current.play(uci: uci)
        machine = current

        switch result {
        case .illegal:
            break
        case let .retry(expected, _):
            lastRejection = expected
        case .advanced:
            lastRejection = nil
        case .solved, .failed:
            await finishCurrentItem()
        }
        return result
    }

    /// Reveals the answer for the current item.
    ///
    /// The attempt is already lost — `AutoGrader` grades any hint `.again` — but
    /// the user keeps playing so they actually see the line.
    @discardableResult
    func hint() -> String? {
        guard var current = machine else { return nil }
        let move = current.revealHint()
        machine = current
        return move
    }

    /// Marks the current position to be kept as a card regardless of outcome.
    func flagCurrentPosition() {
        guard let item = currentItem else { return }
        flaggedItemIDs.insert(item.id)
    }

    /// Abandons the current item without an answer. Counts as a failure: the
    /// user was shown the position and did not solve it.
    func skip() async {
        guard phase == .solving else { return }
        await finishCurrentItem()
    }

    private func finishCurrentItem() async {
        guard let item = currentItem, let current = machine else { return }

        let now = clock()
        let latency = itemStartedAt.map { now.timeIntervalSince($0) * 1000 } ?? 0
        let band = TrainingVocabulary.latencyBand(forRating: item.presented.item.rating)
        let bandMedian = metrics.value(
            TrainingMetricKeys.latencyMedian(band: band),
            default: LatencyBandMedian.seed(band: band)
        )

        let attempt = current.attempt(latencyMs: latency, bandMedianLatencyMs: bandMedian)
        let rating = attempt.rating(tuning: tuning.grading)

        summary.attempted += 1
        if attempt.correct { summary.solved += 1 }
        if attempt.usedHint { summary.hinted += 1 }

        // A solved-with-hint attempt still counts as *not solved* for the
        // rating and for card creation: the answer was on screen.
        let solvedUnaided = attempt.correct && !attempt.usedHint

        if let cardID = item.kind.cardID, !solvedUnaided, case .review = item.kind {
            failedCardIDs.append(cardID)
        }
        registerCandidate(for: item, solvedUnaided: solvedUnaided, deltaSeverity: attempt.latencyMs)

        let context = ItemPersistence(
            item: item,
            rating: rating,
            attempt: attempt,
            solvedUnaided: solvedUnaided,
            band: band,
            bandMedian: bandMedian,
            now: now
        )

        do {
            let updated = try await Self.persist(
                context,
                srs: srs,
                metrics: metrics,
                dailyLoop: dailyLoop,
                settings: settings,
                scheduler: scheduler,
                tuning: tuning,
                currentRating: summary.puzzleRating
            )
            summary.puzzleRating = updated
        } catch {
            // A failed write must not strand the user mid-session; the review
            // stays due and will come back tomorrow.
            phase = .solving
        }

        advance()
    }

    private func advance() {
        itemIndex += 1

        // Retries are appended once, when the planned queue runs out, so a card
        // failed on the last item still gets its retry.
        if itemIndex >= session.items.count, !retriesAppended {
            retriesAppended = true
            session = SessionAssembler.appendingRelearnRetries(to: session, failedCardIDs: failedCardIDs)
        }

        if itemIndex >= session.items.count {
            machine = nil
            phase = .finished
            Task { await self.finishSession() }
            return
        }
        beginCurrentItem()
    }

    /// Admits new cards under the daily cap and closes the day's loop entry.
    private func finishSession() async {
        let now = clock()
        let candidates = pendingCandidates.values.map(\.candidate)
        guard !candidates.isEmpty else { return }

        do {
            let created = try await Self.admitCards(
                candidates: candidates,
                sources: pendingCandidates,
                srs: srs,
                metrics: metrics,
                tuning: tuning,
                now: now
            )
            summary.newCards = created
        } catch {
            // Card creation is a nice-to-have relative to the session itself.
        }
    }

    private func registerCandidate(for item: SessionItemPlan, solvedUnaided: Bool, deltaSeverity: Double) {
        // Only *fresh* puzzles can become new cards here. A review item already
        // has a card, and a relearn item is a second look at that same card.
        guard case .fresh = item.kind else { return }
        let flagged = flaggedItemIDs.contains(item.id)
        guard flagged || !solvedUnaided else { return }

        let candidate = CardCandidate(
            origin: flagged ? .flagged : .freshPuzzle,
            solved: solvedUnaided,
            // Severity ranks candidates when the cap bites. For a puzzle, the
            // rating is the best available proxy for "how much is there to
            // learn here" — a failed 1400 says more than a failed 900.
            severity: Double(item.presented.item.rating),
            createdAt: clock()
        )
        pendingCandidates[candidate.id] = PendingCandidate(candidate: candidate, item: item)
    }

    // MARK: Drills

    /// Records the outcome of an endgame drill run and updates its streak.
    ///
    /// Streaks rather than rates because the curriculum asks for streaks, and it
    /// asks for streaks because a technique you get right two times running is
    /// known and a technique you get right 70% of the time is not.
    @discardableResult
    func recordDrill(_ run: EndgameDrillRun) async -> Double {
        await Self.recordDrillStreak(
            kind: run.drill.kind,
            clean: run.isClean,
            metrics: metrics,
            now: clock()
        )
    }

    /// Records a complete KPK set. A set is clean only if every position in it
    /// was, which is the whole point: the family tests telling won from drawn.
    @discardableResult
    func recordKPKSet(runs: [EndgameDrillRun]) async -> Double {
        let expected = tuning.curriculum.kpkSetSize
        let clean = runs.count >= expected && runs.allSatisfy(\.isClean)
        return await Self.recordDrillStreak(kind: .kpk, clean: clean, metrics: metrics, now: clock())
    }

    // MARK: Moment cards

    /// Promotes mined moments into cards, under the same daily cap.
    ///
    /// Game mistakes outrank corpus puzzles in `CardPolicy`, so calling this
    /// before or after a session gives the same answer — the policy sorts.
    @discardableResult
    func createCards(fromMoments moments: [Database.Moment]) async -> Int {
        let now = clock()
        var sources: [UUID: PendingCandidate] = [:]
        var candidates: [CardCandidate] = []

        for moment in moments {
            let candidate = CardCandidate(
                origin: .gameMistake,
                solved: false,
                // Expected-points lost is the natural severity for a game
                // mistake: it is literally how much the move cost.
                severity: moment.deltaEP,
                createdAt: moment.createdAt
            )
            candidates.append(candidate)
            sources[candidate.id] = PendingCandidate(moment: moment, candidate: candidate)
        }

        let created = try? await Self.admitCards(
            candidates: candidates,
            sources: sources,
            srs: srs,
            metrics: metrics,
            tuning: tuning,
            now: now
        )
        return created ?? 0
    }
}

// MARK: - Pending candidate

/// A candidate card and the thing it came from.
private struct PendingCandidate: Sendable {
    var candidate: CardCandidate
    var item: SessionItemPlan?
    var moment: Database.Moment?

    init(candidate: CardCandidate, item: SessionItemPlan) {
        self.candidate = candidate
        self.item = item
        self.moment = nil
    }

    init(moment: Database.Moment, candidate: CardCandidate) {
        self.candidate = candidate
        self.item = nil
        self.moment = moment
    }
}

/// Everything one finished item needs written.
private struct ItemPersistence: Sendable {
    var item: SessionItemPlan
    var rating: TrainingCore.ReviewRating
    var attempt: PuzzleAttempt
    var solvedUnaided: Bool
    var band: Int
    var bandMedian: Double
    var now: Date
}

// MARK: - Off-main work

extension TrainingService {

    private struct LoadedSession: Sendable {
        var session: AssembledSession
        var rating: GlickoRating
    }

    /// Loads and assembles the session.
    ///
    /// `nonisolated static` with every dependency passed in: that is what makes
    /// the `await` at the call site an actual hop off the main actor rather than
    /// a same-actor continuation.
    private nonisolated static func loadSession(
        srs: any SRSCardStore,
        corpus: any PuzzleCorpus,
        metrics: any MetricStore,
        settings: any AppSettingsStore,
        momentPositions: any MomentPositionSource,
        scheduler: any SchedulerProtocol,
        tuning: DomainTuning,
        focus: WeeklyFocus?,
        now: Date
    ) async throws -> LoadedSession {

        let stored = try settings.current()
        let rating = GlickoRating(rating: stored.puzzleRating, deviation: stored.puzzleRD)
        let userPuzzleRating = Int(stored.puzzleRating.rounded())

        // Fetch a generous slice of due cards: the session takes at most seven,
        // but `SessionBuilder` needs to see the whole due set to order it by
        // retrievability and to retire the ones that have finished the ladder.
        let dueRows = try srs.due(at: now, limit: 64)

        var cards: [TrainingCard] = []
        var positions: [TrainingCard.ID: SolvableItem] = [:]
        // Seeded from the serve history rather than starting empty. Exclusion
        // that only spans one load keeps a puzzle out of *today's* queue and
        // hands the same one back next week: the corpus query is
        // `ORDER BY random()` over a rating band, so a band of a few thousand
        // rows repeats within a fortnight at ten puzzles a day, and the second
        // sighting measures memory of the answer rather than the idea.
        var seenPuzzleIDs = ServedPuzzleHistory.recentlyServed(metrics: metrics)

        for row in dueRows {
            guard let item = try resolvePosition(row: row, corpus: corpus, momentPositions: momentPositions) else {
                continue
            }
            let ladder = CardLadderState.derive(from: (try? srs.reviews(forCard: row.id)) ?? [], tuning: tuning.cards)
            let card = TrainingCardBridge.trainingCard(
                from: row,
                context: TrainingCardBridge.Context(
                    fen: item.fen,
                    puzzleRating: item.rating,
                    primaryTheme: item.primaryTheme,
                    ladder: ladder
                )
            )
            cards.append(card)
            positions[card.id] = item
            if let id = item.puzzleID { seenPuzzleIDs.insert(id) }
        }

        // Theme siblings for the cards that have earned one.
        var siblings: [TrainingCard.ID: Puzzle] = [:]
        for card in cards {
            guard case let .themeSibling(theme, range) = CardPolicy.presentation(for: card, tuning: tuning.cards),
                  let puzzleTheme = TrainingVocabulary.puzzleTheme(theme)
            else { continue }
            let found = try corpus.puzzles(
                ratingRange: range,
                themes: ThemeMask([puzzleTheme]),
                limit: 1,
                excluding: seenPuzzleIDs
            )
            if let sibling = found.first {
                siblings[card.id] = sibling
                seenPuzzleIDs.insert(sibling.id)
            }
        }

        // Ask the package how many fresh slots there are, then fill them 60/40.
        let freshSlots = SessionAssembler.freshSlotCount(
            dueCards: cards,
            targetSize: tuning.cards.sessionTargetSize,
            now: now,
            scheduler: scheduler,
            tuning: tuning.cards
        )
        let mix = SessionAssembler.mix(freshSlots: freshSlots, focus: focus, tuning: tuning.focus)
        let band = TrainingVocabulary.servingBand(userPuzzleRating: userPuzzleRating, tuning: tuning.cards)

        var focusThemed: [Puzzle] = []
        if mix.focusThemed > 0, let habit = focus?.habit {
            let mask = TrainingVocabulary.themes(for: habit)
            if !mask.isEmpty {
                focusThemed = try corpus.puzzles(
                    ratingRange: band,
                    themes: mask,
                    limit: mix.focusThemed,
                    excluding: seenPuzzleIDs
                )
                seenPuzzleIDs.formUnion(focusThemed.map(\.id))
            }
        }

        // Whatever the focus query could not fill falls through to the general
        // pool, so a thin theme never shrinks the session.
        let generalWanted = freshSlots - focusThemed.count
        var general: [Puzzle] = []
        if generalWanted > 0 {
            general = try corpus.puzzles(
                ratingRange: band,
                themes: .empty,
                limit: generalWanted,
                excluding: seenPuzzleIDs
            )
        }

        let assembled = SessionAssembler.assemble(
            SessionAssembler.Inputs(
                dueCards: cards,
                positions: positions,
                siblings: siblings,
                focusThemedPuzzles: focusThemed,
                generalPuzzles: general,
                focus: focus,
                now: now
            ),
            targetSize: tuning.cards.sessionTargetSize,
            scheduler: scheduler,
            tuning: tuning
        )

        return LoadedSession(session: assembled, rating: rating)
    }

    /// Finds the position behind a stored card.
    private nonisolated static func resolvePosition(
        row: SRSCard,
        corpus: any PuzzleCorpus,
        momentPositions: any MomentPositionSource
    ) throws -> SolvableItem? {
        if let puzzleID = row.puzzleID, let puzzle = try corpus.puzzle(id: puzzleID) {
            return SolvableItem(puzzle: puzzle)
        }
        guard let fen = row.fen, let line = try momentPositions.solutionLine(fen: fen), !line.isEmpty else {
            return nil
        }
        return SolvableItem(
            backing: .momentPosition(momentID: nil),
            fen: fen,
            line: line,
            // The moment's FEN is already the position the user got wrong, so
            // there is no setup move to play.
            opponentMovesFirst: false,
            rating: 0,
            primaryTheme: ThemeTag("middlegame")
        )
    }

    private nonisolated static func retire(cardIDs: [SRSCard.ID], srs: any SRSCardStore, now: Date) async throws {
        guard !cardIDs.isEmpty else { return }
        for id in cardIDs {
            guard var card = try srs.card(id: id) else { continue }
            card.due = now.addingTimeInterval(365 * 100 * 86_400)
            try srs.save(card)
        }
    }

    /// Writes everything one finished item produces.
    private nonisolated static func persist(
        _ context: ItemPersistence,
        srs: any SRSCardStore,
        metrics: any MetricStore,
        dailyLoop: any DailyLoopStore,
        settings: any AppSettingsStore,
        scheduler: any SchedulerProtocol,
        tuning: DomainTuning,
        currentRating: GlickoRating
    ) async throws -> GlickoRating {

        let item = context.item
        let isReview = item.kind.isReview

        // 1. Scheduling.
        if let cardID = item.kind.cardID, var row = try srs.card(id: cardID) {
            let before = TrainingCardBridge.cardState(from: row)
            let next = scheduler.nextReview(card: before, rating: context.rating, now: context.now)
            row = TrainingCardBridge.apply(next, to: row)
            try srs.recordReview(
                card: row,
                rating: TrainingCardBridge.storedRating(context.rating),
                stateBefore: TrainingCardBridge.storedState(before.state),
                elapsedDays: before.elapsedDays(at: context.now),
                scheduledDays: before.scheduledIntervalDays,
                durationMs: Int(context.attempt.latencyMs),
                reviewedAt: context.now
            )
        }

        // 2. Puzzle rating. SRS reviews count at half weight — a repeat of a
        //    puzzle the user has already been shown is not independent evidence
        //    of strength, and full weight would let them farm their own deck.
        var rating = currentRating
        if item.presented.item.rating > 0 {
            let glicko = Glicko1(tuning: tuning.puzzleRating)
            rating = glicko.update(
                rating,
                with: PuzzleResult(
                    puzzleRating: Double(item.presented.item.rating),
                    solved: context.solvedUnaided,
                    isSRSReview: isReview
                )
            )
            try settings.update { stored in
                stored.puzzleRating = rating.rating
                stored.puzzleRD = rating.deviation
            }
            try metrics.set(MetricKey.puzzleRating.rawValue, value: rating.rating, sampleCount: 1, at: context.now)
            try metrics.set(
                MetricKey.puzzleRatingDeviation.rawValue,
                value: rating.deviation,
                sampleCount: 1,
                at: context.now
            )
        }

        // 3. Latency band median, so the next attempt is graded against a
        //    number that reflects this user rather than a seed.
        if context.attempt.latencyMs > 0 && context.solvedUnaided {
            try metrics.set(
                TrainingMetricKeys.latencyMedian(band: context.band),
                value: LatencyBandMedian.updated(estimate: context.bandMedian, sample: context.attempt.latencyMs),
                sampleCount: (metrics.counter(TrainingMetricKeys.latencyMedian(band: context.band))?.sampleCount ?? 0) + 1,
                at: context.now
            )
        }

        // 4. What a *fresh* puzzle produces: the per-theme success rate rung 2
        //    gates on, and the serve record that keeps the corpus from handing
        //    the same position back next week.
        //
        //    Both are restricted to fresh items, and for the same reason. A
        //    review is the same card returning, so counting it again measures
        //    how often a position has come round rather than how well the theme
        //    is known — and the bias runs the wrong way, because a card the user
        //    keeps failing is scheduled more often than one they have learned,
        //    so the weakest themes collect the most extra attempts and the gate
        //    reads worse the harder the user is working on it. A relearn is a
        //    second look, minutes later, at a position already counted.
        //
        //    Per-theme counts are kept at the curriculum's rating floor because
        //    "70% on forks" and "70% on forks rated 1200+" are different
        //    measurements.
        if case .fresh = item.kind {
            let floor = tuning.curriculum.themeRatingFloor
            if item.presented.item.rating >= floor {
                let theme = item.presented.item.primaryTheme
                try metrics.increment(TrainingMetricKeys.themeAttempts(theme, ratingFloor: floor), at: context.now)
                if context.solvedUnaided {
                    try metrics.increment(TrainingMetricKeys.themeSolves(theme, ratingFloor: floor), at: context.now)
                }
            }
            if let puzzleID = item.presented.item.puzzleID {
                ServedPuzzleHistory.record(puzzleID: puzzleID, metrics: metrics, at: context.now)
            }
        }

        // 5. Clean-retry rate: a relearn item is, by construction, a re-play of
        //    a position failed earlier today.
        if case .relearn = item.kind {
            try metrics.increment(TrainingMetricKeys.cleanRetryAttempts, at: context.now)
            if context.solvedUnaided {
                try metrics.increment(TrainingMetricKeys.cleanRetrySuccesses, at: context.now)
            }
        }

        // 6. The day's loop.
        try dailyLoop.update(day: DailyLoop.dayKey(for: context.now)) { loop in
            loop.puzzlesDone += 1
        }

        return rating
    }

    private nonisolated static func admitCards(
        candidates: [CardCandidate],
        sources: [UUID: PendingCandidate],
        srs: any SRSCardStore,
        metrics: any MetricStore,
        tuning: DomainTuning,
        now: Date
    ) async throws -> Int {
        let dayKey = DailyLoop.dayKey(for: now)
        let createdToday = Int(metrics.value(TrainingMetricKeys.newCardsAdmitted, window: dayKey))

        let admission = CardPolicy.admitNewCards(
            candidates: candidates,
            createdToday: createdToday,
            tuning: tuning.cards
        )

        var created = 0
        for admitted in admission.admitted {
            guard let source = sources[admitted.id] else { continue }
            if let item = source.item {
                guard let puzzleID = item.presented.item.puzzleID else { continue }
                // Reuse an existing card for the same puzzle rather than
                // creating a duplicate scheduling history.
                if try srs.card(puzzleID: puzzleID) != nil { continue }
                try srs.save(
                    SRSCard(
                        kind: SRSCardKind.puzzle.rawValue,
                        puzzleID: puzzleID,
                        fen: item.presented.item.fen,
                        due: now
                    )
                )
                created += 1
            } else if let moment = source.moment {
                let key = PositionKey.make(fen: moment.fen)
                if try srs.card(positionKey: key) != nil { continue }
                try srs.save(
                    SRSCard(
                        kind: SRSCardKind.momentPosition.rawValue,
                        positionKey: key,
                        fen: moment.fen,
                        due: now
                    )
                )
                created += 1
            }
        }

        if created > 0 {
            try metrics.set(
                TrainingMetricKeys.newCardsAdmitted,
                window: dayKey,
                value: Double(createdToday + created),
                sampleCount: createdToday + created,
                at: now
            )
        }
        return created
    }

    private nonisolated static func recordDrillStreak(
        kind: EndgameDrillKind,
        clean: Bool,
        metrics: any MetricStore,
        now: Date
    ) async -> Double {
        let key = kind.streakMetricKey.rawValue
        let current = metrics.value(key)
        let next = clean ? current + 1 : 0
        // `sampleCount` records how many runs have contributed, so the
        // curriculum can tell "streak of 0, never tried" from "streak of 0,
        // failed yesterday".
        let samples = (metrics.counter(key)?.sampleCount ?? 0) + 1
        try? metrics.set(key, value: next, sampleCount: samples, at: now)
        return next
    }
}

// MARK: - Served puzzles

/// The corpus puzzles the user has already been shown.
///
/// Stored in `skillMetrics`, one row per puzzle, for the same reason every other
/// running total is (see `TrainingMetricKeys`): it is a `(key, window) -> value`
/// pair, and a table to hold one date per puzzle would be a schema migration and
/// a CloudKit change to buy nothing. The value is the number of times the puzzle
/// has been served, which makes the write an `increment` and therefore idempotent
/// in the only sense that matters — a second serve moves `updatedAt`, so the
/// puzzle simply becomes the most recent thing in the window.
enum ServedPuzzleHistory {

    /// Namespaced so a reader can tell a serve record from a computed metric at
    /// a glance, and so the prefix scan cannot pick up anything else.
    static let keyPrefix = "puzzle.served."

    /// How many recent serves are held out of the fresh pool.
    ///
    /// A window rather than the whole history, for two reasons. The set becomes
    /// a SQL `IN` list — `PuzzleRepository.puzzles(excluding:)` says as much in
    /// its own documentation — so it has to stay small. And forgetting a puzzle
    /// after several hundred others is the behaviour we want anyway: at that
    /// distance the position is a fresh test of the idea rather than a recall
    /// test of the answer, which is the only reason repeats were a problem.
    static let exclusionWindow = 400

    /// The most recently served puzzles, newest first, capped at `limit`.
    static func recentlyServed(metrics: any MetricStore, limit: Int = exclusionWindow) -> Set<Puzzle.ID> {
        guard let rows = try? metrics.all() else { return [] }
        let recent =
            rows
            .filter { $0.key.hasPrefix(keyPrefix) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
        return Set(recent.map { String($0.key.dropFirst(keyPrefix.count)) })
    }

    /// Records that a puzzle was put in front of the user.
    ///
    /// Called when an item is *finished*, not when the session is assembled: a
    /// queue the user abandons after two puzzles has served two, and burning the
    /// other eight would quietly shrink the corpus for someone who was
    /// interrupted.
    static func record(puzzleID: Puzzle.ID, metrics: any MetricStore, at date: Date) {
        try? metrics.increment(keyPrefix + puzzleID, at: date)
    }
}

// MARK: - Position keys

/// Stable hash used to deduplicate cards for the same position across games.
///
/// FNV-1a over the position-defining part of the FEN. Explicitly **not**
/// Swift's `Hasher`: that is seeded per process, so the same position would
/// produce a different key on every launch and on every device, and this value
/// is stored and synced.
enum PositionKey {

    static func make(fen: String) -> Int64 {
        // Only the four fields that define the position. The halfmove and
        // fullmove clocks are history, not position, and including them would
        // make the same tactic on move 20 and move 40 look like two cards.
        let significant = fen.split(separator: " ").prefix(4).joined(separator: " ")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in significant.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // Shift into the non-negative range: SQLite stores signed integers and a
        // negative key reads as corruption in a SQL shell.
        return Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
    }
}

// MARK: - Moment positions

/// Supplies the solution line for a card backed by a position from the user's
/// own game.
///
/// The `srsCards` row stores the FEN but not the answer — the answer lives on
/// the `Moment` the card was minted from. Rather than duplicate it into a synced
/// column, the session asks for it at load time.
protocol MomentPositionSource: Sendable {
    /// - Returns: The UCI line the user must find, or `nil` when the position
    ///   cannot be resolved (the game was deleted, say), in which case the card
    ///   is skipped for today rather than shown unanswerable.
    func solutionLine(fen: String) throws -> [String]?
}

/// The default: no moment positions resolvable.
struct EmptyMomentPositionSource: MomentPositionSource {
    func solutionLine(fen: String) throws -> [String]? { nil }
}

/// Resolves moment positions by scanning recent games' moments for a matching
/// FEN.
///
/// A scan rather than an index because `MomentRepository` exposes no lookup by
/// position, and adding one would mean changing a package this layer does not
/// own. The cost is bounded and small: it runs once per session load, over at
/// most `gameLimit` games, for at most seven due cards.
struct GameMomentPositionSource: MomentPositionSource {

    private let games: any GameStore
    private let moments: any MomentStore
    private let gameLimit: Int

    init(games: any GameStore, moments: any MomentStore, gameLimit: Int = 50) {
        self.games = games
        self.moments = moments
        self.gameLimit = gameLimit
    }

    func solutionLine(fen: String) throws -> [String]? {
        for game in try games.recent(limit: gameLimit) {
            for moment in try moments.moments(forGame: game.id) where moment.fen == fen {
                let best = moment.bestUCI.trimmingCharacters(in: .whitespaces)
                guard !best.isEmpty else { continue }
                return [best]
            }
        }
        return nil
    }
}
