//
//  SelfAssessment.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// How much chess the user says they have played.
///
/// ## Why ask before testing
///
/// Duolingo's placement flow opens with a question, not a question *paper*, and
/// the reason is measurement rather than manners. A diagnostic that starts every
/// user at the same difficulty spends its first few items discovering something
/// the user could simply have told us, and it spends them at the two ends of the
/// distribution where being wrong is most expensive: a complete beginner is
/// handed five losses, and a strong player is handed five trivial wins that
/// saturate the score term and produce a `ceilingNotFound` estimate.
///
/// One question moves the starting rung of the ladder and lets both ends skip
/// ahead. It is a *seed*, never a result — nothing here is stored as the user's
/// rating, and five games and twenty puzzles overrule it entirely.
enum ChessExperience: String, CaseIterable, Sendable, Hashable, Identifiable, Codable {

    case new
    case knowsTheMoves
    case playsRegularly
    case competitive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "I'm new to chess"
        case .knowsTheMoves: "I know how the pieces move"
        case .playsRegularly: "I play fairly often"
        case .competitive: "I play rated or club chess"
        }
    }

    /// 1...4 filled bars.
    ///
    /// A signal-bars glyph rather than a number. The scale is genuinely ordinal
    /// — the gaps between these four answers are not equal and nobody can say
    /// what they are — so putting `2` next to the second option would assert a
    /// precision the question does not have. Bars say "more than the one above"
    /// and nothing else, which is exactly what is being claimed.
    var bars: Int {
        switch self {
        case .new: 1
        case .knowsTheMoves: 2
        case .playsRegularly: 3
        case .competitive: 4
        }
    }
}

/// Turns the self-assessment into starting difficulty.
enum CalibrationSeed {

    /// The rating the first calibration opponent plays at when the question was
    /// not answered.
    ///
    /// 1100 sits just below the median of the app's target audience, which makes
    /// the common case a slight underestimate — cheap to correct upward over
    /// five games, and much kinder than opening with a loss.
    static let defaultOpponentRating = 1100

    /// How far the ladder moves after each game.
    static let step = 100

    /// The weakest opponent the engine can actually be.
    ///
    /// `Humanizer.Profile.anchors` starts at 800 and interpolation clamps below
    /// it, so a ladder that walked down to 600 would put "Opponent 600" on the
    /// screen and 600 into `mean(opponentRatings)` while the 800 profile played
    /// every move. The label would be describing nothing, and the estimate would
    /// be dragged down by strength the opponent never actually gave up. Stopping
    /// the walk where the measured profiles stop is the only honest floor
    /// available until a sub-800 anchor exists and has been measured; the old
    /// floor of 400 was two unmeasured steps past the end of the ladder.
    ///
    /// It is also exactly ``opponentRating(for:)`` for `.new`, so the gentlest
    /// seed and the floor agree by construction.
    static let weakestOpponent = 800

    /// Where the opponent ladder starts.
    ///
    /// Offsets from ``defaultOpponentRating`` rather than absolute numbers, so
    /// the unseeded case and the seeded cases cannot drift apart.
    static func opponentRating(for experience: ChessExperience?) -> Int {
        guard let experience else { return defaultOpponentRating }
        switch experience {
        case .new: return defaultOpponentRating - 300
        case .knowsTheMoves: return defaultOpponentRating - 100
        case .playsRegularly: return defaultOpponentRating + 100
        case .competitive: return defaultOpponentRating + 400
        }
    }

    /// Where the puzzle ladder starts.
    ///
    /// Above the playing seed, because puzzle ratings run hot relative to
    /// playing strength — `DomainTuning.Calibration.puzzleRatingOffset` is the
    /// same statement in the other direction, and using it here keeps the two
    /// halves of the flow on one set of numbers.
    static func puzzleRating(
        for experience: ChessExperience?,
        tuning: DomainTuning.Calibration = DomainTuning.default.calibration
    ) -> Int {
        opponentRating(for: experience) - Int(tuning.puzzleRatingOffset)
    }

    /// The next opponent rating after a result.
    ///
    /// A draw holds the ladder still: it is the one result that says the two
    /// sides are already close, so moving would be discarding the information.
    ///
    /// Losses stop at ``weakestOpponent`` rather than continuing down into
    /// labels the engine cannot play.
    static func nextOpponentRating(current: Int, outcome: GameOutcome) -> Int {
        switch outcome {
        case .win: return current + step
        case .loss: return max(weakestOpponent, current - step)
        case .draw: return current
        }
    }

    /// The band the next calibration puzzle is drawn from.
    ///
    /// Same ±`step` walk as the games, and for the same reason: twenty puzzles
    /// all at one difficulty measure whether the user can solve *that*
    /// difficulty, not where their ceiling is.
    static func nextPuzzleRating(current: Int, solved: Bool) -> Int {
        solved ? current + step : max(400, current - step)
    }
}
