//
//  TrainingMetricKeys.swift
//  ChessCoach
//

import Database
import Foundation
import TrainingCore

// MARK: - Why counters live in the metrics table
//
// Several things the training loop needs are *running totals over the whole
// history*: how many puzzles of theme X at 1200+ the user has attempted and
// solved, how long the median solver takes on a rating band, how many new cards
// were admitted today, how long each drill's clean streak is.
//
// None of them justifies a table. They are all a `(key, window) -> (value,
// sampleCount)` pair, which is precisely what `skillMetrics` already is, and
// which the persistence layer already syncs and de-duplicates. Adding four
// tables to store four numbers would be a schema migration and a CloudKit
// change to buy nothing.
//
// The keys are namespaced so a reader can tell a *stored counter* from a
// *computed curriculum metric* at a glance: computed ones are named by
// `TrainingCore.MetricKey`, counters live under the prefixes below.

enum TrainingMetricKeys {

    /// Window string for anything that is a lifetime total.
    static let allTime = MetricWindow.allTime.key

    // MARK: New-card cap

    /// New cards admitted on a given day, so the daily cap survives more than
    /// one session in a day.
    ///
    /// The window is the day key, which is exactly the granularity the cap is
    /// defined at and makes yesterday's count fall out of scope for free.
    static let newCardsAdmitted = "cards.newAdmitted"

    // MARK: Latency bands

    static func latencyMedian(band: Int) -> String { "puzzle.latencyMedianMs.band\(band)" }

    // MARK: Puzzle theme success

    /// Attempts on puzzles carrying `theme` rated at or above `floor`.
    static func themeAttempts(_ theme: ThemeTag, ratingFloor: Int) -> String {
        "puzzle.themeAttempts.\(theme.rawValue)@\(ratingFloor)"
    }

    /// Solves among those attempts.
    static func themeSolves(_ theme: ThemeTag, ratingFloor: Int) -> String {
        "puzzle.themeSolves.\(theme.rawValue)@\(ratingFloor)"
    }

    // MARK: Retry

    /// Failed positions re-played cleanly, and the number of failures. Feeds
    /// `MetricKey.cleanRetryRate`.
    static let cleanRetrySuccesses = "retry.cleanSuccesses"
    static let cleanRetryAttempts = "retry.attempts"
}

// MARK: - Band latency medians

/// Tracks the median solve time per rating band.
///
/// `AutoGrader` normalises latency against "the median for puzzles of this
/// rating band", which is the difference between eight seconds meaning *fast*
/// and meaning *slow*. There is no shipped table of solver medians, and storing
/// every sample to compute a real median would grow without bound.
///
/// So the median is *estimated* with Frugal-1U: one number per band, nudged up
/// when a sample lands above it and down when it lands below. Frugal-1U provably
/// converges on the median of a stationary stream, which is exactly the shape of
/// this data. The one deviation from the published algorithm is the step size:
/// the paper's fixed step of 1 would take tens of thousands of puzzles to travel
/// from a seed of 8s to a true median of 25s, so the step is a fraction of the
/// current estimate instead, which converges in tens of samples and still
/// settles because the step shrinks as the estimate does.
enum LatencyBandMedian {

    /// Fraction of the current estimate each sample can move it.
    static let stepFraction = 0.06
    /// Floor on the step, so an implausibly small estimate cannot freeze.
    static let minimumStepMs = 150.0

    /// The seed for a band with no samples yet.
    ///
    /// Rises with difficulty because it must: an 800-rated puzzle that takes
    /// forty seconds is slow and a 2000-rated one that takes forty seconds is
    /// fast, and seeding both at the same number would grade half the corpus
    /// wrong until enough samples arrived to correct it.
    static func seed(band: Int) -> Double {
        min(60_000, 7_000 + Double(band) * 1_500)
    }

    /// One Frugal-1U step.
    static func updated(estimate: Double, sample: Double) -> Double {
        let step = max(minimumStepMs, estimate * stepFraction)
        if sample > estimate { return estimate + step }
        if sample < estimate { return estimate - step }
        return estimate
    }
}

// MARK: - Counter helpers

extension MetricStore {

    /// Reads a stored counter, or `nil` when it has never been written.
    func counter(_ key: String, window: String = TrainingMetricKeys.allTime) -> SkillMetric? {
        try? metric(key: key, window: window)
    }

    /// Reads a counter's value with a default.
    func value(_ key: String, window: String = TrainingMetricKeys.allTime, default fallback: Double = 0) -> Double {
        counter(key, window: window)?.value ?? fallback
    }

    /// Adds `amount` to a counter and bumps its sample count.
    func increment(
        _ key: String,
        window: String = TrainingMetricKeys.allTime,
        by amount: Double = 1,
        at date: Date = Date()
    ) throws {
        let existing = counter(key, window: window)
        try upsert(
            key: key,
            window: window,
            value: (existing?.value ?? 0) + amount,
            sampleCount: (existing?.sampleCount ?? 0) + 1,
            updatedAt: date
        )
    }

    /// Overwrites a counter.
    func set(
        _ key: String,
        window: String = TrainingMetricKeys.allTime,
        value: Double,
        sampleCount: Int = 0,
        at date: Date = Date()
    ) throws {
        try upsert(key: key, window: window, value: value, sampleCount: sampleCount, updatedAt: date)
    }
}
