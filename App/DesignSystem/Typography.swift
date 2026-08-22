//
//  Typography.swift
//  ChessCoach
//
//  Design system — Typography.
//

import SwiftUI

/// The six type roles. A well-built screen uses four to six of these; twelve
/// styles is the most common tell of a screen nobody edited.
///
/// Roles are an enum rather than six loose `Font` constants so that a screen
/// cannot quietly invent a seventh: adding one means editing this file, which
/// is a conversation rather than an accident.
enum TypeRole: Hashable, CaseIterable {

    /// 44pt rounded bold, tracking −0.5. Clock under pressure, hero stat.
    case display
    /// 28pt bold. Screen titles, result headlines.
    case title
    /// 17pt semibold. Card titles, checklist steps.
    case headline
    /// 17pt regular. Sheet copy, explanations.
    case body
    /// 13pt regular, `.secondary`. Metadata, units.
    case caption
    /// 11pt semibold, uppercase, +0.6 tracking, `.secondary`. Section headers.
    case label

    /// The role one tier down, used by ``DenominatorText`` to demote the
    /// denominator. `display` drops two visual steps because 44pt → 28pt is
    /// still shouting; the denominator wants to be an annotation.
    var demoted: TypeRole {
        switch self {
        case .display: .headline
        case .title: .headline
        case .headline: .caption
        case .body: .caption
        case .caption: .label
        case .label: .label
        }
    }

    var size: CGFloat {
        switch self {
        case .display: 44
        case .title: 28
        case .headline: 17
        case .body: 17
        case .caption: 13
        case .label: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display: .heavy
        case .title: .heavy
        case .headline: .bold
        case .body: .medium
        case .caption: .medium
        case .label: .bold
        }
    }

    /// Tracking in points. Negative on display because large bold text sets
    /// loose; positive on labels because uppercase at 11pt sets tight.
    var tracking: CGFloat {
        switch self {
        case .display: -0.5
        case .label: 0.8
        default: 0
        }
    }

    var isUppercase: Bool { self == .label }

    /// Roles that are metadata rather than content default to `.secondary`.
    var prefersSecondaryForeground: Bool {
        self == .caption || self == .label
    }

    /// Everything is rounded.
    ///
    /// The rounded face is doing a specific job: it is the counterweight to
    /// everything else about this app that is severe. Chess is a game people
    /// quit because it made them feel stupid, and a training app set in a
    /// tight grotesque reads like a report card. Rounded at heavy weights is
    /// warm without being childish, and it is the one thing keeping the violet
    /// from tipping from confident into corporate.
    ///
    /// One face, no exceptions — mixing in the default face would split the app
    /// into two voices.
    var design: Font.Design {
        .rounded
    }

    /// The `Font` for this role, before the numeral treatment.
    ///
    /// Sized with `.system(size:)` relative to a text style so Dynamic Type
    /// still scales it — a fixed `.system(size:)` would freeze the app at the
    /// default size, which is an accessibility regression dressed as precision.
    var font: Font {
        Font.system(textStyle, design: design, weight: weight)
    }

    /// The text style each role scales against.
    var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title
        case .headline: .headline
        case .body: .body
        case .caption: .footnote
        case .label: .caption2
        }
    }
}

/// Applies a ``TypeRole``: font, tracking, case, and the secondary foreground
/// that metadata roles carry by default.
struct TypeRoleModifier: ViewModifier {
    let role: TypeRole
    /// Numerals that are *instruments* — clocks, evals, counts that tick — must
    /// not reflow the layout every time a digit changes.
    let monospacedDigits: Bool
    /// Set false where the caller supplies its own foreground.
    let appliesForeground: Bool

    func body(content: Content) -> some View {
        content
            .font(monospacedDigits ? role.font.monospacedDigit() : role.font)
            .tracking(role.tracking)
            .textCase(role.isUppercase ? .uppercase : nil)
            .foregroundStyle(
                appliesForeground && role.prefersSecondaryForeground
                    ? AnyShapeStyle(.secondary)
                    : AnyShapeStyle(.primary)
            )
    }
}

extension View {

    /// Applies one of the six type roles.
    ///
    /// - Parameters:
    ///   - role: the role.
    ///   - monospacedDigits: pass `true` wherever the number changes in place.
    ///     Mandatory on clocks and the eval capsule.
    ///   - appliesForeground: pass `false` to keep your own `foregroundStyle`.
    func typeRole(
        _ role: TypeRole,
        monospacedDigits: Bool = false,
        appliesForeground: Bool = true
    ) -> some View {
        modifier(
            TypeRoleModifier(
                role: role,
                monospacedDigits: monospacedDigits,
                appliesForeground: appliesForeground
            )
        )
    }
}

// MARK: - Section header

/// A section header with an optional right-aligned qualifier in the same
/// small-caps style, dimmer — `TODAY` on the left, `1 OF 3` on the right.
///
/// The qualifier lives here rather than inside the CTA on purpose: a button
/// that says "Continue (1 of 3)" is making the tally part of the promise, and
/// the button cannot deliver on a tally.
struct SectionHeader: View {
    let title: String
    var qualifier: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .typeRole(.label, appliesForeground: false)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let qualifier {
                Text(qualifier)
                    .typeRole(.label, monospacedDigits: true, appliesForeground: false)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Denominator

/// The value/denominator pair, as data.
///
/// Split out from the view so the composition rules — which half is the number,
/// what the screen reader hears, whether a zero is worth showing at all — are
/// testable without rendering anything.
struct Denominator: Equatable, Sendable {

    /// The part that gets the full-size treatment.
    let value: String
    /// The part that drops a tier and goes grey. Already includes its
    /// separator (`"/100"`, `"of 3"`) — the view does not add one.
    let denominator: String

    init(value: String, denominator: String) {
        self.value = value
        self.denominator = denominator
    }

    /// `3` `/100`. The slash form, for scores and ratios.
    static func over(_ value: Int, _ total: Int) -> Denominator {
        Denominator(value: "\(value)", denominator: "/\(total)")
    }

    /// `1` `of 3`. The prose form, for step tallies.
    static func of(_ value: Int, _ total: Int) -> Denominator {
        Denominator(value: "\(value)", denominator: "of \(total)")
    }

    /// `3` `moments`. The noun form, for counts of a thing.
    ///
    /// Pluralises the noun, because "1 moments" is the kind of detail that
    /// tells a user how much care went into everything they cannot see.
    static func count(_ value: Int, singular: String, plural: String? = nil) -> Denominator {
        let plural = plural ?? singular + "s"
        return Denominator(value: "\(value)", denominator: value == 1 ? singular : plural)
    }

    /// `12` `days`. Returns `nil` at zero.
    ///
    /// A `0 day streak` label on first run reads as a failure the user has not
    /// had the chance to earn yet. The absence is the design, so the
    /// impossibility of rendering it is encoded in the type.
    static func streak(_ days: Int) -> Denominator? {
        guard days > 0 else { return nil }
        return .count(days, singular: "day")
    }

    /// What VoiceOver reads: one phrase, not two adjacent numbers.
    var accessibilityText: String {
        denominator.hasPrefix("/")
            ? "\(value) out of \(denominator.dropFirst())"
            : "\(value) \(denominator)"
    }
}

/// Renders a ``Denominator``: value at `role`, denominator one tier down and
/// greyer, baselines aligned.
struct DenominatorText: View {
    let denominator: Denominator
    var role: TypeRole = .title
    /// The tint of the value half. The denominator is always secondary.
    var valueStyle: AnyShapeStyle = AnyShapeStyle(.primary)

    init(
        _ denominator: Denominator,
        role: TypeRole = .title,
        valueStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    ) {
        self.denominator = denominator
        self.role = role
        self.valueStyle = valueStyle
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: role.demoted == .label ? 3 : 4) {
            Text(denominator.value)
                .typeRole(role, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(valueStyle)
                // The number is the one thing on the card that must survive
                // intact. Without this the value is just another flexible text
                // in an HStack, so a long unit competes with it for width and
                // wins: at display size "1051 Rookly rating" broke the rating
                // itself across two lines, reading as "105" over "1". A unit
                // can wrap or truncate and still be understood; a number cannot.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(denominator.denominator)
                .typeRole(role.demoted, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(denominator.accessibilityText)
    }
}
