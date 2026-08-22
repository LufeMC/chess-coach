//
//  ProfileMeasurementState.swift
//  ChessCoach
//

import Foundation

/// Whether a number on this screen can honestly be shown yet.
///
/// The alternative — rendering `0` when nothing has been measured — is worse
/// than useless: a zero blunder rate and an unmeasured blunder rate look
/// identical, and one of them is a lie. Every place this screen would otherwise
/// print a number resolves through here first, and an unmeasured value gets a
/// sentence naming what is missing and how much more is needed.
enum ProfileMeasurementState: Sendable, Hashable {

    case measured

    /// Some evidence, not yet enough.
    case needsMore(have: Int, need: Int, noun: String)

    /// No evidence at all.
    case nothingYet(noun: String)

    /// The numbers are being recomputed and nothing can be said yet.
    ///
    /// Distinct from ``nothingYet`` because on a launch the two render the same
    /// blank screen and only one of them is a fact about the user. A calibrated
    /// player told "no games recorded yet" while the replay runs is being told
    /// something false.
    case measuring

    /// The stored history could not be read.
    ///
    /// Also distinct from ``nothingYet``, and for the same reason: a failed read
    /// on an account with forty games behind it must not assert an absence.
    case unreadable

    /// The sentence shown in place of the number, or `nil` when there is a real
    /// number to show.
    var message: String? {
        switch self {
        case .measured:
            return nil
        case .needsMore(let have, let need, let noun):
            let remaining = max(need - have, 1)
            return "Not enough \(noun) yet — \(remaining) more to measure this"
        case .nothingYet(let noun):
            return "No \(noun) recorded yet"
        case .measuring:
            return "Measuring your recent games…"
        case .unreadable:
            return "Couldn't read your history — pull down to retry"
        }
    }

    var isMeasured: Bool { self == .measured }

    /// Chooses the state for a sample count against a minimum.
    static func forSamples(have: Int, need: Int, noun: String = "games") -> ProfileMeasurementState {
        if have <= 0 { return .nothingYet(noun: noun) }
        if have < need { return .needsMore(have: have, need: need, noun: noun) }
        return .measured
    }

    /// Chooses the state for a chart series.
    ///
    /// Two points is the floor, because one point is not a trend and a chart
    /// showing a single dot invites the reader to imagine the line through it.
    static func forSeries(pointCount: Int, noun: String = "games") -> ProfileMeasurementState {
        forSamples(have: pointCount, need: 2, noun: noun)
    }
}
