//
//  ProfileStyle.swift
//  ChessCoach
//

import SwiftUI

/// The Profile screen's small shared vocabulary.
enum ProfileStyle {

    /// The one colour the impact chips are allowed to use.
    ///
    /// A muted amber, defined in HSB with the saturation pulled well down so it
    /// reads as "note this" rather than "alarm". **It must never become red.**
    /// Impact is orthogonal to good/bad: the chip says "this is where the points
    /// are", which is what expected-points-lost means, and that reframe is the
    /// difference between triage and scolding.
    static let impactAmber = Color(hue: 0.105, saturation: 0.52, brightness: 0.68)

    /// The single desaturated colour every leak hairline is drawn in. One
    /// colour, varying only in width — colour would imply a per-row verdict.
    static let hairline = Color.secondary.opacity(0.45)

    static let cardCornerRadius: CGFloat = 16
}

/// The uppercase, tracked eyebrow used across the app's cards.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

/// A small capsule chip.
struct ProfileChip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.4)
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
                .font(.footnote)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }
}
