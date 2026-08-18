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
        isRated: Bool = true
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
        isRated: Bool = true
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
            isRated: isRated
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

    public init(
        id: UUID = UUID(),
        gameID: Game.ID,
        ply: Int,
        san: String,
        uci: String,
        classification: String? = nil,
        winPctBefore: Double? = nil,
        winPctAfter: Double? = nil,
        thinkTimeMs: Int = 0
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
        createdAt: Date = Date()
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
        pieceSet: String = "cburnett",
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
