import Foundation

// MARK: - Typed views over loosely-stored columns
//
// These enums are *not* used as column types. The columns are `String`, and
// these give call sites a spell-checked vocabulary on top.
//
// The distinction matters for sync: if `Game.mode` were typed as `GameMode`,
// a row synced down from a device running a newer build with a mode this build
// has never seen would fail to decode and the whole record would be dropped.
// Storing `String` means the record round-trips intact and only the *typed
// accessor* returns `nil`, which callers can handle as "unknown, show a
// fallback" instead of "data lost".

/// How a game was played.
public enum GameMode: String, CaseIterable, Sendable, Hashable, Codable {
    /// Free play against a tuned engine personality.
    case sparring
    /// Play with coaching prompts and hints.
    case guided
    /// A rating-placement game.
    case calibration
}

public enum PlayerColor: String, CaseIterable, Sendable, Hashable, Codable {
    case white
    case black

    public var opposite: PlayerColor { self == .white ? .black : .white }
}

/// Progress of post-game engine analysis.
public enum AnalysisState: String, CaseIterable, Sendable, Hashable, Codable {
    case pending
    case running
    case complete
    case failed
}

/// Standard PGN result strings.
public enum GameResult: String, CaseIterable, Sendable, Hashable, Codable {
    case whiteWins = "1-0"
    case blackWins = "0-1"
    case draw = "1/2-1/2"

    public func isWin(for color: PlayerColor) -> Bool {
        switch (self, color) {
        case (.whiteWins, .white), (.blackWins, .black): return true
        default: return false
        }
    }
}

/// Lifecycle of a coachable moment.
public enum MomentStatus: String, CaseIterable, Sendable, Hashable, Codable {
    /// Extracted but not yet shown.
    case new
    /// Shown to the user and worked through.
    case reviewed
    /// Promoted into the spaced-repetition deck.
    case scheduled
    /// Explicitly dismissed.
    case dismissed
}

public enum SRSCardKind: String, CaseIterable, Sendable, Hashable, Codable {
    /// Card backed by a puzzle from the bundled corpus.
    case puzzle
    /// Card backed by a position lifted from one of the user's own games.
    case momentPosition
}

/// FSRS scheduler states.
public enum SRSState: String, CaseIterable, Sendable, Hashable, Codable {
    case new
    case learning
    case review
    case relearning
}

/// The four-button FSRS grading scale.
public enum ReviewRating: Int, CaseIterable, Sendable, Hashable, Codable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    /// Clamps an arbitrary integer into the scale.
    ///
    /// Used when reading values that may have originated on another device; a
    /// rating outside 1...4 is pinned rather than rejected.
    public init(clamping raw: Int) {
        self = ReviewRating(rawValue: min(max(raw, 1), 4)) ?? .good
    }

    public var isLapse: Bool { self == .again }
}
