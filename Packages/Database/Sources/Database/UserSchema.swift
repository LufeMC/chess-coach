import Foundation
import SQLiteData

// MARK: - Why these types look the way they do
//
// Every table below is (or will be) replicated through CloudKit, which imposes
// constraints that read as odd if you only think about a single device:
//
//  * **UUID primary keys.** Two devices offline at the same time must be able to
//    create rows that never collide. Autoincrement integers cannot promise that.
//  * **No unique constraints beyond the primary key.** If two devices both
//    create "today's loop" for 2026-08-17, a unique index turns a merge into a
//    hard failure with no correct resolution. Uniqueness is enforced by
//    repository queries instead, which can merge rather than reject.
//  * **Enumerated values are stored as `String`, not as Swift enums.** A device
//    running a newer build may sync a `mode` this build has never heard of.
//    A non-frozen `String` decodes it fine; a Swift enum would fail to decode
//    and drop the record. Typed accessors (``Game/gameMode`` and friends) give
//    call sites the ergonomics without the fragility.
//  * **No CHECK constraints on synced columns.** Same reason: a value that is
//    out of range for this build must still round-trip rather than abort the
//    incoming write. Ranges are enforced on the way in, in the repositories.
//  * **Every column added after v1 needs a default** (see ``UserDatabase``),
//    because older devices will keep inserting rows without it.

// MARK: - Game

@Table("games")
public struct Game: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    /// One of ``GameMode``, stored loosely. See ``gameMode``.
    public var mode: String
    /// One of ``PlayerColor``, stored loosely. See ``color``.
    public var userColor: String
    /// JSON blob describing the opponent personality/engine settings. Opaque to
    /// this package so opponent tuning can evolve without a migration.
    public var opponentParams: String
    public var opponentRating: Int
    /// `"1-0"`, `"0-1"`, `"1/2-1/2"`, or `nil` while in progress.
    public var result: String?
    public var termination: String?
    public var pgn: String
    public var userAccuracy: Double?
    public var analysisState: String
    public var isRated: Bool
    /// The game contained a level-2 assisted retry: the coach showed the move
    /// and the user took the blunder back.
    ///
    /// Stored rather than derived because nothing else in a finished game
    /// records that it happened, and the rating ladder treats such a game as
    /// unrated — the result is partly the coach's. A rating recomputed from
    /// history without this column would disagree with the rating that was
    /// actually applied.
    public var usedAssistedRetry: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        mode: String,
        userColor: String,
        opponentParams: String = "{}",
        opponentRating: Int,
        result: String? = nil,
        termination: String? = nil,
        pgn: String = "",
        userAccuracy: Double? = nil,
        analysisState: String = AnalysisState.pending.rawValue,
        isRated: Bool = true,
        usedAssistedRetry: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.userColor = userColor
        self.opponentParams = opponentParams
        self.opponentRating = opponentRating
        self.result = result
        self.termination = termination
        self.pgn = pgn
        self.userAccuracy = userAccuracy
        self.analysisState = analysisState
        self.isRated = isRated
        self.usedAssistedRetry = usedAssistedRetry
    }
}

extension Game {
    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        mode: GameMode,
        userColor: PlayerColor,
        opponentParams: String = "{}",
        opponentRating: Int,
        result: String? = nil,
        termination: String? = nil,
        pgn: String = "",
        userAccuracy: Double? = nil,
        analysisState: AnalysisState = .pending,
        isRated: Bool = true,
        usedAssistedRetry: Bool = false
    ) {
        self.init(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            mode: mode.rawValue,
            userColor: userColor.rawValue,
            opponentParams: opponentParams,
            opponentRating: opponentRating,
            result: result,
            termination: termination,
            pgn: pgn,
            userAccuracy: userAccuracy,
            analysisState: analysisState.rawValue,
            isRated: isRated,
            usedAssistedRetry: usedAssistedRetry
        )
    }

    /// `nil` when a newer build wrote a mode this build does not know.
    public var gameMode: GameMode? { GameMode(rawValue: mode) }
    public var color: PlayerColor? { PlayerColor(rawValue: userColor) }
    public var analysis: AnalysisState? { AnalysisState(rawValue: analysisState) }
    public var isFinished: Bool { endedAt != nil }
}

// MARK: - GameMove

@Table("gameMoves")
public struct GameMove: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var gameID: Game.ID
    /// Half-move number, 1-based.
    public var ply: Int
    public var san: String
    public var uci: String
    /// `"best"`, `"inaccuracy"`, `"mistake"`, `"blunder"`, … or `nil` until the
    /// game has been analysed.
    public var classification: String?
    public var winPctBefore: Double?
    public var winPctAfter: Double?
    public var thinkTimeMs: Int
    /// Lichess move accuracy (0...100), user moves only.
    ///
    /// Recomputable from the two win percentages, and stored anyway: the formula
    /// is only correct when both of them are mover-relative, so every reader that
    /// re-derived it would have to re-derive that contract too. The game accuracy
    /// in ``Game/userAccuracy`` is built from these, and a review screen that
    /// wants a per-move number should not have to re-open the analysis layer to
    /// get one.
    public var accuracy: Double?
    /// Raw value of the `TrainingCore.Habit` a guided-mode prompt asked about
    /// immediately before this move, or `nil` when the player was not interrupted.
    ///
    /// Nothing else records that a prompt happened: the pause is long over by the
    /// time the game is written. It matters afterwards because erring right after
    /// being asked about that exact idea is independent evidence the lesson has
    /// not landed, which is what the moment scorer weights.
    public var guidedPromptHabit: String?
    /// Whether the move that followed the prompt counted as answering it.
    ///
    /// Stored with the habit rather than left for a later migration: the
    /// curriculum gates on a *hit rate*, so a stretch of games carrying prompts
    /// with no verdict would be indistinguishable from a stretch of misses.
    public var guidedPromptHit: Bool?

    public init(
        id: UUID = UUID(),
        gameID: Game.ID,
        ply: Int,
        san: String,
        uci: String,
        classification: String? = nil,
        winPctBefore: Double? = nil,
        winPctAfter: Double? = nil,
        thinkTimeMs: Int = 0,
        accuracy: Double? = nil,
        guidedPromptHabit: String? = nil,
        guidedPromptHit: Bool? = nil
    ) {
        self.id = id
        self.gameID = gameID
        self.ply = ply
        self.san = san
        self.uci = uci
        self.classification = classification
        self.winPctBefore = winPctBefore
        self.winPctAfter = winPctAfter
        self.thinkTimeMs = thinkTimeMs
        self.accuracy = accuracy
        self.guidedPromptHabit = guidedPromptHabit
        self.guidedPromptHit = guidedPromptHit
    }
}

// MARK: - Moment

/// A coachable position pulled out of a game: a blunder, a missed tactic, a
/// good decision worth reinforcing.
@Table("moments")
public struct Moment: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var gameID: Game.ID
    public var ply: Int
    public var fen: String
    public var kind: String
    /// Why the moment happened, e.g. `"missedFork"`.
    public var causeTag: String
    /// Which step of the training loop it belongs to.
    public var stepTag: String
    /// JSON array of modifier strings. Free-form so the coaching taxonomy can
    /// grow without a schema migration.
    public var modifiers: String
    public var playedSAN: String
    public var playedUCI: String
    public var bestSAN: String
    public var bestUCI: String
    /// Expected-points swing caused by the played move.
    public var deltaEP: Double
    /// Ranking score used to pick which moments to surface.
    public var score: Double
    public var coachText: String?
    public var status: String
    public var createdAt: Date
    /// The whole analysis moment, as JSON.
    ///
    /// The columns above are a *projection*: enough to list, sort and filter
    /// moments, and nothing more. A moment also carries its principal variation,
    /// the refutation of the move played, an alternative line, theme tags, win
    /// percentages and a judgment — and a review screen that cannot show the
    /// refutation line is not a review screen. Modelling each of those as a column
    /// would mean a CloudKit-visible migration every time the coaching taxonomy
    /// gains a field, so the producing layer writes the complete value here
    /// instead, exactly as ``Game/opponentParams`` does for opponent tuning.
    ///
    /// Opaque to this package on purpose — the vocabulary belongs to the analysis
    /// layer. Empty for a row written before the column existed, and
    /// ``decodePayload(as:)`` answers `nil` rather than throwing when a payload
    /// from a newer build cannot be decoded, so the worst case is a review that
    /// falls back to the flat columns rather than a moment that will not open.
    ///
    /// One blob rather than a dozen columns is also the right *sync* shape: a
    /// moment is produced atomically by one analysis pass, and per-column
    /// last-write-wins across two devices could otherwise stitch half of one pass
    /// onto half of another and call the result a moment.
    public var payload: String
    /// Whether this moment earned a spaced-repetition card.
    ///
    /// A real column rather than a field inside ``payload`` because it is a query
    /// predicate: the scheduler asks "which moments can become cards" and must not
    /// have to decode every moment ever recorded to find out. It is also not
    /// recoverable from the other columns — eligibility is decided from the
    /// solution length, the criticality gap and the cause tag, and two of those
    /// three are gone by the time a card comes due.
    public var srsEligible: Bool

    public init(
        id: UUID = UUID(),
        gameID: Game.ID,
        ply: Int,
        fen: String,
        kind: String,
        causeTag: String,
        stepTag: String,
        modifiers: String = "[]",
        playedSAN: String,
        playedUCI: String,
        bestSAN: String,
        bestUCI: String,
        deltaEP: Double,
        score: Double,
        coachText: String? = nil,
        status: String = MomentStatus.new.rawValue,
        createdAt: Date = Date(),
        payload: String = "",
        srsEligible: Bool = false
    ) {
        self.id = id
        self.gameID = gameID
        self.ply = ply
        self.fen = fen
        self.kind = kind
        self.causeTag = causeTag
        self.stepTag = stepTag
        self.modifiers = modifiers
        self.playedSAN = playedSAN
        self.playedUCI = playedUCI
        self.bestSAN = bestSAN
        self.bestUCI = bestUCI
        self.deltaEP = deltaEP
        self.score = score
        self.coachText = coachText
        self.status = status
        self.createdAt = createdAt
        self.payload = payload
        self.srsEligible = srsEligible
    }
}

extension Moment {
    public var momentStatus: MomentStatus? { MomentStatus(rawValue: status) }

    /// Decoded ``modifiers``. Malformed JSON yields an empty list rather than
    /// throwing — a bad modifier list must not make a moment unreadable.
    public var modifierList: [String] {
        guard
            let data = modifiers.data(using: .utf8),
            let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    public static func encodeModifiers(_ modifiers: [String]) -> String {
        guard
            let data = try? JSONEncoder().encode(modifiers),
            let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Decodes ``payload`` back into whatever value produced it.
    ///
    /// Generic because this package must not know the analysis vocabulary — see
    /// ``payload``. `nil` covers every way the detail can be unavailable (no
    /// payload, malformed JSON, a shape written by a build that knows a tag this
    /// one does not), and they all have the same answer at the call site: show
    /// what the flat columns say.
    public func decodePayload<T: Decodable>(as type: T.Type = T.self) -> T? {
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Encodes a value for ``payload``, or `""` if it cannot be encoded — a
    /// moment with no detail is still worth storing.
    ///
    /// Keys are sorted so that re-running analysis over an unchanged game
    /// produces a byte-identical blob. Without that, every re-analysis would look
    /// like an edit to the sync engine and push a record for a moment nothing
    /// about had actually changed.
    public static func encodePayload(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(value),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}

// MARK: - SRSCard

/// A spaced-repetition card. FSRS parameters live here directly; the scheduler
/// itself lives outside this package.
@Table("srsCards")
public struct SRSCard: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// ``SRSCardKind``, stored loosely.
    public var kind: String
    /// Set when ``kind`` is `puzzle`: the Lichess puzzle ID.
    public var puzzleID: String?
    /// Set when ``kind`` is `momentPosition`: a Zobrist-style position hash used
    /// to deduplicate cards for the same position across games.
    public var positionKey: Int64?
    public var fen: String?
    public var due: Date
    public var stability: Double
    public var difficulty: Double
    /// FSRS state: `"new"`, `"learning"`, `"review"`, `"relearning"`.
    public var state: String
    public var reps: Int
    public var lapses: Int
    public var lastReview: Date?

    public init(
        id: UUID = UUID(),
        kind: String,
        puzzleID: String? = nil,
        positionKey: Int64? = nil,
        fen: String? = nil,
        due: Date = Date(),
        stability: Double = 0,
        difficulty: Double = 0,
        state: String = SRSState.new.rawValue,
        reps: Int = 0,
        lapses: Int = 0,
        lastReview: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.puzzleID = puzzleID
        self.positionKey = positionKey
        self.fen = fen
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
        self.state = state
        self.reps = reps
        self.lapses = lapses
        self.lastReview = lastReview
    }
}

extension SRSCard {
    public var cardKind: SRSCardKind? { SRSCardKind(rawValue: kind) }
    public var srsState: SRSState? { SRSState(rawValue: state) }
}

// MARK: - ReviewLog

@Table("reviewLogs")
public struct ReviewLog: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var cardID: SRSCard.ID
    public var reviewedAt: Date
    /// 1 = again, 2 = hard, 3 = good, 4 = easy. Clamped by
    /// ``SRSRepository/logReview(_:)`` rather than by a CHECK constraint, so a
    /// record from a future build with a wider scale still syncs in.
    public var rating: Int
    public var stateBefore: String
    public var elapsedDays: Double
    public var scheduledDays: Double
    public var durationMs: Int

    public init(
        id: UUID = UUID(),
        cardID: SRSCard.ID,
        reviewedAt: Date = Date(),
        rating: Int,
        stateBefore: String,
        elapsedDays: Double = 0,
        scheduledDays: Double = 0,
        durationMs: Int = 0
    ) {
        self.id = id
        self.cardID = cardID
        self.reviewedAt = reviewedAt
        self.rating = rating
        self.stateBefore = stateBefore
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.durationMs = durationMs
    }
}

// MARK: - SkillMetric

/// A deliberately generic key/value metric.
///
/// Domain metrics ("tactics accuracy in the last 20 games", "endgame conversion
/// rate") change constantly as the coaching model is tuned. Modelling each as a
/// column would mean a schema migration — and a CloudKit-compatible one — every
/// time. A `(key, window)` pair sidesteps that entirely.
@Table("skillMetrics")
public struct SkillMetric: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// e.g. `"accuracy.tactics"`.
    public var key: String
    /// e.g. `"last20"`, `"allTime"`, `"2026-W33"`.
    public var window: String
    public var value: Double
    public var sampleCount: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        window: String,
        value: Double,
        sampleCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.window = window
        self.value = value
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }
}

// MARK: - MetricSample

/// One observation of a metric, kept forever.
///
/// ``SkillMetric`` answers "what is it *now*": one row per `(key, window)`, and
/// every write destroys the number it replaces. That is the right shape for a
/// curriculum gate, which only ever asks whether the current value clears a
/// threshold, and the wrong shape for the one thing this app exists to show —
/// a rating moving over a year. The two cannot share a row, so history gets its
/// own table.
///
/// Append-only. Rows are inserted, never edited, and the only deletion is the
/// duplicate convergence in `MetricsRepository.recordSample`.
///
/// Keyed by the same `(key, window)` vocabulary as ``SkillMetric`` rather than
/// by a column per plotted quantity, for the reason given there: a `ratings`
/// table with a `puzzleRating` column would need a CloudKit-visible migration
/// every time the chart learned to plot something new.
@Table("metricSamples")
public struct MetricSample: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Matches ``SkillMetric/key``, e.g. `"ladder.rating"`.
    public var key: String
    /// Matches ``SkillMetric/window``, e.g. `"allTime"`.
    public var window: String
    /// `"YYYY-MM-DD"` in the user's local calendar, formatted by
    /// ``DailyLoop/dayKey(for:calendar:)``.
    ///
    /// The coalescing bucket, and the reason opening Profile fifty times in an
    /// afternoon does not write fifty identical points. Stored rather than
    /// derived from ``recordedAt`` on read, so the de-duplicating lookup hits an
    /// index instead of scanning every sample ever taken, and so the bucket a
    /// row was filed under cannot move when the device changes time zone.
    public var day: String
    public var value: Double
    /// When the value this row records was measured.
    ///
    /// Not "when the row was written". A rating that moved is stamped with the
    /// end of the game that moved it, which is the only timestamp that puts the
    /// point on the day the user remembers playing rather than on the day they
    /// next opened the app.
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        window: String,
        day: String,
        value: Double,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.window = window
        self.day = day
        self.value = value
        self.recordedAt = recordedAt
    }
}

// MARK: - DailyLoop

/// One day's progress through the train/play/review loop.
@Table("dailyLoops")
public struct DailyLoop: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// `"YYYY-MM-DD"` in the user's local calendar. Text rather than a `Date`
    /// so that "which day was this" cannot drift with time zone changes.
    public var day: String
    public var gamePlayed: Bool
    public var momentsReviewed: Int
    public var puzzlesDone: Int
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        day: String,
        gamePlayed: Bool = false,
        momentsReviewed: Int = 0,
        puzzlesDone: Int = 0,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.day = day
        self.gamePlayed = gamePlayed
        self.momentsReviewed = momentsReviewed
        self.puzzlesDone = puzzlesDone
        self.completedAt = completedAt
    }
}

extension DailyLoop {
    /// Formats a date as the `day` key. Fixed to POSIX/Gregorian so the key is
    /// stable regardless of the user's locale settings.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        var components = calendar
        components.locale = Locale(identifier: "en_US_POSIX")
        let parts = components.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - AppSettings

@Table("appSettings")
public struct AppSettings: Hashable, Identifiable, Sendable {
    /// There is exactly one settings row, and it uses a **fixed** UUID
    /// (``singletonID``).
    ///
    /// If each device minted its own ID, every device would sync its own
    /// settings row and the user would end up with N rows and no way to pick a
    /// winner. Sharing one ID makes CloudKit's per-column last-write-wins merge
    /// do exactly the right thing: the most recently changed setting wins,
    /// field by field.
    public var id: UUID
    /// Read by nothing.
    ///
    /// Coaching notes are derived on this device from analysis the app has
    /// already run, so there is no model to choose and no thinking budget to
    /// spend. The columns stay because this row syncs: dropping a column is a
    /// schema change every device has to agree on before it can read the row
    /// again, and two unread strings are cheaper than that agreement.
    public var claudeModel: String
    public var effort: String
    public var boardTheme: String
    public var pieceSet: String
    public var soundOn: Bool
    public var hapticsOn: Bool
    public var userRating: Double
    public var puzzleRating: Double
    public var puzzleRD: Double
    public var currentRung: Int
    public var weeklyFocusHabit: String?

    /// The one and only settings row's primary key.
    public static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public init(
        id: UUID = AppSettings.singletonID,
        claudeModel: String = "claude-opus-5",
        effort: String = "medium",
        boardTheme: String = "classic",
        pieceSet: String = "staunty",
        soundOn: Bool = true,
        hapticsOn: Bool = true,
        userRating: Double = 1100,
        puzzleRating: Double = 1000,
        puzzleRD: Double = 350,
        currentRung: Int = 1,
        weeklyFocusHabit: String? = nil
    ) {
        self.id = id
        self.claudeModel = claudeModel
        self.effort = effort
        self.boardTheme = boardTheme
        self.pieceSet = pieceSet
        self.soundOn = soundOn
        self.hapticsOn = hapticsOn
        self.userRating = userRating
        self.puzzleRating = puzzleRating
        self.puzzleRD = puzzleRD
        self.currentRung = currentRung
        self.weeklyFocusHabit = weeklyFocusHabit
    }
}

// MARK: - Local-only tables

/// Engine evaluations for every ply of a game.
///
/// **Not synced.** This is by far the bulkiest table (two principal variations
/// per ply, for every game ever played) and it is entirely reproducible by
/// re-running analysis. Pushing it to CloudKit would burn the user's quota to
/// store a cache.
@Table("plyEvals")
public struct PlyEval: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var gameID: Game.ID
    public var ply: Int
    public var pv1Cp: Int?
    public var pv1Mate: Int?
    /// Space-separated UCI principal variation.
    public var pv1: String
    public var pv2Cp: Int?
    public var pv2Mate: Int?
    public var pv2: String
    public var nodes: Int
    public var depth: Int

    public init(
        id: UUID = UUID(),
        gameID: Game.ID,
        ply: Int,
        pv1Cp: Int? = nil,
        pv1Mate: Int? = nil,
        pv1: String = "",
        pv2Cp: Int? = nil,
        pv2Mate: Int? = nil,
        pv2: String = "",
        nodes: Int = 0,
        depth: Int = 0
    ) {
        self.id = id
        self.gameID = gameID
        self.ply = ply
        self.pv1Cp = pv1Cp
        self.pv1Mate = pv1Mate
        self.pv1 = pv1
        self.pv2Cp = pv2Cp
        self.pv2Mate = pv2Mate
        self.pv2 = pv2
        self.nodes = nodes
        self.depth = depth
    }
}

/// Measured engine throughput for *this* device.
///
/// **Not synced,** and must not be: an iPhone 12's node budget is actively wrong
/// for an M4 iPad. Each device calibrates itself.
@Table("deviceCalibrations")
public struct DeviceCalibration: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var benchNps: Int
    public var nodeBudget: Int
    public var threads: Int
    public var hashMB: Int
    public var calibratedAt: Date

    public init(
        id: UUID = UUID(),
        benchNps: Int,
        nodeBudget: Int,
        threads: Int,
        hashMB: Int,
        calibratedAt: Date = Date()
    ) {
        self.id = id
        self.benchNps = benchNps
        self.nodeBudget = nodeBudget
        self.threads = threads
        self.hashMB = hashMB
        self.calibratedAt = calibratedAt
    }
}


// MARK: - Calibration draft

/// A calibration that has been started but not finished.
///
/// Exactly one row, keyed by ``singletonID``, deleted the moment calibration
/// completes — so this table is empty for all but the first few minutes of the
/// app's life. The measurement itself lives in ``payload`` as an opaque blob
/// written and read by the calibration flow: its shape changes whenever that
/// flow changes, and a column per field would mean a migration each time.
@Table("calibrationDrafts")
public struct CalibrationDraft: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// JSON, owned entirely by the calibration flow.
    public var payload: String
    public var updatedAt: Date

    public static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    public init(
        id: UUID = CalibrationDraft.singletonID,
        payload: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.payload = payload
        self.updatedAt = updatedAt
    }
}
