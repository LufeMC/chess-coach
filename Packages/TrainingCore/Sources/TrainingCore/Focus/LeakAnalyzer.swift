//
//  LeakAnalyzer.swift
//  TrainingCore
//

import Foundation

/// A game, reduced to what leak analysis needs.
public struct GameRecord: Sendable, Hashable, Identifiable {
    public let id: String
    public let playedAt: Date

    public init(id: String, playedAt: Date) {
        self.id = id
        self.playedAt = playedAt
    }
}

/// One tagged mistake from one game.
public struct MistakeRecord: Sendable, Hashable {

    public var gameID: String
    public var causeTag: CauseTag

    /// Expected points lost by the move, as a positive number. Expected points
    /// rather than centipawns because a 200cp slip in a dead-drawn endgame and
    /// a 200cp slip in a sharp middlegame cost wildly different amounts of
    /// actual result, and the user cares about results.
    public var deltaEP: Double

    public init(gameID: String, causeTag: CauseTag, deltaEP: Double) {
        self.gameID = gameID
        self.causeTag = causeTag
        self.deltaEP = deltaEP
    }
}

/// One row of the rating-leak chart.
public struct Leak: Sendable, Hashable {

    public var causeTag: CauseTag

    /// The habit that fixes it, at the rung the analysis was run for.
    public var habit: Habit?

    /// `Σ(deltaEP × 0.5^(gamesAgo / halfLife))` — the sort key.
    public var weightedEPLost: Double

    /// ``weightedEPLost`` divided by the number of games in the window: the
    /// headline "this is costing you X points a game" number.
    public var epLostPerGame: Double

    /// How many mistakes with this tag are in the window.
    public var count: Int

    /// This week's unweighted EP-per-game minus last week's. Positive means
    /// getting worse. Zero when either week has no games — the comparison is
    /// undefined, and showing a fabricated improvement is worse than showing
    /// none.
    public var deltaVsPreviousWeek: Double

    public init(
        causeTag: CauseTag,
        habit: Habit?,
        weightedEPLost: Double,
        epLostPerGame: Double,
        count: Int,
        deltaVsPreviousWeek: Double
    ) {
        self.causeTag = causeTag
        self.habit = habit
        self.weightedEPLost = weightedEPLost
        self.epLostPerGame = epLostPerGame
        self.count = count
        self.deltaVsPreviousWeek = deltaVsPreviousWeek
    }
}

/// Aggregates tagged mistakes into the rating-leak chart.
public enum LeakAnalyzer {

    /// Computes the leak table.
    ///
    /// - Parameters:
    ///   - mistakes: Every tagged mistake available. Mistakes belonging to
    ///     games outside the window are ignored.
    ///   - games: Every game available, so the window can be defined in terms
    ///     of games the user actually played — including the ones with no
    ///     mistakes, which are what make the per-game denominator honest.
    ///   - rung: The user's rung, which decides the cause→habit mapping.
    ///
    /// ## The window
    ///
    /// Nominally the last 21 days, **extended back until it holds at least 8
    /// games**. Both halves matter. A fixed day window makes the chart lie for
    /// anyone whose play is bursty: three games in three weeks produces a chart
    /// built on three games and presented with the same confidence as one built
    /// on thirty. A fixed game window, conversely, would happily reach back six
    /// months and coach the user on a weakness they fixed in the spring.
    ///
    /// ## The recency weight
    ///
    /// `0.5^(gamesAgo / 10)` — a mistake ten games ago counts half as much as
    /// one today. This is the difference between a leak chart and a lifetime
    /// statistic. The user needs to know what is costing them points *now*;
    /// a habit they have already fixed should visibly fade out of the chart
    /// over about a fortnight of play, which is roughly what a ten-game half
    /// life produces, rather than sitting at the top for months because of a
    /// bad patch in the past.
    public static func leaks(
        from mistakes: [MistakeRecord],
        games: [GameRecord],
        rung: Int,
        now: Date = Date(),
        tuning: DomainTuning.Focus = DomainTuning.default.focus
    ) -> [Leak] {
        guard !games.isEmpty else { return [] }

        // Most recent first: the index in this array is `gamesAgo`.
        let ordered = games.sorted { lhs, rhs in
            if lhs.playedAt != rhs.playedAt { return lhs.playedAt > rhs.playedAt }
            return lhs.id < rhs.id
        }

        let cutoff = now.addingTimeInterval(-Double(tuning.leakWindowDays) * 86_400)
        var windowSize = ordered.filter { $0.playedAt >= cutoff }.count
        // Extend back until the window is statistically worth reporting.
        windowSize = min(ordered.count, max(windowSize, tuning.leakMinimumGames))
        guard windowSize > 0 else { return [] }

        var gamesAgo: [String: Int] = [:]
        for (index, game) in ordered.prefix(windowSize).enumerated() {
            gamesAgo[game.id] = index
        }

        // Week-over-week buckets, by date rather than by game index: "last
        // week" is a calendar idea to the user, not a game-count idea.
        let weekSpan = Double(tuning.comparisonWindowDays) * 86_400
        let thisWeekStart = now.addingTimeInterval(-weekSpan)
        let previousWeekStart = now.addingTimeInterval(-2 * weekSpan)

        var thisWeekGames = Set<String>()
        var previousWeekGames = Set<String>()
        for game in ordered {
            if game.playedAt >= thisWeekStart {
                thisWeekGames.insert(game.id)
            } else if game.playedAt >= previousWeekStart {
                previousWeekGames.insert(game.id)
            }
        }

        struct Accumulator {
            var weighted: Double = 0
            var count: Int = 0
            var thisWeek: Double = 0
            var previousWeek: Double = 0
        }
        var byTag: [CauseTag: Accumulator] = [:]

        for mistake in mistakes {
            if let index = gamesAgo[mistake.gameID] {
                var accumulator = byTag[mistake.causeTag] ?? Accumulator()
                let weight = pow(0.5, Double(index) / tuning.leakHalfLifeGames)
                accumulator.weighted += mistake.deltaEP * weight
                accumulator.count += 1
                byTag[mistake.causeTag] = accumulator
            }
            // The week buckets are computed over all games, not just the
            // window, so the comparison still works for a user whose window
            // extended past 21 days.
            if thisWeekGames.contains(mistake.gameID) {
                var accumulator = byTag[mistake.causeTag] ?? Accumulator()
                accumulator.thisWeek += mistake.deltaEP
                byTag[mistake.causeTag] = accumulator
            } else if previousWeekGames.contains(mistake.gameID) {
                var accumulator = byTag[mistake.causeTag] ?? Accumulator()
                accumulator.previousWeek += mistake.deltaEP
                byTag[mistake.causeTag] = accumulator
            }
        }

        let denominator = Double(windowSize)
        let comparable = !thisWeekGames.isEmpty && !previousWeekGames.isEmpty

        return byTag
            .map { tag, accumulator in
                let delta: Double
                if comparable {
                    delta = accumulator.thisWeek / Double(thisWeekGames.count)
                        - accumulator.previousWeek / Double(previousWeekGames.count)
                } else {
                    delta = 0
                }
                return Leak(
                    causeTag: tag,
                    habit: tag.habit(rung: rung),
                    weightedEPLost: accumulator.weighted,
                    epLostPerGame: accumulator.weighted / denominator,
                    count: accumulator.count,
                    deltaVsPreviousWeek: delta
                )
            }
            // Only tags that actually appear in the window are worth charting;
            // a tag that only showed up in the week buckets has no window
            // weight and would render as a zero-length bar.
            .filter { $0.count > 0 }
            .sorted { lhs, rhs in
                if lhs.weightedEPLost != rhs.weightedEPLost { return lhs.weightedEPLost > rhs.weightedEPLost }
                return lhs.causeTag.rawValue < rhs.causeTag.rawValue
            }
    }
}
