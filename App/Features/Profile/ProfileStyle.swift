//
//  ProfileStyle.swift
//  ChessCoach
//

import SwiftUI

/// The Profile screen's small shared vocabulary, and its accent budget.
///
/// ## Where the accent goes
///
/// One accent, and on this screen it means **"this is what the reading is
/// about"**. It appears in exactly two places, which are the same claim said
/// twice: the ring on the most recent point (here is where you are) and the
/// leak bars, the status word, and the single filled button beneath them (here
/// is what to do about it).
///
/// Everything else is deliberately monochrome. The selection chrome — metric
/// chips, the range control — is a fill change on ``Palette/surfaceSunken``,
/// because a tinted `3M` is a statement about the chart's window rather than
/// about the user, and it would spend the accent on a control that answers
/// nothing. The plotted line and the period bars are ink, for the same reason a
/// good instrument face is black on white: three tints inside a 176pt box leave
/// the eye nothing to rank.
enum ProfileStyle {

    /// The ink every plotted mark is drawn in.
    ///
    /// The line is quieter than the period bars sitting over it, because the
    /// bars are the reading and the line is the evidence for it.
    static let plotLineOpacity: Double = 0.55

    /// The uncertainty band. Faint enough to be felt rather than measured — a
    /// legible band invites the reader to trace its edge, which is precisely the
    /// precision the band exists to deny.
    static let plotBandOpacity: Double = 0.07

    /// Height of a leak bar. Thick enough to carry a length comparison across
    /// four rows, thin enough that it cannot be mistaken for a progress bar the
    /// user is meant to fill.
    static let leakBarHeight: CGFloat = 4
}

/// The uppercase, tracked eyebrow used across the app's cards.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .typeRole(.label, appliesForeground: false)
            .foregroundStyle(.tertiary)
    }
}

/// A small capsule chip.
struct ProfileChip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .typeRole(.label, appliesForeground: false)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// The honest stand-in for a number that cannot be shown yet.
///
/// Deliberately not a consolation message. It names what is missing and how
/// much more is needed — "Not enough games yet — 3 more to measure this" — and
/// stops there. Reassurance would imply the state warranted distress.
struct MeasurementPlaceholder: View {
    let message: String
    var symbol: String = "clock"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .typeRole(.caption, appliesForeground: false)
            Text(message)
                .typeRole(.caption, appliesForeground: false)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }
}

/// A row of equal-width choices, one of them current.
///
/// The system's segmented `Picker` is not used because its selected segment is
/// a floating white capsule with a shadow under it, which is the one depth
/// treatment the app does not have: level 1 is a hairline, never a shadow. This
/// draws the same control out of the tokens the rest of the screen uses.
struct SegmentedChoice<Option: Hashable & Identifiable>: View {

    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(title(option))
                        .typeRole(.label, monospacedDigits: true, appliesForeground: false)
                        .foregroundStyle(option == selection ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.chip - 2, style: .continuous)
                                .fill(
                                    option == selection
                                        ? Palette.surfaceRaised.dynamic
                                        : Color.clear
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(option == selection ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                .fill(Palette.surfaceSunken.dynamic)
        )
        // Removal is animated, never onset: a selection that eases *in* reads as
        // the control thinking about it.
        .animation(Motion.snappy, value: selection)
    }
}
