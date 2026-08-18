//
//  CoachResponse.swift
//  ClaudeKit
//

import Foundation

/// What the model returns for a coaching pass.
///
/// The shape is the enforcement mechanism. Every move the model wants to show
/// the student is a discrete `{san, uci, plyFromRoot}` record inside a line —
/// never notation embedded in prose — because a structured move can be checked
/// against the engine's PV and a sentence cannot.
public struct CoachResponse: Codable, Sendable, Equatable {

    public var gameNote: GameNote
    public var momentNotes: [MomentNote]
    public var weeklyFocusSuggestion: WeeklyFocusSuggestion
    public var flags: Flags

    public init(
        gameNote: GameNote,
        momentNotes: [MomentNote],
        weeklyFocusSuggestion: WeeklyFocusSuggestion,
        flags: Flags
    ) {
        self.gameNote = gameNote
        self.momentNotes = momentNotes
        self.weeklyFocusSuggestion = weeklyFocusSuggestion
        self.flags = flags
    }

    /// Character limits, mirrored into the JSON schema as `maxLength` and
    /// re-checked by ``CoachVerifier`` — the schema is a strong hint, not a
    /// guarantee, and these numbers are load-bearing for the layout.
    public enum Limits {
        public static let headline = 120
        public static let body = 600
        public static let question = 200
        public static let explanation = 400
        public static let rationale = 200
    }

}

// MARK: - Game note

public extension CoachResponse {

    struct GameNote: Codable, Sendable, Equatable {
        public var headline: String
        public var body: String
        public var tone: Tone

        public init(headline: String, body: String, tone: Tone) {
            self.headline = headline
            self.body = body
            self.tone = tone
        }

        /// Chosen by the model from the result and the student's trend, not by
        /// the app: "encouraging" after a loss they played well is right, and
        /// "direct" after a win they got away with is also right.
        public enum Tone: String, Codable, Sendable, CaseIterable {
            case encouraging
            case direct
        }
    }

}

// MARK: - Moment notes

public extension CoachResponse {

    struct MomentNote: Codable, Sendable, Equatable {
        public var momentID: String

        /// The Socratic lead. Must contain no move notation at all — the point
        /// is the student re-derives the move, and a question that names the
        /// answer isn't a question.
        public var question: String

        public var explanation: String

        /// The line being shown, copied from the start of one provided PV.
        public var keyLine: Line

        /// An optional second line, same rules.
        public var alternativeLine: Line?

        /// Whether the model agrees with the app's `causeTag`.
        public var causeAffirmed: Bool

        /// Set when `causeAffirmed` is false. Fed back into tagging review.
        public var suggestedTag: String?

        public init(
            momentID: String,
            question: String,
            explanation: String,
            keyLine: Line,
            alternativeLine: Line? = nil,
            causeAffirmed: Bool,
            suggestedTag: String? = nil
        ) {
            self.momentID = momentID
            self.question = question
            self.explanation = explanation
            self.keyLine = keyLine
            self.alternativeLine = alternativeLine
            self.causeAffirmed = causeAffirmed
            self.suggestedTag = suggestedTag
        }
    }

    /// A quoted variation.
    struct Line: Codable, Sendable, Equatable {
        /// Index into the moment's `engineLines`. Naming the source is what
        /// makes the line checkable — "which PV did you mean" is not something
        /// we want to infer.
        public var sourcePVIndex: Int
        public var moves: [MoveRef]

        public init(sourcePVIndex: Int, moves: [MoveRef]) {
            self.sourcePVIndex = sourcePVIndex
            self.moves = moves
        }
    }

    /// One move in a quoted line.
    struct MoveRef: Codable, Sendable, Equatable {
        public var san: String
        public var uci: String
        /// Distance from `fenBefore`, starting at 0. Anchors the line to the
        /// root so a "prefix" cannot quietly start three plies in.
        public var plyFromRoot: Int

        public init(san: String, uci: String, plyFromRoot: Int) {
            self.san = san
            self.uci = uci
            self.plyFromRoot = plyFromRoot
        }
    }

}

// MARK: - Weekly focus suggestion & flags

public extension CoachResponse {

    struct WeeklyFocusSuggestion: Codable, Sendable, Equatable {
        public var habitID: String
        public var rationale: String

        public init(habitID: String, rationale: String) {
            self.habitID = habitID
            self.rationale = rationale
        }
    }

    struct Flags: Codable, Sendable, Equatable {
        /// Moment ids whose `causeTag` the model disputes. The app uses this to
        /// audit its own tagger, which is why it is a first-class field rather
        /// than something to mine out of prose.
        public var disagreesWithCauseTag: [String]

        public init(disagreesWithCauseTag: [String] = []) {
            self.disagreesWithCauseTag = disagreesWithCauseTag
        }
    }

}
