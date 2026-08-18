//
//  LeakPresentation.swift
//  ChessCoach
//

import Foundation
import TrainingCore

// MARK: - Read this before changing how leaks look
//
// This section is a *diagnosis*, and every visual decision in it exists to keep
// it from becoming a scolding. Four rules, all of them deliberate:
//
// 1. **The ordering is the diagnosis.** Rows are sorted by expected points lost
//    per game, descending. That single fact — "this is where the points are" —
//    is the entire message. Everything else is supporting detail.
//
// 2. **No red. Ever.** Impact is orthogonal to good/bad: it says where the
//    leverage is, not that the user is failing. Red converts "here is where to
//    work" into "here is what is wrong with you", and a user who feels accused
//    stops opening the app. The chips are muted amber and grey.
//
// 3. **No bars, no per-row colour.** A full-width saturated bar per row reads as
//    an alarm panel and encodes nothing the number and the ordering do not
//    already carry. The one permitted visual encoding is a 2pt hairline under
//    each row, scaled by magnitude, in a single desaturated colour.
//
// 4. **Chips are not on every row.** A badge that appears on 100% of rows
//    conveys tone, not data — so ``LeakImpact/low`` deliberately has no chip.
//    If you find yourself adding one "for consistency", you have just built the
//    thing rule 4 exists to prevent.

/// How much of the user's result is riding on a leak.
enum LeakImpact: Sendable, Hashable, CaseIterable {
    case high
    case medium
    case low

    /// `nil` for ``low`` — see rule 4 above. This is not an oversight.
    var chipTitle: String? {
        switch self {
        case .high: return "HIGH IMPACT"
        case .medium: return "MEDIUM"
        case .low: return nil
        }
    }
}

/// One occurrence of a leak, for the drill-in list.
struct LeakOccurrence: Sendable, Hashable, Identifiable {
    var id: UUID
    var gameID: UUID
    var playedAt: Date
    var ply: Int
    var playedSAN: String
    var bestSAN: String
    var epLost: Double
    var opponentRating: Int
    var result: String?

    /// Move number as a player counts them: ply 1 and 2 are both move 1.
    var moveNumber: Int { (ply + 1) / 2 }
}

/// One row of the leak table.
struct LeakRow: Sendable, Hashable, Identifiable {

    var id: String { causeTag.rawValue }

    var causeTag: CauseTag
    var title: String

    /// Positive number of expected points lost per game, rendered with a
    /// leading minus. Expected points rather than centipawns because the user
    /// cares about results, and a 200cp slip costs wildly different amounts of
    /// result depending on the position.
    var epLostPerGame: Double

    var count: Int

    /// What a player at this rating typically racks up over the same window.
    ///
    /// **Currently always `nil`.** Nothing in the data layer supplies a
    /// population baseline, and a fabricated one would be the most damaging
    /// number on the screen — it would turn "14 occurrences" into a verdict
    /// against an invented norm. The row renders the reference only when it is
    /// real; see the report for what the data layer would need to provide.
    var typicalCount: Int?

    var impact: LeakImpact

    /// 0...1 relative to the largest leak in the table. Drives the hairline
    /// width only.
    var magnitude: Double

    var habit: Habit?
}

enum LeakTable {

    /// Expected-points-per-game thresholds for the impact buckets.
    ///
    /// Absolute rather than relative to the top row on purpose. A relative
    /// scheme would stamp `HIGH IMPACT` on the largest leak of a user who has
    /// no real leaks left, which is precisely the false alarm this screen is
    /// built to avoid. At 0.20 EP per game, forty games is eight points of
    /// result — genuinely worth a fortnight of work. Below 0.08 it is noise.
    static let highImpactThreshold = 0.20
    static let mediumImpactThreshold = 0.08

    static func impact(epLostPerGame: Double) -> LeakImpact {
        if epLostPerGame >= highImpactThreshold { return .high }
        if epLostPerGame >= mediumImpactThreshold { return .medium }
        return .low
    }

    /// Turns the analyser's output into display rows.
    ///
    /// - Parameter typicalCounts: Population baselines by cause, when the data
    ///   layer has them. Empty today.
    static func rows(
        from leaks: [Leak],
        typicalCounts: [CauseTag: Int] = [:]
    ) -> [LeakRow] {
        // `LeakAnalyzer` already sorts by weighted EP lost, which is the same
        // ordering as per-game EP (they differ by a constant denominator). It is
        // re-sorted here anyway: the ordering *is* the diagnosis, so it should
        // not depend on an upstream implementation detail staying put.
        let sorted = leaks.sorted { lhs, rhs in
            if lhs.epLostPerGame != rhs.epLostPerGame { return lhs.epLostPerGame > rhs.epLostPerGame }
            return lhs.causeTag.rawValue < rhs.causeTag.rawValue
        }

        let peak = sorted.first?.epLostPerGame ?? 0

        return sorted.map { leak in
            LeakRow(
                causeTag: leak.causeTag,
                title: title(for: leak.causeTag),
                epLostPerGame: leak.epLostPerGame,
                count: leak.count,
                typicalCount: typicalCounts[leak.causeTag],
                impact: impact(epLostPerGame: leak.epLostPerGame),
                magnitude: peak > 0 ? min(max(leak.epLostPerGame / peak, 0), 1) : 0,
                habit: leak.habit
            )
        }
    }

    /// How many games the leak table actually rests on.
    ///
    /// Mirrors ``LeakAnalyzer``'s window rule — nominally the last
    /// `leakWindowDays`, extended back until it holds `leakMinimumGames` — so
    /// the header can say `Last 23 games` and be telling the truth. Labelling it
    /// with the number of games *fetched* would overstate the sample every time
    /// the user had a quiet fortnight.
    static func windowSize(
        games: [GameRecord],
        now: Date = Date(),
        tuning: DomainTuning.Focus = DomainTuning.default.focus
    ) -> Int {
        guard !games.isEmpty else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(tuning.leakWindowDays) * 86_400)
        let recent = games.filter { $0.playedAt >= cutoff }.count
        return min(games.count, max(recent, tuning.leakMinimumGames))
    }

    /// User-facing name for a cause.
    ///
    /// Names the behaviour, not the person: "Hanging pieces", not "You hang
    /// pieces". The taxonomy is open (a tag can arrive from a newer build), so
    /// an unknown tag falls back to a de-camel-cased form rather than vanishing
    /// from a table whose whole job is completeness.
    static func title(for tag: CauseTag) -> String {
        switch tag {
        case .missedNewThreat: return "Missed opponent threats"
        case .ignoredStandingThreat: return "Ignored standing threats"
        case .missedForcingIdea: return "Missed forcing ideas"
        case .kingExposure: return "King left exposed"
        case .forcingBias: return "Premature forcing moves"
        case .planlessTrade: return "Planless trades"
        case .positionalDrift: return "Positional drift"
        case .miscalculatedTactic: return "Miscalculated tactics"
        case .allowedDeepTactic: return "Allowed deep tactics"
        case .miscountedExchange: return "Miscounted exchanges"
        case .hungMovedPiece: return "Hanging pieces"
        case .hungLeftPiece: return "Pieces left hanging"
        case .allowedShallowTactic: return "Allowed simple tactics"
        case .endgameTechnique: return "Endgame technique"
        case .openingPrinciple: return "Opening principles"
        default: return humanised(tag.rawValue)
        }
    }

    /// `missedNewThreat` → `Missed new threat`.
    static func humanised(_ rawValue: String) -> String {
        guard !rawValue.isEmpty else { return "Unclassified" }
        var out = ""
        for (index, character) in rawValue.enumerated() {
            if index == 0 {
                out.append(Character(character.uppercased()))
            } else if character.isUppercase {
                out.append(" ")
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }
}
