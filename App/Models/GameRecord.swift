import Database
import Foundation
import TrainingCore

/// A finished game, in the shape persistence needs it.
///
/// `GameSession` is `@MainActor` and full of `ChessKit` value types; the write
/// happens on an actor with no main-actor affinity. This DTO is the boundary:
/// everything crosses it as plain `Sendable` data, so the writer never has to
/// touch — or await — the session.
struct FinishedGameRecord: Sendable {

    struct Move: Sendable {
        var ply: Int
        var san: String
        var uci: String
        var byUser: Bool
        var thinkTimeMs: Int
        var clockAfterMs: Int
        /// Raw value of the `TrainingCore.Habit` a guided-mode prompt asked
        /// about immediately before this move.
        var guidedPromptHabit: String?
        /// Whether the move counted as answering that prompt.
        ///
        /// A habit with no verdict is the deliberate third state: the user asked
        /// to be shown the method, so the move that followed is evidence about
        /// the coach rather than about them. `GameMovePromptLog` drops those
        /// rows from the hit rate instead of counting them as misses.
        var guidedPromptHit: Bool?
        /// The move a second-try catch took back before this one was played,
        /// with the refutation the coach showed and what it would have cost.
        /// See the `v9.secondTryCatch` migration for why it is kept.
        var retractedUCI: String?
        var retractedRefutation: String?
        var retractedDeltaEP: Double?
    }

    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var mode: String
    var userColor: PlayerColor
    var opponentRating: Int
    /// `"1-0"`, `"0-1"` or `"1/2-1/2"`.
    var result: String
    var termination: String
    var pgn: String
    var moves: [Move]
    /// Everything about the opponent and the format that has no column of its
    /// own. Stored as an opaque JSON blob by design so opponent tuning can evolve
    /// without a CloudKit-visible schema migration.
    var opponentParams: OpponentParams
    /// Calibration games feed the rating estimate; the others do not.
    var isRated: Bool
    /// Which K-factor tier the result is worth on the playing ladder, or `nil`
    /// when it must not move the rating at all.
    ///
    /// Deliberately *not* the same bit as ``isRated``. `isRated` says the game
    /// was played under measurement conditions — no coaching, no take-backs —
    /// and the analysis and metric layers already read it that way. Rating
    /// weight says how much evidence about playing strength the result is, and
    /// the two genuinely differ for sparring: sparring is not a measurement, but
    /// it is the only thing most days produce, and a ladder that ignores it is a
    /// number that never moves.
    var ratingWeight: LadderGameMode?
    /// Whether the coach showed the refutation and the move was then taken back.
    ///
    /// Such a game is unrated whatever its weight — see
    /// ``TrainingCore/LadderGame/containedLevel2AssistedRetry``: the result is
    /// partly the engine's, and counting it measures the coach.
    var usedAssistedRetry: Bool = false
    /// How many moves the user took back, by any route — second try at any hint
    /// level, or the undo window before the opponent replies.
    ///
    /// ``usedAssistedRetry`` only catches the one case where the coach drew the
    /// refutation first, and that is the rarest of them. Every blunder over
    /// 0.30 expected points in a sparring game is offered back for free, so a
    /// win after two quietly retracted blunders used to move the rating exactly
    /// as far as a clean one — and the ladder then served opponents the player
    /// could not beat unaided. ``TrainingCore/EloLadder`` halves K per
    /// retraction instead of refusing the game outright: the game was still
    /// played, it is just weaker evidence.
    var retractionCount: Int = 0

    /// The JSON blob written to `games.opponentParams`.
    struct OpponentParams: Sendable, Codable, Equatable {
        var opponentRating: Int
        var baseSeconds: Int
        var incrementSeconds: Int
        var secondTryEnabled: Bool
        var guidedEnabled: Bool

        var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard
                let data = try? encoder.encode(self),
                let text = String(data: data, encoding: .utf8)
            else { return "{}" }
            return text
        }

        static func decode(_ json: String) -> OpponentParams? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(OpponentParams.self, from: data)
        }
    }
}

extension FinishedGameRecord {

    /// The row written to `games`.
    var gameRow: GameRow {
        GameRow(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            mode: mode,
            userColor: userColor.rawValue,
            opponentParams: opponentParams.json,
            opponentRating: opponentRating,
            result: result,
            termination: termination,
            pgn: pgn,
            userAccuracy: nil,
            // Every finished game enters the analysis queue. `AnalysisService`
            // is what moves it out of `pending`.
            analysisState: AnalysisState.pending.rawValue,
            isRated: isRated,
            usedAssistedRetry: usedAssistedRetry
        )
    }

    /// The rows written to `gameMoves`, in board order.
    var moveRows: [GameMoveRow] {
        moves.map { move in
            GameMoveRow(
                gameID: id,
                ply: move.ply,
                san: move.san,
                uci: move.uci,
                classification: nil,
                winPctBefore: nil,
                winPctAfter: nil,
                thinkTimeMs: move.thinkTimeMs,
                guidedPromptHabit: move.guidedPromptHabit,
                guidedPromptHit: move.guidedPromptHit,
                retractedUCI: move.retractedUCI,
                retractedRefutation: move.retractedRefutation,
                retractedDeltaEP: move.retractedDeltaEP
            )
        }
    }

    /// The result as the playing ladder sees it, or `nil` when it must not move
    /// the rating.
    var ladderGame: LadderGame? {
        guard let ratingWeight, let played = GameResult(rawValue: result) else { return nil }
        // `unknown` is the termination `GameSession` writes when the opponent
        // search stopped answering and the game was abandoned where it stood.
        // The stored "1/2-1/2" is a placeholder, not a result: nobody agreed a
        // draw, and feeding it to the ladder would be evidence about a game the
        // player never got to finish.
        guard GameTermination(rawValue: termination) != .unknown else { return nil }

        let outcome: GameOutcome =
            if played == .draw {
                .draw
            } else {
                played.isWin(for: userColor) ? .win : .loss
            }

        return LadderGame(
            opponentRating: Double(opponentRating),
            outcome: outcome,
            mode: ratingWeight,
            containedLevel2AssistedRetry: usedAssistedRetry,
            retractionCount: retractionCount
        )
    }
}

// MARK: - Ladder rating

/// Moves the playing rating after a finished game.
///
/// This is the only writer of `AppSettings.userRating` outside calibration, and
/// it exists because calibration alone left the number frozen: the Profile
/// chart, the curriculum ladder, the opponent ladder and the leak scores all
/// read a rating that could never change once the first-run estimate landed.
///
/// It runs once per finished game, from the same task that saves it, rather than
/// from the metrics recompute — `MetricsService.refresh()` runs on foreground
/// and on every Profile load, and an increment applied there would be applied
/// again on the next launch.
///
/// An actor for the same reason ``GamePersistence`` is one: the repositories
/// underneath are synchronous `Sendable` structs, so this exists to give
/// `GameSession` — which is `@MainActor` — somewhere to `await` that is not the
/// UI thread.
actor LadderRatingWriter {

    /// Counters the K schedule needs that have no column of their own. They are
    /// single numbers keyed by name, which is what `skillMetrics` already is.
    enum Keys {
        static let gamesSinceCalibration = "ladder.gamesSinceCalibration"
        static let driftBoostGamesRemaining = "ladder.driftBoostGamesRemaining"
        static let consecutiveHighDriftChecks = "ladder.consecutiveHighDriftChecks"
        static let consecutiveLowDriftChecks = "ladder.consecutiveLowDriftChecks"
    }

    /// How many recent ladder games the drift check averages over.
    ///
    /// Ten is the window the guard was tuned against: short enough to notice a
    /// player who has genuinely moved, long enough that one hot streak does not
    /// trip it on its own.
    static let driftWindow = 10

    private let settings: any AppSettingsStore
    private let metrics: any MetricStore
    private let games: (any GameStore)?
    private let tuning: DomainTuning

    init(
        settings: any AppSettingsStore,
        metrics: any MetricStore,
        games: (any GameStore)? = nil,
        tuning: DomainTuning = .default
    ) {
        self.settings = settings
        self.metrics = metrics
        self.games = games
        self.tuning = tuning
    }

    /// The shared writer, or `nil` when the database could not be opened.
    static let shared: LadderRatingWriter? = AppDatabase.sharedIfAvailable.map {
        LadderRatingWriter(settings: $0.settings, metrics: $0.metrics, games: $0.games)
    }

    /// Applies one game and returns the new rating, or `nil` when the game did
    /// not count.
    @discardableResult
    func apply(_ record: FinishedGameRecord, at date: Date = Date()) throws -> Double? {
        guard let game = record.ladderGame else { return nil }

        let stored = try settings.current()
        let state = LadderState(
            rating: stored.userRating,
            gamesSinceCalibration: Int(metrics.value(Keys.gamesSinceCalibration)),
            consecutiveHighDriftChecks: Int(metrics.value(Keys.consecutiveHighDriftChecks)),
            consecutiveLowDriftChecks: Int(metrics.value(Keys.consecutiveLowDriftChecks)),
            driftBoostGamesRemaining: Int(metrics.value(Keys.driftBoostGamesRemaining))
        )

        let updated = EloLadder.update(state: state, game: game, tuning: tuning.ladder)
        // An unrated game comes back untouched, counter included. Writing it
        // anyway would advance the K schedule on a game that moved nothing,
        // shortening the high-K window a new user actually needs.
        guard updated != state else { return nil }

        // The guard that catches a rating set to the wrong level in the first
        // place. Without it a genuinely improving player wins every game as the
        // underdog and still crawls up four points at a time — and because the
        // curriculum gates on rating, a rating stuck below the player is not
        // merely slow, it withholds the material they are ready for.
        let next = driftChecked(updated)

        try settings.update { $0.userRating = next.rating }
        try metrics.set(
            Keys.gamesSinceCalibration,
            value: Double(next.gamesSinceCalibration),
            sampleCount: 1,
            at: date
        )
        try metrics.set(
            Keys.driftBoostGamesRemaining,
            value: Double(next.driftBoostGamesRemaining),
            sampleCount: 1,
            at: date
        )
        // The same key the metric recompute writes, from the same source, so the
        // Profile chart moves with the game rather than with the next refresh.
        try metrics.set(MetricKey.ladderRating.rawValue, value: next.rating, sampleCount: 1, at: date)
        // Both streak counters, not just the boost. The guard only fires on two
        // consecutive checks, so a counter that is read but never written can
        // never reach two and the guard can never fire at all.
        try metrics.set(
            Keys.consecutiveHighDriftChecks,
            value: Double(next.consecutiveHighDriftChecks),
            sampleCount: 1,
            at: date
        )
        try metrics.set(
            Keys.consecutiveLowDriftChecks,
            value: Double(next.consecutiveLowDriftChecks),
            sampleCount: 1,
            at: date
        )

        return next.rating
    }

    /// Runs the drift check once the window is full.
    ///
    /// The performance rating is measured over the same population the rating
    /// itself is computed from — `MetricComputer.ladderGame` is the one mapping,
    /// deliberately shared, because a guard that averaged a different set of
    /// games than the rating would be checking the rating against a number it
    /// never came from.
    ///
    /// ## Why assisted-retry games are dropped here
    ///
    /// ``EloLadder/update(state:game:tuning:)`` already refuses to rate a game
    /// where the coach showed the refutation and the move was taken back — see
    /// ``TrainingCore/LadderGame/containedLevel2AssistedRetry``, "a rating that
    /// counts them measures the coach, not the user". `performanceRating` does
    /// not know about the flag, so before this filter existed the same games the
    /// rating declined to use could still trip the guard: a run of coached wins
    /// read as a player performing far above their rating, and the guard's
    /// answer to that is K=40 for the next five games. The rating then moved
    /// four times as fast on evidence it had itself thrown away.
    ///
    /// The fetch is five windows deep rather than three because of that filter.
    /// A fortnight of leaning on take-backs can leave fewer than ten usable
    /// games inside a narrower read, and a guard that quietly stops running is
    /// worse than one that fires late — this is the check that catches a rating
    /// set to the wrong level in the first place.
    private func driftChecked(_ state: LadderState) -> LadderState {
        guard let games else { return state }

        let recent = (try? games.recent(limit: Self.driftWindow * 5)) ?? []
        let ladder = recent
            .compactMap(MetricComputer.ladderGame(for:))
            .filter { !$0.containedLevel2AssistedRetry }
            .prefix(Self.driftWindow)

        guard ladder.count >= Self.driftWindow,
              let performance = EloLadder.performanceRating(games: Array(ladder))
        else { return state }

        return EloLadder.recordDriftCheck(
            state: state,
            performanceRatingLast10: performance,
            tuning: tuning.ladder
        )
    }
}
