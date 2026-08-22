//
//  MetricComputer.swift
//  ChessCoach
//

import AnalysisKit
import ChessKit
import Database
import EngineKit
import Foundation
import TrainingCore

// MARK: - Inputs

/// One analysed game, with everything the metrics are derived from.
///
/// A value type rather than a query, so the whole metric layer can be tested
/// from fixtures with no database and no engine.
struct AnalysedGame: Sendable {
    var game: Database.Game
    /// In board order.
    var moves: [GameMove]
    var moments: [Database.Moment]
    /// Engine evaluation per ply, in board order.
    var evals: [PlyEval]
    var guidedPrompts: [GuidedPromptRecord]

    init(
        game: Database.Game,
        moves: [GameMove] = [],
        moments: [Database.Moment] = [],
        evals: [PlyEval] = [],
        guidedPrompts: [GuidedPromptRecord] = []
    ) {
        self.game = game
        self.moves = moves
        self.moments = moments
        self.evals = evals
        self.guidedPrompts = guidedPrompts
    }
}

/// The lifetime counters the training loop maintains, as read back out of the
/// metrics table.
struct MetricCounters: Sendable {
    var puzzleRating: Double = DomainTuning.default.puzzleRating.startingRating
    var puzzleDeviation: Double = DomainTuning.default.puzzleRating.startingDeviation
    var ladderRating: Double = 1_100
    /// Clean-run streak and how many runs have been recorded, per drill family.
    var drillStreaks: [EndgameDrillKind: MetricValue] = [:]
    /// Attempts and solves per theme, at the curriculum's rating floor.
    var themeAttempts: [ThemeTag: Double] = [:]
    var themeSolves: [ThemeTag: Double] = [:]
    var cleanRetryAttempts: Double = 0
    var cleanRetrySuccesses: Double = 0

    init() {}
}

// MARK: - Per-game statistics

/// Everything one game contributes, computed once and then summed over whatever
/// window a metric asks for.
///
/// Splitting it this way matters: the curriculum asks for the same underlying
/// counts over four different windows (8, 10, 12 and 20 games), and recomputing
/// a full board replay per window would be four times the work for identical
/// numbers.
struct GameStatistics: Sendable {

    var userMoves = 0
    /// Moment cause tag → count, already filtered by any per-metric threshold.
    var causeCounts: [String: Int] = [:]
    var blunders = 0

    var openingCompositePassed = false
    var openingAccuracySum = 0.0
    var openingAccuracyCount = 0
    var openingMistakes = 0

    var middlegameNonCriticalAccuracySum = 0.0
    var middlegameNonCriticalAccuracyCount = 0

    var criticalMoments = 0
    var criticalHits = 0
    var impulseAtCritical = 0
    var criticalThinkMs = 0.0
    var criticalThinkCount = 0
    var normalThinkMs = 0.0
    var normalThinkCount = 0

    var reachedWinning = false
    var wonFromWinning = false
    var advantageSlips = 0

    var endedInClockPressure = false

    var wasRookEnding = false
    var rookEndingResultFlipped = false

    var ladderGame: LadderGame?
    var guidedPrompts: [GuidedPromptRecord] = []

    init() {}
}

// MARK: - Computer

/// Turns stored games, moments, evaluations and counters into the metric values
/// the curriculum gates on.
///
/// ## What is and is not computed
///
/// Every metric the ladder names is listed in ``unsupportedMetrics`` or produced
/// here. A metric that has no data source is deliberately *not written* rather
/// than written as zero: `Skill.evaluate(in:)` reports a missing value as
/// **unmeasured**, which the UI shows as "keep playing", whereas a fabricated
/// zero would show as a failure the user cannot act on.
enum MetricComputer {

    /// Metrics the ladder names that this build cannot derive.
    ///
    /// - `prophylactic.findRate` — needs a detector that enumerates the
    ///   prophylactic moves that *were* available, which the analysis pass does
    ///   not currently emit. Nothing in the stored data distinguishes "there was
    ///   no prophylactic move" from "there was one and it was missed".
    /// A criterion on one of these is dropped before the ladder is drawn — see
    /// `CurriculumLadderState` — because a row that can never tick is a promise
    /// the build cannot keep.
    static let unsupportedMetrics: Set<String> = [
        MetricKey.prophylacticFindRate.rawValue
    ]

    /// Expected-points loss equivalent to the curriculum's hanging-piece
    /// centipawn threshold.
    ///
    /// Moments store `deltaEP`, and the curriculum states the threshold in
    /// centipawns. Converting once, here, through the same win-percentage curve
    /// the rest of the app uses keeps the two in step if either moves.
    static func hangingPieceEPThreshold(tuning: DomainTuning.Curriculum) -> Double {
        let level = EvalMath.expectedPoints(EvalMath.winPercent(cp: 0))
        let dropped = EvalMath.expectedPoints(EvalMath.winPercent(cp: -tuning.hangingPieceThresholdCentipawns))
        return level - dropped
    }

    // MARK: Entry point

    /// - Parameter games: Most recent first.
    static func compute(
        games: [AnalysedGame],
        counters: MetricCounters,
        ladder: [Rung] = Curriculum.default,
        tuning: DomainTuning = .default
    ) -> [MetricAddress: MetricValue] {

        let statistics = games.map { Self.statistics(for: $0, tuning: tuning) }
        var result: [MetricAddress: MetricValue] = [:]

        for window in windows(in: ladder) {
            switch window {
            case let .lastGames(count):
                let slice = Array(statistics.prefix(count))
                merge(gameMetrics(slice, window: window, tuning: tuning), into: &result)
                // Prompt metrics get the full list, not the slice: their window
                // is counted in guided games. See `guidedPromptMetrics`.
                merge(guidedPromptMetrics(statistics, window: window, games: count), into: &result)
            case .lastDays, .allTime:
                break
            }
        }

        merge(lifetimeMetrics(counters: counters, ladder: ladder, tuning: tuning), into: &result)

        // The clean-retry rate is asked for over a game window, but retries are
        // a *session* event with no game to attribute them to. The lifetime
        // value is written at the requested address rather than left blank: it
        // is a real measurement over a different window, and withholding it
        // would permanently block a required rung-1 skill.
        for address in addresses(in: ladder) where address.key == .cleanRetryRate {
            guard counters.cleanRetryAttempts > 0 else { continue }
            result[address] = MetricValue(
                value: counters.cleanRetrySuccesses / counters.cleanRetryAttempts,
                sampleCount: Int(counters.cleanRetryAttempts)
            )
        }

        return result
    }

    private static func merge(
        _ values: [MetricAddress: MetricValue],
        into result: inout [MetricAddress: MetricValue]
    ) {
        for (address, value) in values { result[address] = value }
    }

    /// Every `(key, window)` the ladder references.
    static func addresses(in ladder: [Rung]) -> [MetricAddress] {
        ladder
            .flatMap(\.skills)
            .flatMap(\.criteria)
            .map { MetricAddress(key: $0.metricKey, window: $0.window) }
    }

    static func windows(in ladder: [Rung]) -> [MetricWindow] {
        var seen: [MetricWindow] = []
        for address in addresses(in: ladder) where !seen.contains(address.window) {
            seen.append(address.window)
        }
        return seen
    }

    // MARK: Game-window metrics

    private static func gameMetrics(
        _ statistics: [GameStatistics],
        window: MetricWindow,
        tuning: DomainTuning
    ) -> [MetricAddress: MetricValue] {
        guard !statistics.isEmpty else { return [:] }

        var result: [MetricAddress: MetricValue] = [:]
        func put(_ key: MetricKey, _ value: Double, _ samples: Int) {
            guard !unsupportedMetrics.contains(key.rawValue), samples > 0 else { return }
            result[MetricAddress(key: key, window: window)] = MetricValue(value: value, sampleCount: samples)
        }

        let userMoves = statistics.reduce(0) { $0 + $1.userMoves }
        let games = statistics.count

        func per100(_ causes: [AnalysisKit.CauseTag]) -> Double {
            let raw = causes.reduce(0) { total, cause in
                total + statistics.reduce(0) { $0 + ($1.causeCounts[cause.rawValue] ?? 0) }
            }
            return userMoves > 0 ? Double(raw) / Double(userMoves) * 100 : 0
        }

        put(.hangingPiecePer100, per100([.hungMovedPiece, .hungLeftPiece]), userMoves)
        put(.ignoredThreatPer100, per100([.missedNewThreat, .ignoredStandingThreat]), userMoves)
        // Both halves of the missed-tactic detector: the user either calculated
        // it and got it wrong, or never looked. Same skill, same metric.
        put(.missedTacticPer100, per100([.miscalculatedTactic, .missedForcingIdea]), userMoves)
        put(.allowedDeepTacticPer100, per100([.allowedDeepTactic]), userMoves)
        put(.missedQuietMovePer100, per100([.forcingBias]), userMoves)

        let blunders = statistics.reduce(0) { $0 + $1.blunders }
        put(.blundersPer100, userMoves > 0 ? Double(blunders) / Double(userMoves) * 100 : 0, userMoves)

        // Opening.
        let composites = statistics.filter(\.openingCompositePassed).count
        put(.openingCompositeRate, Double(composites) / Double(games), games)

        let openingAccuracyCount = statistics.reduce(0) { $0 + $1.openingAccuracyCount }
        let openingAccuracySum = statistics.reduce(0.0) { $0 + $1.openingAccuracySum }
        put(.openingAccuracy, openingAccuracyCount > 0 ? openingAccuracySum / Double(openingAccuracyCount) : 0, openingAccuracyCount)

        let openingMistakes = statistics.reduce(0) { $0 + $1.openingMistakes }
        put(.openingMistakesPerGame, Double(openingMistakes) / Double(games), games)

        // Middlegame quality.
        let middleCount = statistics.reduce(0) { $0 + $1.middlegameNonCriticalAccuracyCount }
        let middleSum = statistics.reduce(0.0) { $0 + $1.middlegameNonCriticalAccuracySum }
        put(.middlegameNonCriticalAccuracy, middleCount > 0 ? middleSum / Double(middleCount) : 0, middleCount)

        let critical = statistics.reduce(0) { $0 + $1.criticalMoments }
        let criticalHits = statistics.reduce(0) { $0 + $1.criticalHits }
        put(.criticalMomentHitRate, critical > 0 ? Double(criticalHits) / Double(critical) : 0, critical)

        // Clock.
        let pressure = statistics.filter(\.endedInClockPressure).count
        put(.clockPressureGameRate, Double(pressure) / Double(games), games)

        let impulses = statistics.reduce(0) { $0 + $1.impulseAtCritical }
        put(.impulseAtCriticalCount, Double(impulses), games)

        let criticalThinkCount = statistics.reduce(0) { $0 + $1.criticalThinkCount }
        let normalThinkCount = statistics.reduce(0) { $0 + $1.normalThinkCount }
        if criticalThinkCount > 0, normalThinkCount > 0 {
            let criticalMean = statistics.reduce(0.0) { $0 + $1.criticalThinkMs } / Double(criticalThinkCount)
            let normalMean = statistics.reduce(0.0) { $0 + $1.normalThinkMs } / Double(normalThinkCount)
            if normalMean > 0 {
                put(.criticalToNormalThinkTimeRatio, criticalMean / normalMean, criticalThinkCount)
            }
        }

        // Conversion.
        let winning = statistics.filter(\.reachedWinning)
        if !winning.isEmpty {
            let converted = winning.filter(\.wonFromWinning).count
            put(.winRateFromWinningPosition, Double(converted) / Double(winning.count), winning.count)
            let slips = winning.reduce(0) { $0 + $1.advantageSlips }
            put(.advantageSlipsPerWinningGame, Double(slips) / Double(winning.count), winning.count)
        }

        // Rook endings, normalised per eight endings as the key's name says.
        let rookEndings = statistics.filter(\.wasRookEnding)
        if !rookEndings.isEmpty {
            let flips = rookEndings.filter(\.rookEndingResultFlipped).count
            put(.rookEndingResultFlipsPer8, Double(flips) / Double(rookEndings.count) * 8, rookEndings.count)
        }

        // Playing ladder.
        let ladderGames = statistics.compactMap(\.ladderGame)
        if let performance = EloLadder.performanceRating(games: ladderGames) {
            put(.ladderPerformance, performance, ladderGames.count)
        }

        return result
    }

    // MARK: Guided-mode prompts

    /// Hit rate on the guided-mode coaching prompts, per habit.
    ///
    /// The one metric family whose window is *not* the last `games` rows of the
    /// table, and the exception is deliberate. A prompt only exists in guided
    /// mode, so a sparring game is not a zero for this metric — it is a
    /// not-applicable — and letting one occupy a slot in "the last ten games"
    /// meant the sample size depended on which mode the user happened to be in
    /// lately. Someone alternating modes was judged on whatever three or four
    /// guided games survived the cut; someone who played ten sparring games
    /// since their last guided one lost the metric altogether, and
    /// `Skill.evaluate(in:)` reads a missing value as unmet — silently
    /// un-certifying the *required* `r2.threatAwareness` for playing the wrong
    /// mode for a fortnight. The minimum-sample rule this metric now carries
    /// would otherwise have made that worse, not better: eight prompts cannot
    /// be collected out of a window sparring games are free to fill.
    ///
    /// Counting the window in games that actually asked about the habit gives
    /// every user the same sample, and ages it out only when newer guided games
    /// push it out. It is still bounded by how far back `MetricsService` loads,
    /// so it cannot reach into ancient history to keep a stale rate alive.
    private static func guidedPromptMetrics(
        _ statistics: [GameStatistics],
        window: MetricWindow,
        games: Int
    ) -> [MetricAddress: MetricValue] {
        var result: [MetricAddress: MetricValue] = [:]
        func put(_ key: MetricKey, _ value: Double, _ samples: Int) {
            guard !unsupportedMetrics.contains(key.rawValue), samples > 0 else { return }
            result[MetricAddress(key: key, window: window)] = MetricValue(value: value, sampleCount: samples)
        }

        // Bucketed per habit — only `scanThreats` is gated today, but a new
        // guided gate then needs no new code here.
        let habits = Set(statistics.flatMap { $0.guidedPrompts.map(\.habit) })
        var prompts: [String: (total: Int, hits: Int)] = [:]
        for habit in habits {
            var bucket = (total: 0, hits: 0)
            let asked = statistics.filter { statistic in
                statistic.guidedPrompts.contains { $0.habit == habit }
            }
            for statistic in asked.prefix(games) {
                for prompt in statistic.guidedPrompts where prompt.habit == habit {
                    bucket.total += 1
                    if prompt.hit { bucket.hits += 1 }
                }
            }
            prompts[habit] = bucket
        }

        if let scan = prompts[Habit.scanThreats.rawValue], scan.total > 0 {
            put(.guidedScanThreatsHitRate, Double(scan.hits) / Double(scan.total), scan.total)
        }

        return result
    }

    // MARK: Lifetime metrics

    private static func lifetimeMetrics(
        counters: MetricCounters,
        ladder: [Rung],
        tuning: DomainTuning
    ) -> [MetricAddress: MetricValue] {
        var result: [MetricAddress: MetricValue] = [:]
        let allTime = MetricWindow.allTime

        result[MetricAddress(key: .puzzleRating, window: allTime)] =
            MetricValue(value: counters.puzzleRating, sampleCount: 1)
        result[MetricAddress(key: .puzzleRatingDeviation, window: allTime)] =
            MetricValue(value: counters.puzzleDeviation, sampleCount: 1)
        result[MetricAddress(key: .ladderRating, window: allTime)] =
            MetricValue(value: counters.ladderRating, sampleCount: 1)

        for (kind, value) in counters.drillStreaks {
            result[MetricAddress(key: kind.streakMetricKey, window: allTime)] = value
        }

        let floor = tuning.curriculum.themeRatingFloor
        for theme in tuning.curriculum.rung2Themes {
            let attempts = counters.themeAttempts[theme] ?? 0
            guard attempts > 0 else { continue }
            let solves = counters.themeSolves[theme] ?? 0
            result[MetricAddress(key: .puzzleThemeSuccess(theme, ratingFloor: floor), window: allTime)] =
                MetricValue(value: solves / attempts, sampleCount: Int(attempts))
        }

        return result
    }

    // MARK: Single-game replay

    /// Replays one game and collects everything it contributes.
    ///
    /// Replaying is unavoidable: phase classification, the opening composite,
    /// criticality's SEE filters and the endgame classifier all need the actual
    /// board, and none of it is stored per ply.
    static func statistics(for analysed: AnalysedGame, tuning: DomainTuning = .default) -> GameStatistics {
        var statistics = GameStatistics()
        let game = analysed.game
        let userIsWhite = game.color != .black

        statistics.guidedPrompts = analysed.guidedPrompts
        statistics.ladderGame = ladderGame(for: game)

        // Moment counts, filtered where the curriculum names a threshold.
        let hangingThreshold = hangingPieceEPThreshold(tuning: tuning.curriculum)
        for moment in analysed.moments {
            let isHanging = moment.causeTag == AnalysisKit.CauseTag.hungMovedPiece.rawValue
                || moment.causeTag == AnalysisKit.CauseTag.hungLeftPiece.rawValue
            if isHanging && moment.deltaEP < hangingThreshold { continue }
            statistics.causeCounts[moment.causeTag, default: 0] += 1
        }
        // Expected points before the move at each ply, from the *mover's*
        // perspective — which is what an engine score already is.
        var epByPly: [Int: Double] = [:]
        var bestByPly: [Int: UCIScore] = [:]
        var secondByPly: [Int: UCIScore] = [:]
        for eval in analysed.evals {
            guard let best = score(cp: eval.pv1Cp, mate: eval.pv1Mate) else { continue }
            bestByPly[eval.ply] = best
            epByPly[eval.ply] = EvalMath.expectedPoints(score: best)
            if let second = score(cp: eval.pv2Cp, mate: eval.pv2Mate) {
                secondByPly[eval.ply] = second
            }
        }

        var board = Board(position: .standard)
        var lastCaptureSquare: Square?
        var castled = false
        var openingMistakeSeen = false
        var minorsDeveloped = 0
        var everWinning = false
        var wasWinningPreviousPly = false
        var rookEndingResultClass: ResultClass?
        var userThinkTimes: [Int] = []

        for move in analysed.moves.sorted(by: { $0.ply < $1.ply }) {
            let ply = move.ply
            let isUserMove = (ply % 2 == 1) == userIsWhite
            let positionBefore = board.position
            let phase = AnalysisKit.Phase.classify(position: positionBefore, ply: ply)

            if isUserMove {
                statistics.userMoves += 1
                userThinkTimes.append(move.thinkTimeMs)

                // Expected points from the user's point of view.
                let epBefore = epByPly[ply]
                let epAfter = epByPly[ply + 1].map { 1 - $0 }
                let accuracy = epBefore.flatMap { before in
                    epAfter.map { EvalMath.accuracy(winPctBefore: before * 100, winPctAfter: $0 * 100) }
                }
                let deltaEP = epBefore.flatMap { before in epAfter.map { max(0, before - $0) } }
                let judgment = deltaEP.map { EvalMath.judgment(deltaEP: $0) }

                if judgment == .blunder { statistics.blunders += 1 }

                if phase == .opening {
                    if let accuracy { statistics.openingAccuracySum += accuracy; statistics.openingAccuracyCount += 1 }
                    if let judgment, judgment >= .mistake {
                        statistics.openingMistakes += 1
                        openingMistakeSeen = true
                    }
                }

                // Criticality, using the same evaluator the analysis pass uses
                // so the two never disagree about what a key moment was.
                var isCritical = false
                if let best = bestByPly[ply] {
                    let result = Criticality.evaluate(
                        best: UCIInfo(score: best, pv: [move.uci]),
                        secondBest: secondByPly[ply].map { UCIInfo(multipv: 2, score: $0) },
                        board: board,
                        lastCaptureSquare: lastCaptureSquare
                    )
                    isCritical = result.isCritical
                }

                if isCritical {
                    statistics.criticalMoments += 1
                    // A hit is a moment the user came through without giving
                    // anything back — not merely one that escaped the "mistake"
                    // label. The mistake band opens at 0.20 expected points, so
                    // counting anything below it would let a move that hands
                    // over a fifth of the result count as holding the position,
                    // at exactly the moments where the position was decided.
                    if let judgment, judgment < .inaccuracy { statistics.criticalHits += 1 }
                    statistics.criticalThinkMs += Double(move.thinkTimeMs)
                    statistics.criticalThinkCount += 1
                    if ThinkBucket.classify(thinkTimeMs: move.thinkTimeMs, control: nil) == .fast {
                        statistics.impulseAtCritical += 1
                    }
                } else {
                    statistics.normalThinkMs += Double(move.thinkTimeMs)
                    statistics.normalThinkCount += 1
                    if phase == .middlegame, let accuracy {
                        statistics.middlegameNonCriticalAccuracySum += accuracy
                        statistics.middlegameNonCriticalAccuracyCount += 1
                    }
                }

                // Conversion: a slip is a user move that gives the advantage
                // back, not merely a position that stopped being winning.
                if let epBefore, epBefore >= winningEPThreshold {
                    everWinning = true
                    wasWinningPreviousPly = true
                } else if wasWinningPreviousPly, let epBefore, epBefore < winningEPThreshold {
                    statistics.advantageSlips += 1
                    wasWinningPreviousPly = false
                }

                if move.san.hasPrefix("O-O"), ply <= tuning.curriculum.openingCastledByMove * 2 {
                    castled = true
                }
            }

            // Rook-ending result-class tracking, on both sides' plies so a flip
            // caused by the opponent's move is not blamed on the user's.
            if AnalysisKit.EndgameClassifier.classify(positionBefore) == .rookEndgame {
                statistics.wasRookEnding = true
                if let best = bestByPly[ply] {
                    // Normalise to the user's point of view before classifying.
                    let userScore = isUserMove ? best : best.negated
                    let current = ResultClass.classify(userScore)
                    if let previous = rookEndingResultClass, previous != current {
                        statistics.rookEndingResultFlipped = true
                    }
                    rookEndingResultClass = current
                }
            }

            if board.position.piece(at: Square(String(move.uci.dropFirst(2).prefix(2)))) != nil {
                lastCaptureSquare = Square(String(move.uci.dropFirst(2).prefix(2)))
            } else {
                lastCaptureSquare = nil
            }

            guard PuzzleSolveMachine.apply(uci: move.uci, to: &board) else { break }

            if ply == tuning.curriculum.openingMinorsDevelopedByMove * 2 || ply == analysed.moves.count {
                minorsDeveloped = max(minorsDeveloped, developedMinors(in: board.position, white: userIsWhite))
            }
        }

        statistics.openingCompositePassed = Curriculum.openingCompositePasses(
            castledByMoveLimit: castled,
            minorsDevelopedByMoveLimit: minorsDeveloped >= tuning.curriculum.openingMinorsRequired,
            noOpeningMistakes: !openingMistakeSeen,
            tuning: tuning.curriculum
        )

        statistics.reachedWinning = everWinning
        if everWinning, let result = game.result.flatMap(GameResult.init(rawValue:)) {
            statistics.wonFromWinning = result.isWin(for: userIsWhite ? .white : .black)
        }

        statistics.endedInClockPressure = endedInClockPressure(
            userThinkTimes: userThinkTimes,
            termination: game.termination
        )

        return statistics
    }

    /// Expected points at which a position counts as winning, per the rung-4
    /// conversion skill.
    static let winningEPThreshold = 0.85

    /// Whether a game ended with the user out of thinking time.
    ///
    /// There is no clock column, so this is inferred from the shape of the think
    /// times: a tail of moves that are all snap judgements is what running low
    /// on clock looks like from the move list. An explicit timeout termination
    /// short-circuits it. Documented as a heuristic because it is one — the
    /// alternative is not measuring the rung-4 clock skill at all.
    static func endedInClockPressure(userThinkTimes: [Int], termination: String?) -> Bool {
        if let termination, termination.lowercased().contains("time") || termination.lowercased().contains("flag") {
            return true
        }
        let tailLength = 8
        guard userThinkTimes.count >= 16 else { return false }
        let tail = userThinkTimes.suffix(tailLength)
        return tail.allSatisfy { ThinkBucket.classify(thinkTimeMs: $0, control: nil) == .fast }
    }

    /// How many of the four minor-piece home squares have been vacated.
    ///
    /// Counting *empty slots* rather than pieces away from home is the right
    /// reading of "developed": a knight that has moved is developed, and a
    /// knight traded off on b1 is not — but neither is sitting on b1, and the
    /// square being empty is the observable both cases share. Counting surviving
    /// minors elsewhere on the board would credit a bishop that was captured on
    /// f8 and recaptured by a rook.
    static func developedMinors(in position: Position, white: Bool) -> Int {
        let color: Piece.Color = white ? .white : .black
        let home: [Square] = white ? [.b1, .c1, .f1, .g1] : [.b8, .c8, .f8, .g8]
        return home.filter { square in
            guard let piece = position.piece(at: square) else { return true }
            return !(piece.color == color && (piece.kind == .knight || piece.kind == .bishop))
        }.count
    }

    private static func score(cp: Int?, mate: Int?) -> UCIScore? {
        if let mate { return .mate(mate) }
        if let cp { return .centipawns(cp) }
        return nil
    }

    /// A finished game as the rating ladder sees it.
    ///
    /// Selected by *mode*, not by `isRated`. `isRated` means "this game is clean
    /// enough to measure raw strength from" and is false for every sparring game
    /// by construction, because second-try is on — filtering on it here left the
    /// performance rating computed over calibration games alone, so the drift
    /// guard that is supposed to catch a mis-set rating had nothing to look at.
    ///
    /// Calibration is the one mode excluded: `CalibrationModel` already writes
    /// the rating those games produced, and counting them again here would let
    /// the same five games move the number twice.
    static func ladderGame(for game: Database.Game) -> LadderGame? {
        guard
            game.gameMode != .calibration,
            let result = game.result.flatMap(GameResult.init(rawValue:)),
            let color = game.color
        else { return nil }

        // Qualified: `GameOutcome` also names the coaching layer's win/loss/draw
        // for a game summary. This one is the ladder's scoring value.
        let outcome: TrainingCore.GameOutcome
        if result == .draw {
            outcome = .draw
        } else {
            outcome = result.isWin(for: color) ? .win : .loss
        }

        return LadderGame(
            opponentRating: Double(game.opponentRating),
            outcome: outcome,
            mode: game.gameMode == .guided ? .guided : .sparring,
            containedLevel2AssistedRetry: game.usedAssistedRetry
        )
    }
}
