//
//  CoachRequest.swift
//  ClaudeKit
//

import Foundation

/// The payload the app sends for a post-game coaching pass.
///
/// This is a *summary*, never a game dump. The full PGN is deliberately absent:
/// the model has no engine, so anything it would infer from extra moves is
/// guesswork, and every extra token is paid for on every game. What it gets is
/// the analysis the app already trusts — a handful of moments, each with the
/// engine's own lines — plus enough of the student's profile to pitch the
/// language correctly.
public struct CoachRequest: Codable, Sendable, Equatable {

    /// Bumped whenever the shape changes, so a stored response can be matched
    /// to the contract that produced it.
    public static let currentSchemaVersion = 1

    /// Caps enforced before sending. Exceeding them is a correctness problem
    /// (413s, blown latency budget, diluted attention), not a style one.
    public enum Caps {
        public static let maxMoments = 3
        public static let maxPVPlies = 8
    }

    public var schemaVersion: Int
    public var profile: Profile
    public var game: Game
    public var moments: [Moment]

    /// Populated only on the repair attempt: the violations the verifier found
    /// in the model's first answer, echoed back so it can correct itself
    /// instead of re-rolling blind.
    public var validationErrors: [ValidationError]?

    public init(
        schemaVersion: Int = CoachRequest.currentSchemaVersion,
        profile: Profile,
        game: Game,
        moments: [Moment],
        validationErrors: [ValidationError]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.game = game
        self.moments = moments
        self.validationErrors = validationErrors
    }

    /// Applies ``Caps``. Call before sending; ``CoachService`` does it for you.
    public func capped() -> CoachRequest {
        var copy = self
        copy.moments = moments.prefix(Caps.maxMoments).map { moment in
            var moment = moment
            moment.engineLines = moment.engineLines.map { line in
                var line = line
                line.pvSAN = Array(line.pvSAN.prefix(Caps.maxPVPlies))
                line.pvUCI = Array(line.pvUCI.prefix(Caps.maxPVPlies))
                return line
            }
            return moment
        }
        return copy
    }

    /// Look-up used throughout verification.
    public func moment(id: String) -> Moment? {
        moments.first { $0.momentID == id }
    }

}

// MARK: - Profile

public extension CoachRequest {

    struct Profile: Codable, Sendable, Equatable {
        public var ratingEstimate: Int
        /// Rating deviation. Wide uncertainty is a cue to hedge claims about
        /// the student's level rather than a number to quote at them.
        public var ratingUncertainty: Int
        public var rung: Rung
        public var weeklyFocus: WeeklyFocus
        public var leakTop3: [Leak]

        public init(
            ratingEstimate: Int,
            ratingUncertainty: Int,
            rung: Rung,
            weeklyFocus: WeeklyFocus,
            leakTop3: [Leak]
        ) {
            self.ratingEstimate = ratingEstimate
            self.ratingUncertainty = ratingUncertainty
            self.rung = rung
            self.weeklyFocus = weeklyFocus
            self.leakTop3 = leakTop3
        }
    }

    struct Rung: Codable, Sendable, Equatable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    struct WeeklyFocus: Codable, Sendable, Equatable {
        public var habitID: String
        /// Which step of the thinking algorithm this habit sits in.
        public var stepTag: String
        public var microGoal: MicroGoal

        public init(habitID: String, stepTag: String, microGoal: MicroGoal) {
            self.habitID = habitID
            self.stepTag = stepTag
            self.microGoal = microGoal
        }
    }

    struct MicroGoal: Codable, Sendable, Equatable {
        public var metricID: String
        public var target: Double
        public var current: Double

        public init(metricID: String, target: Double, current: Double) {
            self.metricID = metricID
            self.target = target
            self.current = current
        }
    }

    struct Leak: Codable, Sendable, Equatable {
        public var causeTag: String
        /// Expected points lost per game to this cause.
        public var epLostPerGame: Double
        public var trend: Trend

        public init(causeTag: String, epLostPerGame: Double, trend: Trend) {
            self.causeTag = causeTag
            self.epLostPerGame = epLostPerGame
            self.trend = trend
        }
    }

    enum Trend: String, Codable, Sendable, CaseIterable {
        case improving
        case flat
        case worsening
    }

}

// MARK: - Game

public extension CoachRequest {

    struct Game: Codable, Sendable, Equatable {
        public var result: Result
        public var userColor: Color
        public var accuracyUser: Double
        public var accuracyOpponent: Double
        public var timeControl: String
        public var moveCount: Int
        public var opening: String
        public var phaseAccuracy: PhaseAccuracy

        public init(
            result: Result,
            userColor: Color,
            accuracyUser: Double,
            accuracyOpponent: Double,
            timeControl: String,
            moveCount: Int,
            opening: String,
            phaseAccuracy: PhaseAccuracy
        ) {
            self.result = result
            self.userColor = userColor
            self.accuracyUser = accuracyUser
            self.accuracyOpponent = accuracyOpponent
            self.timeControl = timeControl
            self.moveCount = moveCount
            self.opening = opening
            self.phaseAccuracy = phaseAccuracy
        }

        public enum Result: String, Codable, Sendable, CaseIterable {
            case win
            case loss
            case draw
        }

        public enum Color: String, Codable, Sendable, CaseIterable {
            case white
            case black
        }
    }

    struct PhaseAccuracy: Codable, Sendable, Equatable {
        public var opening: Double
        public var middlegame: Double
        public var endgame: Double

        public init(opening: Double, middlegame: Double, endgame: Double) {
            self.opening = opening
            self.middlegame = middlegame
            self.endgame = endgame
        }
    }

}

// MARK: - Moments

public extension CoachRequest {

    /// One position worth talking about, already judged by the app.
    struct Moment: Codable, Sendable, Equatable {
        public var momentID: String
        public var ply: Int
        /// FEN *before* the student's move. Every line in this moment —
        /// engine PVs and anything the model quotes — is rooted here.
        public var fenBefore: String
        public var phase: Phase
        public var playedSAN: String
        public var playedUCI: String
        public var bestSAN: String
        public var bestUCI: String
        /// Expected points lost, positive.
        public var deltaEP: Double
        public var judgment: Judgment
        /// The app's diagnosis. The model coaches to it, or disputes it
        /// explicitly — it does not silently coach something else.
        public var causeTag: String
        public var stepTag: String
        public var modifiers: [String]
        public var thinkTimeMs: Int
        /// How much this move mattered relative to its neighbours.
        public var criticalityGap: Double
        public var engineLines: [EngineLine]

        public init(
            momentID: String,
            ply: Int,
            fenBefore: String,
            phase: Phase,
            playedSAN: String,
            playedUCI: String,
            bestSAN: String,
            bestUCI: String,
            deltaEP: Double,
            judgment: Judgment,
            causeTag: String,
            stepTag: String,
            modifiers: [String] = [],
            thinkTimeMs: Int,
            criticalityGap: Double,
            engineLines: [EngineLine]
        ) {
            self.momentID = momentID
            self.ply = ply
            self.fenBefore = fenBefore
            self.phase = phase
            self.playedSAN = playedSAN
            self.playedUCI = playedUCI
            self.bestSAN = bestSAN
            self.bestUCI = bestUCI
            self.deltaEP = deltaEP
            self.judgment = judgment
            self.causeTag = causeTag
            self.stepTag = stepTag
            self.modifiers = modifiers
            self.thinkTimeMs = thinkTimeMs
            self.criticalityGap = criticalityGap
            self.engineLines = engineLines
        }

        /// The `best` line, or the first line, if any.
        public var bestLineIndex: Int? {
            engineLines.firstIndex { $0.label == .best } ?? (engineLines.isEmpty ? nil : 0)
        }

        public enum Phase: String, Codable, Sendable, CaseIterable {
            case opening
            case middlegame
            case endgame
        }

        public enum Judgment: String, Codable, Sendable, CaseIterable {
            case inaccuracy
            case mistake
            case blunder
            case missedWin
        }
    }

    /// An engine principal variation.
    ///
    /// This is the *only* source of truth for moves the model may quote.
    /// ``CoachVerifier`` checks quoted lines against `pvUCI` and nothing else.
    struct EngineLine: Codable, Sendable, Equatable {
        public var label: Label
        /// Centipawns from the side-to-move's point of view at `fenBefore`.
        public var evalCp: Int
        public var pvSAN: [String]
        public var pvUCI: [String]

        public init(label: Label, evalCp: Int, pvSAN: [String], pvUCI: [String]) {
            self.label = label
            self.evalCp = evalCp
            self.pvSAN = pvSAN
            self.pvUCI = pvUCI
        }

        public enum Label: String, Codable, Sendable, CaseIterable {
            case best
            case played
            case alt
        }
    }

}

// MARK: - Validation feedback

public extension CoachRequest {

    /// A violation echoed back to the model on the repair attempt.
    struct ValidationError: Codable, Sendable, Equatable {
        public var momentID: String?
        public var field: String
        public var problem: String

        public init(momentID: String?, field: String, problem: String) {
            self.momentID = momentID
            self.field = field
            self.problem = problem
        }

        public init(_ violation: Violation) {
            self.momentID = violation.momentID
            self.field = violation.field
            self.problem = violation.message
        }
    }

}
