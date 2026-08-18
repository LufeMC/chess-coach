//
//  TimeErrorDetector.swift
//  AnalysisKit
//

import ChessKit

/// Reports how the clock was involved in an error.
///
/// These findings never become the primary cause on their own — a blunder is a
/// blunder whatever the clock said. They feed the cause tagger's time overlays,
/// which move the *step* being coached: snap-judging a critical position is a
/// candidate-generation problem, not a calculation problem, however deep the
/// tactic was.
public struct TimeErrorDetector: Detector, Sendable {
    public let id = DetectorID.timeError

    public init() {}

    public func detect(_ context: MoveContext) -> [Finding] {
        var findings: [Finding] = []

        if context.didFlag {
            findings.append(
                Finding(
                    detector: id,
                    subtype: .flagged,
                    magnitude: 1,
                    detail: "Ran out of time on this move"
                )
            )
        }

        if let bucket = context.thinkBucket {
            if bucket == .fast, context.isCritical, context.judgment >= .mistake {
                findings.append(
                    Finding(
                        detector: id,
                        subtype: .impulseAtCritical,
                        magnitude: context.criticalityGap,
                        detail: "Moved fast in a critical position"
                    )
                )
            }
            if bucket == .long, context.judgment >= .mistake {
                findings.append(
                    Finding(
                        detector: id,
                        subtype: .blunderAfterLongThink,
                        magnitude: context.deltaEP,
                        detail: "Long think ended in a \(context.judgment)"
                    )
                )
            }
        }

        if context.clockPressure {
            findings.append(
                Finding(
                    detector: id,
                    subtype: .clockPressure,
                    magnitude: context.deltaEP,
                    detail: "Played under clock pressure"
                )
            )
        }

        return findings
    }
}

/// The full detector suite, in a fixed order.
///
/// Order here is presentation only — the cause tagger applies its own priority —
/// but a stable order keeps `secondaryTags` deterministic, which matters for
/// tests and for diffing two analyses of the same game.
public enum DetectorSuite {
    public static let all: [any Detector] = [
        HangingPieceDetector(),
        IgnoredThreatDetector(),
        AllowedTacticDetector(),
        MissedTacticDetector(),
        WrongTradeDetector(),
        KingWeakeningPawnMoveDetector(),
        MissedQuietMoveDetector(),
        EndgameTechniqueDetector(),
        OpeningPrincipleDetector(),
        TimeErrorDetector()
    ]

    /// Runs every detector over one move.
    public static func run(_ context: MoveContext, detectors: [any Detector] = all) -> [Finding] {
        detectors.flatMap { $0.detect(context) }
    }
}
