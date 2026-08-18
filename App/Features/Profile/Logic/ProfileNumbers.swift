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

/// Formats a metric value for display next to its threshold.
///
/// The curriculum's thresholds span four orders of magnitude — `1.0` hanging
/// pieces per 100 moves, `0.55` clean-retry rate, `1350` ladder rating — so a
/// fixed decimal count is wrong for at least one of them. Rule: large values
/// are whole numbers, small ones keep enough decimals to distinguish them from
/// their threshold, and trailing zeros are trimmed so `0.80` reads as `0.8`.
func formatMetricValue(_ value: Double) -> String {
    if abs(value) >= 100 || value == value.rounded() && abs(value) >= 10 {
        return String(format: "%.0f", value)
    }
    let two = String(format: "%.2f", value)
    if two.hasSuffix("0") {
        return String(two.dropLast())
    }
    return two
}

extension MetricComparison {

    /// The mathematical symbol, for the `0.8 / < 1.0` measurement text.
    var symbol: String {
        switch self {
        case .lessThan: return "<"
        case .lessThanOrEqual: return "≤"
        case .greaterThanOrEqual: return "≥"
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
