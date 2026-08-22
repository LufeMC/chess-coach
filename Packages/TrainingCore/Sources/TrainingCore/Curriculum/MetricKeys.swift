//
//  MetricKeys.swift
//  TrainingCore
//

import Foundation

/// The metric vocabulary the curriculum gates on.
///
/// Namespaced with dots so a metric's producer is readable from its key alone:
/// `mistake.*` comes from the post-game analysis detectors, `drill.*` from the
/// endgame drills, `puzzle.*`/`ladder.*` from the rating systems, and so on.
/// The app layer is responsible for computing these; this package only names
/// them and compares them to thresholds.
extension MetricKey {

    // MARK: - Mistake rates (per 100 moves unless stated)

    /// Pieces hung for at least
    /// ``DomainTuning/Curriculum/hangingPieceThresholdCentipawns``.
    public static let hangingPiecePer100: MetricKey = "mistake.hangingPiece.per100"
    public static let blundersPer100: MetricKey = "mistake.blunder.per100"
    public static let missedTacticPer100: MetricKey = "mistake.missedTactic.per100"
    public static let ignoredThreatPer100: MetricKey = "mistake.ignoredThreat.per100"
    public static let allowedDeepTacticPer100: MetricKey = "mistake.allowedTactic.deep.per100"
    public static let missedQuietMovePer100: MetricKey = "mistake.missedQuietMove.per100"

    // MARK: - Retry and guidance

    /// Fraction of failed positions the user then re-played cleanly.
    public static let cleanRetryRate: MetricKey = "retry.cleanRate"
    /// Hit rate on the guided-mode "what is your opponent threatening?" prompt.
    public static let guidedScanThreatsHitRate: MetricKey = "guided.scanThreats.hitRate"

    // MARK: - Drills

    public static let kqkDrillCleanStreak: MetricKey = "drill.kqk.cleanStreak"
    public static let krkDrillCleanStreak: MetricKey = "drill.krk.cleanStreak"
    /// Consecutive *complete sets* of KPK positions solved without error.
    public static let kpkDrillCleanSetStreak: MetricKey = "drill.kpk.cleanSetStreak"
    public static let lucenaDrillCleanStreak: MetricKey = "drill.lucena.cleanStreak"
    public static let philidorDrillCleanStreak: MetricKey = "drill.philidor.cleanStreak"
    /// Rook endings whose result class flipped, normalised per 8 endings.
    public static let rookEndingResultFlipsPer8: MetricKey = "rookEnding.resultFlipsPer8"

    // MARK: - Opening

    /// Fraction of games passing the three-part opening composite.
    public static let openingCompositeRate: MetricKey = "opening.compositeRate"
    public static let openingAccuracy: MetricKey = "opening.accuracy"
    public static let openingMistakesPerGame: MetricKey = "opening.mistakesPerGame"

    // MARK: - Middlegame quality

    public static let middlegameNonCriticalAccuracy: MetricKey = "accuracy.middlegameNonCritical"
    /// Fraction of critical moments where the user found a good move.
    public static let criticalMomentHitRate: MetricKey = "criticalMoment.hitRate"
    /// Fraction of available prophylactic moves the user found.
    public static let prophylacticFindRate: MetricKey = "prophylactic.findRate"

    // MARK: - Conversion

    /// Win rate in games that reached an expected-points advantage of 0.85.
    public static let winRateFromWinningPosition: MetricKey = "conversion.winRateFromWinningEP"
    /// Advantage-losing slips per game that was winning.
    public static let advantageSlipsPerWinningGame: MetricKey = "conversion.advantageSlipsPerWinningGame"

    // MARK: - Clock

    /// Fraction of games that ended in clock pressure.
    public static let clockPressureGameRate: MetricKey = "timeError.clockPressure.gameRate"
    /// Count of instant moves played at critical moments.
    public static let impulseAtCriticalCount: MetricKey = "timeError.impulseAtCritical.count"
    /// Mean think time at critical moments divided by mean elsewhere.
    public static let criticalToNormalThinkTimeRatio: MetricKey = "thinkTime.criticalToNormalRatio"

    // MARK: - Ratings

    public static let puzzleRating: MetricKey = "puzzle.rating"
    public static let puzzleRatingDeviation: MetricKey = "puzzle.ratingDeviation"
    public static let ladderRating: MetricKey = "ladder.rating"
    /// Performance rating over the metric's window.
    public static let ladderPerformance: MetricKey = "ladder.performance"

    // MARK: - Composed keys

    /// Success rate on puzzles of a given theme at or above a rating floor.
    ///
    /// The floor is part of the key rather than a separate criterion because
    /// the *metric itself* is scoped — "70% on forks" and "70% on forks rated
    /// 1200+" are different measurements, not the same measurement with an
    /// extra condition.
    public static func puzzleThemeSuccess(_ theme: ThemeTag, ratingFloor: Int) -> MetricKey {
        MetricKey("puzzle.themeSuccess.\(theme.rawValue)@\(ratingFloor)")
    }
}

// MARK: - How a metric reads on screen

/// The user-facing vocabulary for one metric: the quantity it measures, the unit
/// its value carries, and what one observation of it is.
///
/// ## Why the ladder cannot do without this
///
/// The curriculum states its gates in code — `cleanRetryRate ≥ 0.55` — and the
/// screen has to render them to someone who has never seen a metric key. With
/// only the numbers the row under "Blunder control" reads `0.4 / ≥ 0.55`, which
/// names no quantity, carries no unit, and cannot be gone away and practised.
///
/// ``sampleNoun`` is here rather than assumed to be "games" because it is not
/// games: the rung-2 theme gate counts puzzle attempts, the rung-3
/// critical-moment gate counts critical moments, and the drill gates count runs
/// of a drill that no amount of playing will ever start. A ladder that answers
/// every one of those with "Needs 15 more games" is giving an instruction that
/// does not work, on the one screen whose job is to say what unblocks the next
/// rung.
public struct MetricPresentation: Sendable, Hashable {

    /// How a value on this metric is written out.
    public enum Style: Sendable, Hashable {
        /// A fraction in `0...1`, read aloud as a percentage.
        case rate
        /// Already on a 0–100 scale.
        case percentage
        /// A small rate or ratio where the decimals carry the meaning.
        case decimal
        /// A whole number: a rating, a streak, a tally.
        case count

        public func format(_ value: Double) -> String {
            switch self {
            case .rate: return String(format: "%.0f%%", value * 100)
            case .percentage: return String(format: "%.0f%%", value)
            case .count: return String(format: "%.0f", value)
            case .decimal:
                let two = String(format: "%.2f", value)
                return two.hasSuffix("0") ? String(two.dropLast()) : two
            }
        }
    }

    /// The measured quantity, named the way a player would say it.
    public var name: String

    /// The unit the value and its threshold both carry, when the bare number is
    /// ambiguous. `nil` where the style already says it (a percentage) or where
    /// the name does (a rating).
    public var unit: String?

    public var style: Style

    /// What one observation is, plural.
    public var sampleNoun: String

    /// The same noun for a count of one. Spelled out rather than derived by
    /// trimming an `s`, so an irregular plural cannot break it silently.
    public var sampleNounSingular: String

    /// Where an observation comes from when playing a game will not produce one.
    /// `nil` when games are the source.
    public var sampleSource: String?

    public init(
        name: String,
        unit: String? = nil,
        style: Style,
        sampleNoun: String = "games",
        sampleNounSingular: String = "game",
        sampleSource: String? = nil
    ) {
        self.name = name
        self.unit = unit
        self.style = style
        self.sampleNoun = sampleNoun
        self.sampleNounSingular = sampleNounSingular
        self.sampleSource = sampleSource
    }

    /// `0.8 per 100 moves`, or `42%` where the style carries the unit itself.
    public func formatted(_ value: Double) -> String {
        guard let unit else { return style.format(value) }
        return "\(style.format(value)) \(unit)"
    }
}

extension MetricKey {

    /// How this metric reads on screen.
    ///
    /// Total by construction: an unrecognised key — one composed by a newer
    /// build, or added here without a line below — falls back to its own last
    /// path component rather than dropping the row. A ladder row that vanishes
    /// is worse than one named awkwardly.
    public var presentation: MetricPresentation {
        if let theme = Self.themePresentation(rawValue) { return theme }

        switch self {

        // Mistake rates. The "per 100 moves" is the whole reason these numbers
        // are small; without it "0.8" invites the reading "0.8 a game".
        case .hangingPiecePer100:
            return MetricPresentation(name: "Hanging pieces", unit: "per 100 moves", style: .decimal)
        case .blundersPer100:
            return MetricPresentation(name: "Blunders", unit: "per 100 moves", style: .decimal)
        case .missedTacticPer100:
            return MetricPresentation(name: "Missed tactics", unit: "per 100 moves", style: .decimal)
        case .ignoredThreatPer100:
            return MetricPresentation(name: "Ignored threats", unit: "per 100 moves", style: .decimal)
        case .allowedDeepTacticPer100:
            return MetricPresentation(name: "Deep tactics allowed", unit: "per 100 moves", style: .decimal)
        case .missedQuietMovePer100:
            return MetricPresentation(name: "Missed quiet moves", unit: "per 100 moves", style: .decimal)

        // Retry and guidance. Neither is produced by playing another sparring
        // game, which is exactly why they carry their own nouns.
        case .cleanRetryRate:
            return MetricPresentation(
                name: "Clean retries", style: .rate,
                sampleNoun: "retried review cards", sampleNounSingular: "retried review card"
            )
        case .guidedScanThreatsHitRate:
            // Prompts, not games: the sample this metric counts is one coaching
            // question, and guided mode asks at most three of them per game.
            // "Needs 8 more guided games" would have overstated the work by
            // roughly three times, on the row whose only job is to say what
            // unblocks the rung. The noun still names the mode, because that is
            // the part the user has to go and choose.
            return MetricPresentation(
                name: "Threat prompts answered", style: .rate,
                sampleNoun: "guided threat prompts", sampleNounSingular: "guided threat prompt"
            )

        // Drills. A drill metric only ever moves when the drill is run, so the
        // row says where the drill lives rather than asking for another game.
        case .kqkDrillCleanStreak:
            return .drill(name: "K+Q mate drill, clean runs in a row")
        case .krkDrillCleanStreak:
            return .drill(name: "K+R mate drill, clean runs in a row")
        case .kpkDrillCleanSetStreak:
            return .drill(name: "King-and-pawn sets, clean in a row")
        case .lucenaDrillCleanStreak:
            return .drill(name: "Lucena drill, clean runs in a row")
        case .philidorDrillCleanStreak:
            return .drill(name: "Philidor drill, clean runs in a row")
        case .rookEndingResultFlipsPer8:
            return MetricPresentation(
                name: "Rook endings thrown away", unit: "per 8 endings", style: .decimal,
                sampleNoun: "rook endings", sampleNounSingular: "rook ending"
            )

        // Opening.
        case .openingCompositeRate:
            return MetricPresentation(name: "Sound openings", style: .rate)
        case .openingAccuracy:
            return MetricPresentation(name: "Opening accuracy", style: .percentage)
        case .openingMistakesPerGame:
            return MetricPresentation(name: "Opening mistakes", unit: "per game", style: .decimal)

        // Middlegame quality.
        case .middlegameNonCriticalAccuracy:
            return MetricPresentation(
                name: "Middlegame accuracy", style: .percentage,
                sampleNoun: "quiet middlegame moves", sampleNounSingular: "quiet middlegame move"
            )
        case .criticalMomentHitRate:
            return MetricPresentation(
                name: "Critical moments held", style: .rate,
                sampleNoun: "critical moments", sampleNounSingular: "critical moment"
            )
        case .prophylacticFindRate:
            return MetricPresentation(name: "Prophylactic moves found", style: .rate)

        // Conversion.
        case .winRateFromWinningPosition:
            return MetricPresentation(
                name: "Won from winning positions", style: .rate,
                sampleNoun: "winning games", sampleNounSingular: "winning game"
            )
        case .advantageSlipsPerWinningGame:
            return MetricPresentation(
                name: "Advantage given back", unit: "per winning game", style: .decimal,
                sampleNoun: "winning games", sampleNounSingular: "winning game"
            )

        // Clock.
        case .clockPressureGameRate:
            return MetricPresentation(name: "Games ending in time trouble", style: .rate)
        case .impulseAtCriticalCount:
            return MetricPresentation(name: "Instant moves at critical moments", style: .count)
        case .criticalToNormalThinkTimeRatio:
            return MetricPresentation(
                name: "Time at critical moments", unit: "× the rest of the game", style: .decimal
            )

        // Ratings.
        case .puzzleRating:
            return MetricPresentation(
                name: "Puzzle rating", style: .count,
                sampleNoun: "puzzles", sampleNounSingular: "puzzle"
            )
        case .puzzleRatingDeviation:
            return MetricPresentation(
                name: "Puzzle rating uncertainty", unit: "points", style: .count,
                sampleNoun: "puzzles", sampleNounSingular: "puzzle"
            )
        case .ladderRating:
            return MetricPresentation(name: "Game rating", style: .count)
        case .ladderPerformance:
            return MetricPresentation(name: "Performance rating", style: .count)

        default:
            return MetricPresentation(name: Self.humanised(rawValue), style: .decimal)
        }
    }

    /// `puzzle.themeSuccess.fork@1200` → forks at 1200+.
    ///
    /// Parsed rather than switched on because the key is composed at runtime
    /// from the tuning's theme list and rating floor; a fixed table here would
    /// go stale the moment either moved.
    private static func themePresentation(_ rawValue: String) -> MetricPresentation? {
        let prefix = "puzzle.themeSuccess."
        guard rawValue.hasPrefix(prefix) else { return nil }
        let body = rawValue.dropFirst(prefix.count)
        let parts = body.split(separator: "@", maxSplits: 1)
        guard let theme = parts.first else { return nil }
        let floor = parts.count == 2 ? String(parts[1]) : nil
        let noun = ThemeTag(String(theme)).pluralNoun
        let qualifier = floor.map { " at \($0)+" } ?? ""
        return MetricPresentation(
            name: "\(noun.capitalisedFirst)\(qualifier)",
            style: .rate,
            sampleNoun: floor.map { "puzzles rated \($0)+" } ?? "puzzles",
            sampleNounSingular: floor.map { "puzzle rated \($0)+" } ?? "puzzle"
        )
    }

    /// `mistake.hangingPiece.per100` → `Hanging piece`.
    private static func humanised(_ rawValue: String) -> String {
        let tail = rawValue.split(separator: ".").last.map(String.init) ?? rawValue
        var out = ""
        for (index, character) in tail.enumerated() {
            if index == 0 {
                out.append(Character(character.uppercased()))
            } else if character.isUppercase {
                out.append(" ")
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }
}

extension MetricPresentation {

    /// A drill streak: a whole number of clean runs, produced only by running
    /// the drill, so the row can say where it comes from instead of asking for
    /// a game that will never move it.
    ///
    /// It names the *occasion* rather than a screen. There is no Endgames shelf
    /// to send anyone to — the string used to read "Train › Endgames", which was
    /// a destination the app had already removed — and a drill now arrives as
    /// the exercise of a training set's concept, at the rung that gates on it.
    /// Naming a tab that does not exist is worse than naming nothing.
    static func drill(name: String) -> MetricPresentation {
        MetricPresentation(
            name: name,
            style: .count,
            sampleNoun: "clean runs",
            sampleNounSingular: "clean run",
            sampleSource: "a training set"
        )
    }
}

extension ThemeTag {

    /// The theme as a plural noun, for prose that lists several.
    ///
    /// Only the themes the curriculum names are spelled out; anything else falls
    /// back to its raw value, which is still better in a sentence than a gap.
    var pluralNoun: String {
        switch self {
        case .fork: return "forks"
        case .pin: return "pins"
        case .skewer: return "skewers"
        case .discoveredAttack: return "discovered attacks"
        case .backRankMate: return "back-rank mates"
        default: return rawValue
        }
    }
}

extension String {

    /// Uppercases the first character and leaves the rest alone, so
    /// "back-rank mates" becomes "Back-rank mates" without touching the hyphen.
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
