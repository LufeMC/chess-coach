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
// 3. **One hue, opacity by rank.** Each row carries a full-width 4pt bar whose
//    length is the points it costs, and every bar is the same accent at a lower
//    alpha the further down the table it sits. Multi-hue bars read as a pie
//    chart of blame — the eye starts ranking the *colours* and invents a
//    severity scale nobody encoded. One hue leaves length as the only variable,
//    which is the only variable there is.
//
// 4. **Chips are not on every row.** A badge that appears on 100% of rows
//    conveys tone, not data — so ``LeakImpact/low`` deliberately has no chip.
//    If you find yourself adding one "for consistency", you have just built the
//    thing rule 4 exists to prevent.

extension Habit {

    /// The habit named as a thing you go and practise.
    ///
    /// ``Habit/microGoalTitle`` is an imperative — "Blunder-check every move" —
    /// which is right on a chip the user reads mid-game and wrong on a button,
    /// where an instruction reads as the app telling them off on their way out.
    var trainingNoun: String {
        switch self {
        case .whatChanged: return "reading the last move"
        case .scanThreats: return "threat scanning"
        case .candidatesFirst: return "picking candidates"
        case .calcToQuiet: return "calculating to quiet"
        case .blunderCheck: return "blunder-checking"
        case .kingSafety: return "king safety"
        case .endgameTechnique: return "endgame technique"
        case .convertCleanly: return "converting won positions"
        case .clockDiscipline: return "clock discipline"
        }
    }
}

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

    /// One line saying what the cause actually is, under the title.
    ///
    /// The table's names are necessarily terse — "Positional drift" is a
    /// category, not an explanation — and a user who cannot tell two rows apart
    /// cannot act on either. Written about the move, never about the person.
    var detail: String

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

    /// 0...1 relative to the largest leak in the table. Drives the bar's length
    /// and nothing else — length is the only thing the bar is allowed to say.
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
                detail: detail(for: leak.causeTag),
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

    /// The one-line explanation under a cause's name.
    ///
    /// Every line describes the *move*: "the piece you moved was left where it
    /// could be taken", never "you hang pieces". The distinction is the whole
    /// difference between a diagnosis a user acts on and one they stop opening.
    ///
    /// Two clauses: what happened, then how to catch it. The first half alone
    /// restates the row's own title — "positional drift: several quiet moves
    /// with no plan" is a definition, not a diagnosis — and leaves the user to
    /// take the training button on trust. The second half is the mechanism: the
    /// question to ask, at the moment it would have caught this.
    static func detail(for tag: CauseTag) -> String {
        switch tag {
        case .missedNewThreat:
            return "The opponent's last move created a threat that went unanswered — ask what their move attacks before choosing yours."
        case .ignoredStandingThreat:
            return "A threat that had stood for several moves stayed unanswered — re-check standing threats, not only new ones."
        case .missedForcingIdea:
            return "A check, capture or threat of your own went unplayed — list your checks and captures before quiet moves."
        case .kingExposure:
            return "The king's shelter came apart before the position could afford it — count the attackers aimed at it first."
        case .forcingBias:
            return "A check or capture played because it was forcing — calculate it to a quiet position before playing it."
        case .planlessTrade:
            return "Pieces came off with nothing gained — name what the trade improves before taking."
        case .positionalDrift:
            return "Several quiet moves with no plan behind them — pick a worst-placed piece and give it a square."
        case .miscalculatedTactic:
            return "A calculated line went wrong — at every capture, check for an in-between move before going deeper."
        case .allowedDeepTactic:
            return "A tactic several moves deep landed against you — after your candidate, look for their forcing reply."
        case .miscountedExchange:
            return "The captures on one square were counted wrong — count attackers and defenders, cheapest first."
        case .hungMovedPiece:
            return "The piece you moved was left where it could be taken — before releasing, ask what attacks the square it lands on."
        case .hungLeftPiece:
            return "A piece elsewhere was left undefended — scan your own loose pieces after every move you make."
        case .allowedShallowTactic:
            return "A one or two-move tactic landed against you — check their checks and captures before you commit."
        case .endgameTechnique:
            return "A known endgame method was available and not used — name the technique before starting to calculate."
        case .openingPrinciple:
            return "An opening move against development, the centre, or king safety — develop, castle, then commit a pawn."
        default:
            // An unknown tag still belongs in a table whose job is
            // completeness, and inventing prose for it would be worse than
            // saying only what is known.
            return "Repeated across your recent games."
        }
    }

    /// The label on the button that opens training for a cause.
    ///
    /// Named after the *habit that fixes it* rather than the cause itself, so
    /// the button reads as somewhere to go: "Train blunder-checking" is a
    /// destination, "Train hanging pieces" is a description of the problem with
    /// the word Train in front of it. A generic `Continue` would be worse than
    /// either — the step and what it costs both belong on the button.
    ///
    /// `nil` when the cause has no habit mapped to it, which is the same
    /// condition under which the handoff cannot open a session: the tab switch
    /// carries the habit and nothing else, so a habitless cause lands the user
    /// on Train home with no set. Returning a title here — the old fallback was
    /// "Train this pattern" — put a filled button in front of an action that
    /// silently did nothing, so the absence of a title is what the two surfaces
    /// now key their buttons off.
    static func trainActionTitle(for row: LeakRow) -> String? {
        guard let habit = row.habit else { return nil }
        return "Train \(habit.trainingNoun)"
    }

    /// Alpha for the bar on the row at `rank`, top row first.
    ///
    /// A ramp rather than a palette: the accent stays the accent all the way
    /// down and only its presence fades, so the eye reads "less of the same
    /// thing" instead of "a different kind of thing". The floor keeps the last
    /// row visible — a bar too faint to see is a row the table forgot to draw.
    static func barOpacity(rank: Int) -> Double {
        max(1.0 - Double(max(rank, 0)) * 0.22, 0.34)
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

// MARK: - The reading above the table

/// What the table says taken as a whole: how much is going out, and whether it
/// is going out through one hole or several.
///
/// The shape matters more than the total. A user losing 0.6 expected points a
/// game through one habit has a fortnight of work in front of them; a user
/// losing the same 0.6 through five habits has a general standard-of-play
/// problem and no single thing to practise. Those are different instructions,
/// and a table of numbers alone gives neither.
struct LeakDiagnosis: Sendable, Hashable {

    /// How the loss is distributed.
    enum Shape: Sendable, Hashable {
        case clean
        case concentrated
        case spread

        /// The phrase beside the number, read at a glance.
        ///
        /// The three are parallel statements of *how many holes there are*.
        /// "Clean" was not: beside a figure it read as a grade on the user
        /// rather than as a shape, while the other two described distribution.
        var word: String {
            switch self {
            case .clean: return "Nothing much"
            case .concentrated: return "One cause"
            case .spread: return "Several causes"
            }
        }
    }

    /// Expected points per game currently going out, summed across causes.
    ///
    /// Deliberately **not** a 0–100 composite. A score needs a ceiling, no
    /// ceiling has been measured, and the moment one is invented the number
    /// stops describing the user and starts describing the invention. Expected
    /// points per game is what the analyser actually computes and it is already
    /// in the unit that matters: results.
    var pointsPerGame: Double

    var shape: Shape

    /// One sentence naming the finding.
    var headline: String

    /// The short paragraph under it, which says what to do about it.
    var explanation: String

    /// The digits alone; the unit is carried beside them and one tier down.
    var formattedPoints: String { String(format: "%.2f", pointsPerGame) }

    /// The share of the loss riding on the top row. At or above this, working
    /// anything but the first row is a worse use of the fortnight.
    static let concentrationThreshold = 0.45

    /// Reads a sorted leak table.
    ///
    /// `nil` when there is nothing to read, in which case the section shows its
    /// measurement placeholder rather than a confident sentence about an empty
    /// table.
    static func make(rows: [LeakRow], windowGames: Int) -> LeakDiagnosis? {
        guard let top = rows.first else { return nil }

        let total = rows.reduce(0) { $0 + $1.epLostPerGame }
        let sample = windowGames > 0 ? "your last \(windowGames) games" : "your recent games"
        let points = String(format: "%.2f", total)

        guard total >= LeakTable.mediumImpactThreshold else {
            return LeakDiagnosis(
                pointsPerGame: total,
                shape: .clean,
                headline: "Nothing here is costing you much.",
                explanation: """
                    Across \(sample) these causes cost \(points) points of result a game — \
                    \(Self.unitGloss) — which is not enough to be worth a training block. \
                    Keep playing; this table finds the next one before you feel it.
                    """
            )
        }

        let share = total > 0 ? top.epLostPerGame / total : 0
        guard share >= concentrationThreshold else {
            return LeakDiagnosis(
                pointsPerGame: total,
                shape: .spread,
                headline: "The points are coming off in small pieces.",
                explanation: """
                    Across \(sample) these causes cost \(points) points of result a game — \
                    \(Self.unitGloss) — split fairly evenly between them. Take them from the \
                    top: with nothing dominating, the ordering is the whole of the priority. \
                    \(Self.impactGloss)
                    """
            )
        }

        return LeakDiagnosis(
            pointsPerGame: total,
            shape: .concentrated,
            headline: "\(top.title) is where most of it goes.",
            explanation: """
                Across \(sample) these causes cost \(points) points of result a game — \
                \(Self.unitGloss) — and \(Int((share * 100).rounded()))% of that is the top row \
                alone. Work it first; the rest of the table barely moves until it does. \
                \(Self.impactGloss)
                """
        )
    }

    /// The unit beside every figure in this section.
    ///
    /// **Not "expected points".** That is what the analyser computes — a
    /// win-probability delta — and it is a term a 1200 player has never met; a
    /// chess player reading "pts" reasonably guesses rating points or material,
    /// both of which make `−0.42` nonsense. "Points of result" says what the
    /// scale is in the only currency the user is playing for, and
    /// ``unitGloss`` fixes it exactly.
    /// Spelled "per game" rather than "/ game" because this string is also the
    /// figure's VoiceOver label, and a slash is read out as the word.
    static let unitDenominator = "points of result per game"

    /// What a point *is*, said once on the screen that uses it.
    ///
    /// The number the whole section is sorted by was previously defined nowhere
    /// a sighted reader could find it — only in the VoiceOver label. Naming the
    /// scale is the difference between a headline figure and a decoration: the
    /// user cannot tell whether 0.3 is a lot without knowing that 1 is a whole
    /// win.
    static let unitGloss = "a win is worth 1 point, a draw a half"

    /// The same gloss as a standalone sentence, for surfaces that have no
    /// explanation paragraph to fold it into.
    static let unitSentence = "Points of result: \(unitGloss)."

    /// What the chips on the rows mean, said once rather than on every row.
    static let impactGloss =
        "Anything over \(String(format: "%.2f", LeakTable.highImpactThreshold)) a game is marked High impact."
}

// MARK: - Per-leak history

/// A leak's recent history, bucketed for a sparkline.
///
/// This is the one element on the screen that can say *it is working*. A row
/// reporting "−0.38 a game" is a fact about now; the same row with a shape
/// falling away behind it is evidence that a fortnight of blunder-checking
/// changed something, which is the only argument that survives a bad week.
struct LeakTrend: Sendable, Hashable {

    /// Points of result lost inside each bucket, oldest first, so the sparkline
    /// reads left-to-right the way time does.
    var buckets: [Double]

    /// The span the buckets cover — the span the caller actually looked at, not
    /// a nominal one. See ``make(from:now:observedSince:maximumDays:bucketCount:)``.
    var days: Int

    /// The tallest bucket, which the sparkline scales against. Never zero —
    /// ``make`` refuses to build a trend with nothing in it.
    var peak: Double { buckets.max() ?? 0 }

    /// Says which end is which. Six bars and the bare figure "90 days" leave the
    /// reader to guess whether time runs left-to-right, and a sparkline read
    /// backwards says the opposite of what it means.
    var spanLabel: String {
        days == 1 ? "1 day, oldest first" : "\(days) days, oldest first"
    }

    /// Which way the shape is going, for the accessibility value.
    ///
    /// VoiceOver previously got the span and nothing else — the one element on
    /// the screen that can say "it is working" said nothing at all. Halves
    /// rather than first-versus-last bucket, because a single quiet fortnight
    /// at either end would otherwise decide the verdict.
    var directionLabel: String {
        let half = buckets.count / 2
        guard half > 0 else { return "not enough history to show a direction" }
        let older = buckets.prefix(half).reduce(0, +)
        let newer = buckets.suffix(buckets.count - half).reduce(0, +)
        guard older > 0 else { return "flat over \(days) days" }
        let change = (newer - older) / older
        if change <= -0.15 { return "falling over \(days) days" }
        if change >= 0.15 { return "rising over \(days) days" }
        return "flat over \(days) days"
    }

    /// Occurrences below this cannot make a shape, only a pattern of when the
    /// user happened to sit down and play.
    static let minimumOccurrences = 4

    /// Buckets the occurrences of one cause.
    ///
    /// `nil` rather than a flat line when the evidence is thin: a sparkline is
    /// read as a claim about direction, and a claim about direction drawn from
    /// three moves is the kind of number that makes a user distrust every other
    /// number beside it.
    ///
    /// - Parameter observedSince: The earliest instant the caller's occurrences
    ///   could have come from. `nil` means "assume the full span".
    ///
    /// ## Why the span is not simply ninety days
    ///
    /// It was, and the label said so, while the occurrences behind it came from
    /// the leak horizon — the last twenty analysed games. For anyone playing
    /// daily that is about three weeks, so four of the six buckets were empty
    /// *by construction* and every sparkline on the screen drew the same shape:
    /// nothing, nothing, nothing, nothing, then a surge. A user reading that
    /// sees a habit getting rapidly worse, on the one element of the screen
    /// whose entire job is to be able to say the opposite.
    ///
    /// Bucketing across the window that was actually read fixes both halves.
    /// The shape describes the period it was measured over, and a leading run
    /// of empty buckets now means what it looks like it means — the app looked
    /// there and found nothing, which for a fix four weeks old is exactly the
    /// evidence the user wants.
    static func make(
        from occurrences: [LeakOccurrence],
        now: Date = Date(),
        observedSince: Date? = nil,
        maximumDays: Int = 90,
        bucketCount: Int = 6
    ) -> LeakTrend? {
        guard maximumDays > 0, bucketCount >= 2 else { return nil }

        // Rounded up, so a window of "twenty days and two hours" is described
        // as twenty-one days rather than as twenty days that quietly excludes
        // its own oldest game.
        let observed = observedSince.map { start in
            Int((now.timeIntervalSince(start) / 86_400).rounded(.up))
        }
        let days = min(maximumDays, max(observed ?? maximumDays, 1))

        let span = Double(days) * 86_400
        let bucketSeconds = span / Double(bucketCount)
        var buckets = [Double](repeating: 0, count: bucketCount)
        var counted = 0

        for occurrence in occurrences {
            let age = now.timeIntervalSince(occurrence.playedAt)
            // Inclusive at the far end. Every occurrence in a game is stamped
            // with that game's start, so the oldest game in the window sits
            // exactly on the boundary — an exclusive test would silently drop
            // the whole game the window was sized from.
            guard age >= 0, age <= span else { continue }
            let index = bucketCount - 1 - min(Int(age / bucketSeconds), bucketCount - 1)
            buckets[index] += occurrence.epLost
            counted += 1
        }

        guard counted >= minimumOccurrences, buckets.filter({ $0 > 0 }).count >= 2 else {
            return nil
        }
        return LeakTrend(buckets: buckets, days: days)
    }
}
