//
//  TrainingService.swift
//  ChessCoach
//

import AnalysisKit
import Database
import Foundation
import OSLog
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
            await adopt(loaded, now: now)
        } catch {
            // The raw error is for the log, never for the screen. A user who
            // opens Train and is shown `SQLite error 11: database disk image is
            // malformed` has been handed a fault report instead of a sentence,
            // and the one thing they can actually do about it — close the app
            // and come back — is the thing it does not say.
            AppLog.persistence.error("training session load failed: \(String(describing: error), privacy: .public)")
            phase = .failed("The puzzle database could not be opened. Close the app and open it again.")
        }
    }

    /// Builds and starts the calculation set: a short run of puzzles from a band
    /// above the user, worked slowly.
    ///
    /// A separate entry point rather than a flag on ``startSession(focus:)``
    /// because the two sessions share only the solve surface. This one reads no
    /// due cards, asks no scheduler, admits no new cards and carries no weekly
    /// focus — the week's habit is a bias applied to *recognition* material, and
    /// weighting a calculation band toward one motif would narrow the search the
    /// set exists to make the user do.
    func startCalculationSet() async {
        guard phase != .loading else { return }
        phase = .loading
        // Not the week's focus, and not stale either: the header reads this to
        // decide whether to name a habit, and leaving the last session's focus
        // in place would label a theme-blind set as weighted toward something.
        focus = nil

        let now = clock()
        do {
            let loaded = try await Self.loadCalculationSet(
                corpus: corpus,
                metrics: metrics,
                settings: settings,
                tuning: tuning
            )
            await adopt(loaded, now: now)
        } catch {
            AppLog.persistence.error("calculation set load failed: \(String(describing: error), privacy: .public)")
            phase = .failed("The puzzle database could not be opened. Close the app and open it again.")
        }
    }

    /// Takes ownership of a freshly loaded queue.
    ///
    /// Shared by both entry points so a queue can never be adopted half-reset —
    /// a leftover `failedCardIDs` or `pendingCandidates` from the previous
    /// session would append a retry for a card this queue does not contain, or
    /// admit a card for a puzzle the user answered an hour ago.
    private func adopt(_ loaded: LoadedSession, now: Date) async {
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
        // A floor, not the real reading. The UI calls `startLatencyClock()`
        // when the position becomes solvable and overwrites this; a driver with
        // no UI in front of it — a self-test, a headless run — would otherwise
        // report a latency of zero, which `AutoGrader` reads as `.easy`.
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

    /// Restarts the latency clock for the item on screen.
    ///
    /// See ``PuzzleSessionDriver/markItemShown()`` for why the service cannot
    /// decide this moment for itself: it advances to the next item inside the
    /// call that grades the previous one, long before that position is in front
    /// of anybody.
    func startLatencyClock() {
        itemStartedAt = clock()
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

    /// Drops the same-day retry for a card whose "wrong" move the engine went on
    /// to rate as good as the stored one.
    ///
    /// Only reachable for a position mined from the user's own game, where the
    /// stored answer is whatever the analysis pass liked best rather than the
    /// only move that holds the result — see
    /// ``PuzzleMoveComparison/verdict(answer:played:answerIsForced:)``. The
    /// grade has already been written by then and is left alone: the card is one
    /// the user should see again, and the engine's 40k-node opinion is not
    /// strong enough to overturn a review. Handing the same position back twenty
    /// seconds later is a different matter — the app has just told them their
    /// move was equal, and the only thing a retry can teach there is to produce
    /// the stored move instead of the one the position rates the same.
    func creditEquivalentAnswer(cardID: SRSCard.ID) {
        failedCardIDs.removeAll { $0 == cardID }
        guard retriesAppended else { return }
        // The retries are already in the queue, so the withdrawal has to reach
        // the queue too. Only items the user has not arrived at yet: removing
        // one at or behind the cursor would renumber the set under them.
        var items = session.items
        var index = items.count - 1
        while index > itemIndex {
            if items[index].kind == .relearn(cardID: cardID) { items.remove(at: index) }
            index -= 1
        }
        session.items = items
    }

    private func finishCurrentItem() async {
        guard let item = currentItem, let current = machine else { return }

        let now = clock()
        let latency = itemStartedAt.map { now.timeIntervalSince($0) * 1000 } ?? 0
        // A position mined from the user's own game carries no corpus rating,
        // and grading its latency against band 0 — a seven-second median — made
        // every one of them read as slow. The user's own rating is the nearest
        // honest stand-in for "how hard should this have been for them".
        let ratingForBand = item.presented.item.rating > 0
            ? item.presented.item.rating
            : Int(summary.puzzleRating.rating.rounded())
        let band = TrainingVocabulary.latencyBand(forRating: ratingForBand)
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
        // A missed calculation puzzle is not a candidate. Missing one is the
        // expected outcome — the band is 200 points above the user by
        // construction — so admitting them would spend the whole of
        // `newCardsPerDay` (three, the entire anti-burnout mechanism) on the one
        // set that cannot run out of misses, starving the daily set and the slot
        // `admitCards` holds back for a mistake from the user's own game. An
        // explicit keep is a different act and still admits, which is the only
        // way one of these reaches the deck.
        guard flagged || (!solvedUnaided && !item.isCalculation) else { return }

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
    /// Game mistakes outrank corpus puzzles in `CardPolicy`, but that ordering
    /// only sorts the candidates handed to *one* call, and a day can spend its
    /// cap on puzzles before a game is ever played. `admitCards` therefore keeps
    /// a slot back for a game mistake rather than relying on the ordering; see
    /// the reasoning there.
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
                    // This one is used to *bound a search*, not to weigh a
                    // result, so the sentinel zero a mined position carries has
                    // to be substituted here. Left alone it made the sibling
                    // band `(-100)...100`, which matches no puzzle in the
                    // corpus — so the cards mined from the user's own games,
                    // the ones most worth generalising, could never reach the
                    // ladder's generalisation step at all. The user's own
                    // rating is the nearest honest answer to "how hard should a
                    // comparable puzzle be for them".
                    puzzleRating: item.rating > 0 ? item.rating : userPuzzleRating,
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

        // One slot held back for a gated theme the user has not been measured
        // on yet.
        //
        // Rung 2 needs fifteen fresh attempts at 1200+ on each of five specific
        // themes, and the focus mask that owns 60% of the fresh slots contains
        // none of them — `calcToQuiet` is sacrifices and long mates. So the
        // gate was left to chance: about four random puzzles a day, of which
        // skewers and discovered attacks are a small minority, against a rung
        // whose other requirements are met in weeks. The ring stalled on a
        // sampling artefact rather than on a missing skill.
        //
        // Round-robin by fewest attempts, so the scarcest theme is served
        // first, and only above the floor the gate counts at — a 900-rated fork
        // does not move the number.
        // How far above the curriculum's theme floor the reserved slot may
        // reach when the user's own serving band does not get there. Narrow on
        // purpose: the slot has to be allowed above the band, but only just — a
        // puzzle far above the user is one they fail without learning anything,
        // and the gate counts attempts, not miracles.
        let gatedThemeReach = 100
        var gated: [Puzzle] = []
        let gateWanted = freshSlots - focusThemed.count
        // The reserved slot fires whatever the band says, and that is the whole
        // point of reserving it.
        //
        // It used to be guarded on `band.upperBound >= themeRatingFloor`, on the
        // reasoning that below the floor "the gate is out of reach anyway". The
        // gate is not out of reach — it is *only* reachable through this slot,
        // and the guard was what put it out of reach. `r2.themes` is a REQUIRED
        // rung-2 skill needing 15 attempts per theme on puzzles rated
        // `themeRatingFloor`+ , and every other source of fresh puzzles draws
        // from `puzzleRating ± freshServingBand`. So a user placed on rung 2
        // with a puzzle rating below `floor - band` had no path to a single
        // countable attempt: the five criteria sat unmeasured forever, unmeasured
        // counts as unmet, and **rung 2 could not be passed at all**. Calibration
        // can place exactly that user, because the rung comes from the combined
        // playing-scale estimate and the serving band comes from the Glicko
        // puzzle rating — two different scales, neither aware of the other.
        //
        // Reaching above the band is the correct trade rather than a concession:
        // one puzzle in a set of ten, on a theme the curriculum has explicitly
        // asked the user to demonstrate. The alternative on offer was a rung
        // nobody could leave.
        let gateCeiling = max(band.upperBound, tuning.curriculum.themeRatingFloor + gatedThemeReach)
        if gateWanted > 0,
            let deficient = Self.deficientGatedTheme(metrics: metrics, tuning: tuning.curriculum),
            let puzzleTheme = TrainingVocabulary.puzzleTheme(deficient)
        {
            gated = try corpus.puzzles(
                ratingRange: tuning.curriculum.themeRatingFloor...gateCeiling,
                themes: ThemeMask([puzzleTheme]),
                limit: 1,
                excluding: seenPuzzleIDs
            )
            seenPuzzleIDs.formUnion(gated.map(\.id))
        }

        // Whatever the focus and gate queries could not fill falls through to
        // the general pool, so a thin theme never shrinks the session.
        let generalWanted = freshSlots - focusThemed.count - gated.count
        var general: [Puzzle] = gated
        if generalWanted > 0 {
            general += try corpus.puzzles(
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

    /// Loads the calculation set: fresh puzzles from a band above the user, and
    /// nothing else.
    ///
    /// Deliberately takes neither the SRS store nor the scheduler. That is not a
    /// tidiness argument — it is the guarantee that this path cannot touch the
    /// review queue, stated in the signature where a later change has to notice
    /// it rather than in a comment it can be made to contradict.
    ///
    /// The band comes back empty for a user whose rating has passed the top of
    /// the corpus, and that is allowed to produce an empty set. Widening or
    /// sliding the band to fill it would serve puzzles at or below the user's
    /// own level under the calculation label, which is the substitution the
    /// entry point's copy exists to make impossible.
    private nonisolated static func loadCalculationSet(
        corpus: any PuzzleCorpus,
        metrics: any MetricStore,
        settings: any AppSettingsStore,
        tuning: DomainTuning
    ) async throws -> LoadedSession {

        let stored = try settings.current()
        let rating = GlickoRating(rating: stored.puzzleRating, deviation: stored.puzzleRD)
        let band = TrainingVocabulary.calculationBand(
            userPuzzleRating: Int(stored.puzzleRating.rounded()),
            tuning: tuning.calculation
        )

        // The same exclusion window the daily set uses. A repeat here is worse
        // than a repeat there: four minutes spent recalling an answer is four
        // minutes not spent calculating, which inverts the whole point of the
        // set.
        let seen = ServedPuzzleHistory.recentlyServed(metrics: metrics)
        let wanted = max(0, tuning.calculation.setSize * tuning.calculation.candidateMultiple)

        // Lichess tags a solution of three moves `long` and four or more
        // `veryLong`. That is the corpus's own name for the property this set
        // wants and the only length signal that can ride along with the rating
        // index — the moves themselves are one space-separated column, so
        // solution length is not a predicate.
        var candidates = try corpus.puzzles(
            ratingRange: band,
            themes: ThemeMask([.long, .veryLong]),
            limit: wanted,
            excluding: seen
        )

        // Topped up from the unfiltered band rather than required. A band that
        // holds no long-tagged puzzle is still a band above the user's level,
        // and the length preference must not be allowed to empty a set that the
        // entry point has already counted and priced. `calculationSet` ranks
        // whatever arrives, so the long ones still lead.
        if candidates.count < tuning.calculation.setSize {
            var excluded = seen
            excluded.formUnion(candidates.map(\.id))
            candidates += try corpus.puzzles(
                ratingRange: band,
                themes: .empty,
                limit: wanted - candidates.count,
                excluding: excluded
            )
        }

        return LoadedSession(
            session: SessionAssembler.calculationSet(candidates: candidates, tuning: tuning.calculation),
            rating: rating
        )
    }

    /// The rung-2 theme furthest from being measured, or nil once every one of
    /// them has the attempts the gate needs.
    ///
    /// Deliberately reads the same counters `MetricComputer` gates on, so the
    /// slot stops being reserved the moment the gate can be evaluated.
    private nonisolated static func deficientGatedTheme(
        metrics: any MetricStore,
        tuning: DomainTuning.Curriculum
    ) -> ThemeTag? {
        let floor = tuning.themeRatingFloor
        let counts = tuning.rung2Themes.map { theme in
            (theme, metrics.value(TrainingMetricKeys.themeAttempts(theme, ratingFloor: floor)))
        }
        guard let scarcest = counts.min(by: { $0.1 < $1.1 }),
            scarcest.1 < Double(tuning.themeMinimumAttempts)
        else { return nil }
        return scarcest.0
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
        guard let fen = row.fen, let mined = try momentPositions.minedPosition(fen: fen), !mined.line.isEmpty
        else {
            return nil
        }
        return SolvableItem(
            backing: .momentPosition(momentID: nil),
            fen: fen,
            line: mined.line,
            // The moment's FEN is already the position the user got wrong, so
            // there is no setup move to play.
            opponentMovesFirst: false,
            // Zero is a sentinel, not a guess at difficulty. `persist` gates
            // the Glicko update on `rating > 0`, and rightly: a position from
            // the user's own game has no independent rating, so feeding one in
            // — their own, say — would be updating the rating against itself
            // and dragging it toward whatever it already was. Consumers that
            // need a *band* rather than an opponent strength substitute the
            // user's rating at their own call site; see the latency band in
            // `finishCurrentItem` and the sibling range in `loadSession`.
            rating: 0,
            // The analysis already named the motif — and the value was computed
            // and then dropped here, so every mined card was tagged
            // `middlegame`. That names a phase rather than an idea: it has no
            // noun for the banner, no definition for the summary chip, and it
            // sends the anti-memorisation ladder hunting for a "sibling" that
            // is any middlegame puzzle at all.
            primaryTheme: mined.theme ?? ThemeTag("middlegame")
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
        //
        //    A calculation puzzle counts at full weight, like any other fresh
        //    one. Glicko already prices the difficulty: at +250 the expected
        //    score is low, so a miss costs almost nothing and a solve is worth a
        //    great deal — which is exactly the measurement the raised band is
        //    there to make. Excluding them would throw away the only attempts in
        //    the day that carry real information about the ceiling.
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
        //
        //    The calculation set is excluded from the counters for a third
        //    reason. Its band sits 200 points above the user by construction, so
        //    a miss there is the expected result and says nothing about whether
        //    the theme is known at the user's own level — but the gate would
        //    read it as evidence that it is not, and the gate is *required* for
        //    rung 2. Counting it would mean the ladder went backwards for the
        //    user who did the hardest work of their day, and further backwards
        //    the more of it they did.
        if case .fresh = item.kind {
            let floor = tuning.curriculum.themeRatingFloor
            if !item.isCalculation, item.presented.item.rating >= floor {
                // Credit every gated theme the puzzle genuinely carries, not the
                // single theme `primaryTheme` elects.
                //
                // `primaryTheme` picks one label off a ranked list, for naming a
                // puzzle in copy — one puzzle, one noun. The gate is a different
                // question: it asks how often the user solves positions
                // *containing* a fork, a pin, a skewer, a discovered attack, a
                // back-rank mate. A puzzle honestly carries several of those at
                // once, and Lichess tags them that way.
                //
                // Crediting only the elected theme made the scarcest gates
                // starve. The reserved slot would go and fetch a backRankMate
                // puzzle precisely because that counter was lowest, and then the
                // attempt would be credited to whatever outranked backRankMate
                // in the naming order — so the counter it was fetched to feed
                // did not move, and the next set fetched another one. Round and
                // round, at roughly 2.5x the intended cost, on a gate that is
                // required to leave rung 2.
                let carried = tuning.curriculum.rung2Themes.filter { gatedTheme in
                    guard let puzzleTheme = TrainingVocabulary.puzzleTheme(gatedTheme) else { return false }
                    return item.presented.item.themes.contains(puzzleTheme)
                }
                // A puzzle carrying none of them still counts for the theme it is
                // named by, which is what the pre-gate behaviour was for.
                let credited = carried.isEmpty ? [item.presented.item.primaryTheme] : carried
                for theme in credited {
                    try metrics.increment(TrainingMetricKeys.themeAttempts(theme, ratingFloor: floor), at: context.now)
                    if context.solvedUnaided {
                        try metrics.increment(TrainingMetricKeys.themeSolves(theme, ratingFloor: floor), at: context.now)
                    }
                }
            }
            // The serve record is kept for every fresh item, calculation
            // included: it is what stops the corpus handing the same position
            // back inside the exclusion window, and a position whose answer is
            // remembered is a recognition test — which is the one thing this set
            // must not quietly become.
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

        // 6. The day's loop. A calculation puzzle counts here like any other:
        //    the counter is puzzles *answered*, and a user who spent twelve
        //    minutes on three of them and then found Today unchanged would have
        //    been told the hardest work of their day did not happen.
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

        // A mistake from the user's own game keeps a slot however the day went.
        //
        // `CardPolicy` ranks a game mistake above every corpus puzzle, but that
        // ordering only holds *within one call*, and this is called twice a day
        // from different places: once at the end of a session, once when the
        // analysis pass mines a finished game. Nothing stores
        // `admission.deferred`, so on a day that spent the cap on puzzles first
        // — the "Short on time? 10 puzzles" path, then a game — the three
        // highest-priority cards in the system were deferred to a queue that
        // does not exist and never became cards at all.
        //
        // Spending one slot over the cap is the cheaper error: the cap exists to
        // keep the review queue from growing faster than it can be worked, and a
        // position the user actually got wrong is the last thing that should
        // lose to a corpus puzzle. A cap of zero is an explicit "no new cards"
        // and is still honoured.
        let cap = tuning.cards.newCardsPerDay
        let reservesSlot = cap > 0 && candidates.contains { $0.origin == .gameMistake }
        let budgetSpent = reservesSlot ? min(createdToday, cap - 1) : createdToday

        let admission = CardPolicy.admitNewCards(
            candidates: candidates,
            createdToday: budgetSpent,
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
    /// - Returns: The card, or `nil` when the position cannot be resolved (the
    ///   game was deleted, say), in which case the card is skipped for today
    ///   rather than shown unanswerable.
    func minedPosition(fen: String) throws -> MinedPosition?
}

/// A position from the user's own game, ready to be served.
///
/// More than the answer, because the answer alone is what made these — the most
/// valuable cards in the deck — the worst-explained items in the app. A
/// one-move line has no continuation, and `PuzzleReason` cannot say why a quiet
/// move works without one; a `middlegame` theme has no noun, so the banner fell
/// through to naming the square and the summary chip read `f3`.
struct MinedPosition: Sendable, Hashable {
    /// The move to find, plus the opponent's reply where the analysis stored
    /// one. Two plies at most: the position *is* the moment the user went
    /// wrong, so the card is a single move, and the reply is carried only so
    /// the explanation can answer "and then what?".
    var line: [String]
    /// The motif the analysis named, in the corpus's own vocabulary. Nil where
    /// the line won material by no recognised motif, in which case the caller
    /// keeps the neutral tag rather than inventing one.
    var theme: ThemeTag?
}

/// The default: no moment positions resolvable.
struct EmptyMomentPositionSource: MomentPositionSource {
    func minedPosition(fen: String) throws -> MinedPosition? { nil }
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

    func minedPosition(fen: String) throws -> MinedPosition? {
        for game in try games.recent(limit: gameLimit) {
            for row in try moments.moments(forGame: game.id) where row.fen == fen {
                let best = row.bestUCI.trimmingCharacters(in: .whitespaces)
                guard !best.isEmpty else { continue }
                let analysed = row.decodePayload(as: AnalysisKit.Moment.self)
                return MinedPosition(
                    line: Self.line(best: best, from: analysed),
                    theme: analysed.flatMap(Self.theme(of:))
                )
            }
        }
        return nil
    }

    /// The answer, and the reply the analysis had already found for it.
    ///
    /// One ply of continuation and no more. The whole principal variation would
    /// turn a one-move card into a four-move puzzle, which is a different
    /// exercise from the one the moment justifies; a single reply is what
    /// ``PuzzleReason`` needs to answer the objection the reader is about to
    /// raise, and it costs nothing.
    ///
    /// The PV is used only when its first ply *is* the stored best move. A
    /// payload written before the columns were last touched can disagree, and
    /// the second ply of a different line is not this move's reply.
    private static func line(best: String, from moment: AnalysisKit.Moment?) -> [String] {
        guard let pv = moment?.pvBest, pv.first == best, pv.count >= 2 else { return [best] }
        let reply = pv[1].trimmingCharacters(in: .whitespaces)
        return reply.isEmpty ? [best] : [best, reply]
    }

    /// The analysis's motif as a corpus theme.
    ///
    /// Every mined card used to be tagged `middlegame`, which names a phase
    /// rather than an idea: it has no noun for the banner, no definition for
    /// the summary, and — after two long-interval passes — it sends the
    /// anti-memorisation ladder looking for a "sibling" that is any middlegame
    /// puzzle at all.
    private static func theme(of moment: AnalysisKit.Moment) -> ThemeTag? {
        for tactic in moment.themeTags {
            switch tactic {
            case .fork: return ThemeTag("fork")
            case .pin: return ThemeTag("pin")
            case .skewer: return ThemeTag("skewer")
            case .discoveredAttack: return ThemeTag("discoveredAttack")
            case .backRankMate: return ThemeTag("backRankMate")
            case .removalOfDefender: return ThemeTag("capturingDefender")
            case .trappedPiece: return ThemeTag("trappedPiece")
            // `mateThreat` and `unknownTactic` name no pattern the user could
            // be taught by name, and mapping them to the nearest theme would
            // put a word on screen the position may not support.
            case .mateThreat, .unknownTactic: continue
            }
        }
        return nil
    }
}
