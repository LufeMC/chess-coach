//
//  Skill.swift
//  TrainingCore
//

import Foundation

/// The name of a measurable metric.
///
/// `String`-backed so it maps one-to-one onto the loosely-typed `(key, window)`
/// metric rows the database stores. New metrics are a data change here, not a
/// schema migration there.
public struct MetricKey: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
}

/// The span a metric is measured over.
public enum MetricWindow: Sendable, Hashable, Codable {
    case lastGames(Int)
    case lastDays(Int)
    case allTime

    /// The string the database stores in its `window` column.
    public var key: String {
        switch self {
        case .lastGames(let n): return "last\(n)"
        case .lastDays(let n): return "last\(n)d"
        case .allTime: return "allTime"
        }
    }
}

/// How a measured value is compared against a threshold.
///
/// `lessThanOrEqual` is present because several rung-3 and rung-4 gates are
/// stated as "≤" ("≤1 result-flip per 8 rook endings", "≤0.2 advantage-slips
/// per winning game", "zero impulse-at-critical") and encoding those as
/// `lessThan` with a nudged threshold would bury an off-by-epsilon in the data
/// table.
public enum MetricComparison: String, Sendable, Hashable, Codable, CaseIterable {
    case lessThan
    case lessThanOrEqual
    case greaterThanOrEqual

    public func evaluate(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .lessThan: return value < threshold
        case .lessThanOrEqual: return value <= threshold
        case .greaterThanOrEqual: return value >= threshold
        }
    }
}

/// One measurable condition.
public struct SkillCriterion: Sendable, Hashable, Codable {

    public var metricKey: MetricKey
    public var window: MetricWindow
    public var threshold: Double
    public var comparison: MetricComparison

    /// Observations needed before the metric is trusted at all. A 100% success
    /// rate over two attempts is not a 100% success rate.
    public var minimumSamples: Int

    public init(
        metricKey: MetricKey,
        window: MetricWindow,
        threshold: Double,
        comparison: MetricComparison,
        minimumSamples: Int = 0
    ) {
        self.metricKey = metricKey
        self.window = window
        self.threshold = threshold
        self.comparison = comparison
        self.minimumSamples = minimumSamples
    }
}

/// A measurable skill on the curriculum ladder.
///
/// ## Why `criteria` is an array
///
/// The obvious shape is one metric per skill. The curriculum content does not
/// fit it: half the rung gates are conjunctions ("blunders per 100 moves < 4.0
/// **AND** clean-retry rate ≥ 55%", "Lucena and Philidor clean twice **AND**
/// ≤1 result-flip per 8 rook endings"). Splitting each conjunct into its own
/// `Skill` would double the ladder's length, present the user with eight
/// checkboxes per rung instead of five, and — because `isRequired` is per skill
/// — lose the fact that the conjuncts stand or fall together.
///
/// So a skill owns a list of criteria, all of which must hold. The
/// single-criterion case, which is most of them, has a convenience initialiser
/// with exactly the flat shape, and ``metricKey``/``window``/``threshold``/
/// ``comparison`` read through to the first criterion.
public struct Skill: Sendable, Hashable, Codable, Identifiable {

    public var id: String
    public var title: String

    /// All criteria must hold for the skill to be met.
    public var criteria: [SkillCriterion]

    /// Advancement is blocked while a required skill is unmet. Non-required
    /// skills are shown to the user and celebrated, but do not gate — they are
    /// the ones where a legitimate playing style can fail the metric.
    public var isRequired: Bool

    /// The habit that trains this skill, if any.
    ///
    /// This is what lets ``FocusSelector`` honour "pick the habit owning the
    /// largest leak **that maps to a current-rung skill**" — without it, the
    /// weekly focus could recommend work the curriculum is not measuring.
    public var habit: Habit?

    public init(id: String, title: String, criteria: [SkillCriterion], isRequired: Bool, habit: Habit? = nil) {
        self.id = id
        self.title = title
        self.criteria = criteria
        self.isRequired = isRequired
        self.habit = habit
    }

    /// Single-criterion convenience.
    public init(
        id: String,
        title: String,
        metricKey: MetricKey,
        window: MetricWindow,
        threshold: Double,
        comparison: MetricComparison,
        isRequired: Bool,
        habit: Habit? = nil,
        minimumSamples: Int = 0
    ) {
        self.init(
            id: id,
            title: title,
            criteria: [
                SkillCriterion(
                    metricKey: metricKey,
                    window: window,
                    threshold: threshold,
                    comparison: comparison,
                    minimumSamples: minimumSamples
                )
            ],
            isRequired: isRequired,
            habit: habit
        )
    }

    /// The primary criterion's metric, for the common single-criterion skill.
    public var metricKey: MetricKey? { criteria.first?.metricKey }
    public var window: MetricWindow? { criteria.first?.window }
    public var threshold: Double? { criteria.first?.threshold }
    public var comparison: MetricComparison? { criteria.first?.comparison }
}

/// A recorded metric value.
public struct MetricValue: Sendable, Hashable, Codable {
    public var value: Double
    public var sampleCount: Int

    public init(value: Double, sampleCount: Int = 0) {
        self.value = value
        self.sampleCount = sampleCount
    }
}

/// Where a metric lives: its key and the window it was measured over.
public struct MetricAddress: Sendable, Hashable, Codable {
    public var key: MetricKey
    public var window: MetricWindow

    public init(key: MetricKey, window: MetricWindow) {
        self.key = key
        self.window = window
    }
}

/// Everything currently known about the user's measured skills.
///
/// A plain bag of values rather than a query interface: this package does no
/// I/O, so the caller loads whatever the rung's skills reference and hands it
/// over.
public struct MetricSnapshot: Sendable, Hashable {

    public private(set) var values: [MetricAddress: MetricValue]

    public init(_ values: [MetricAddress: MetricValue] = [:]) {
        self.values = values
    }

    public subscript(key: MetricKey, window: MetricWindow) -> MetricValue? {
        get { values[MetricAddress(key: key, window: window)] }
        set { values[MetricAddress(key: key, window: window)] = newValue }
    }

    public mutating func set(_ value: Double, samples: Int = 0, for key: MetricKey, window: MetricWindow) {
        values[MetricAddress(key: key, window: window)] = MetricValue(value: value, sampleCount: samples)
    }

    /// Builder form, for terse test fixtures and previews.
    public func setting(_ value: Double, samples: Int = 0, for key: MetricKey, window: MetricWindow) -> MetricSnapshot {
        var copy = self
        copy.set(value, samples: samples, for: key, window: window)
        return copy
    }
}

/// The outcome of checking one skill.
public struct SkillEvaluation: Sendable, Hashable {

    public var skillID: Skill.ID
    public var isMet: Bool

    /// Criteria that were measured and came up short. These are the actionable
    /// ones — the user is doing the thing, just not well enough yet.
    public var failingCriteria: [SkillCriterion]

    /// Criteria with no recorded value, or too few samples to trust. Reported
    /// separately from failures because the user response is different: "keep
    /// playing" rather than "you are not there yet". Conflating the two makes
    /// a brand-new rung look like a wall of failures.
    public var unmeasuredCriteria: [SkillCriterion]

    public init(
        skillID: Skill.ID,
        isMet: Bool,
        failingCriteria: [SkillCriterion] = [],
        unmeasuredCriteria: [SkillCriterion] = []
    ) {
        self.skillID = skillID
        self.isMet = isMet
        self.failingCriteria = failingCriteria
        self.unmeasuredCriteria = unmeasuredCriteria
    }
}

extension Skill {

    /// Evaluates every criterion against the snapshot.
    ///
    /// A skill with no criteria is vacuously met; a criterion with no data is
    /// not, because "we have never measured this" is not evidence of
    /// competence.
    public func evaluate(in snapshot: MetricSnapshot) -> SkillEvaluation {
        var failing: [SkillCriterion] = []
        var unmeasured: [SkillCriterion] = []

        for criterion in criteria {
            guard let measured = snapshot[criterion.metricKey, criterion.window],
                  measured.sampleCount >= criterion.minimumSamples else {
                unmeasured.append(criterion)
                continue
            }
            if !criterion.comparison.evaluate(measured.value, threshold: criterion.threshold) {
                failing.append(criterion)
            }
        }

        return SkillEvaluation(
            skillID: id,
            isMet: failing.isEmpty && unmeasured.isEmpty,
            failingCriteria: failing,
            unmeasuredCriteria: unmeasured
        )
    }
}
