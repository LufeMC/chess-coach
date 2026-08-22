//
//  ProfileNumbers.swift
//  ChessCoach
//

import Foundation
import TrainingCore

// MARK: - Why this directory is pure
//
// Everything under `Profile/Logic` imports `Foundation` and `TrainingCore` and
// nothing else — no SwiftUI, no `Database`, no app services. That is what makes
// the interesting parts of this screen (window arithmetic, met/unmet
// evaluation, leak ordering, empty-state selection) exercisable from literals.
// The views and the store reads live one directory up and map database rows
// into these types at the boundary.

extension MetricComparison {

    /// The threshold stated as what the user has to reach, for the
    /// `Hanging pieces 0.8 per 100 moves · need under 1.0` measurement text.
    ///
    /// Words rather than `<` / `≥`. The symbols are compact and exact, and they
    /// are also the reason the row read as a database dump: a ladder row is the
    /// app telling someone what to aim at, and "need under 1.0" is that
    /// sentence where "< 1.0" is its notation.
    var need: String {
        switch self {
        case .lessThan: return "need under"
        case .lessThanOrEqual: return "need at most"
        case .greaterThanOrEqual: return "need at least"
        }
    }
}

extension MetricWindow {

    /// Parses the string form the database stores back into a window.
    ///
    /// The inverse of ``MetricWindow/key``. It lives here rather than in
    /// `TrainingCore` because that package is deliberately I/O-free and has no
    /// reason to know that anything ever round-trips through a text column.
    ///
    /// Returns `nil` for an unrecognised string rather than guessing: a window
    /// written by a newer build should drop out of the snapshot, not silently
    /// masquerade as a window this build understands.
    init?(storageKey: String) {
        if storageKey == "allTime" {
            self = .allTime
            return
        }
        guard storageKey.hasPrefix("last") else { return nil }
        var digits = storageKey.dropFirst("last".count)
        let isDays = digits.hasSuffix("d")
        if isDays { digits = digits.dropLast() }
        guard !digits.isEmpty, let count = Int(digits), count > 0 else { return nil }
        self = isDays ? .lastDays(count) : .lastGames(count)
    }
}
