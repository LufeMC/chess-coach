//
//  TimeModel.swift
//  AnalysisKit
//

import Foundation

/// The clock a game was played at.
public struct TimeControl: Sendable, Equatable, Codable {
    public let baseSeconds: Double
    public let incrementSeconds: Double

    public init(baseSeconds: Double, incrementSeconds: Double) {
        self.baseSeconds = baseSeconds
        self.incrementSeconds = incrementSeconds
    }

    /// Seconds a player can afford per move.
    ///
    /// `(base + 40 × increment) / 45` is the usual estimate: a game is assumed to
    /// last about forty moves' worth of increment, and the total is spread over
    /// forty-five moves so the estimate errs toward "you have less time than you
    /// think".
    public var perMoveBudgetSeconds: Double {
        (baseSeconds + 40 * incrementSeconds) / 45
    }

    public static let blitz5plus0 = TimeControl(baseSeconds: 300, incrementSeconds: 0)
    public static let rapid10plus0 = TimeControl(baseSeconds: 600, incrementSeconds: 0)
    public static let classical = TimeControl(baseSeconds: 5400, incrementSeconds: 30)
}

/// How long a move took, relative to what the clock allows.
public enum ThinkBucket: String, Sendable, Codable, CaseIterable {
    case fast
    case normal
    case long

    /// Floor for the "fast" boundary: below four seconds is snap-judgement
    /// territory even in a classical game.
    public static let fastFloorSeconds = 4.0
    /// Floor for the "long" boundary: forty-five seconds is a real think even in
    /// a game with a tiny budget.
    public static let longFloorSeconds = 45.0

    public static func classify(thinkTimeMs: Int, control: TimeControl?) -> ThinkBucket {
        let seconds = Double(thinkTimeMs) / 1000
        let budget = control?.perMoveBudgetSeconds ?? 0
        if seconds < max(fastFloorSeconds, 0.25 * budget) { return .fast }
        if seconds > max(longFloorSeconds, 2.5 * budget) { return .long }
        return .normal
    }
}
