//
//  TodayClimbStrip.swift
//  ChessCoach
//

import BoardUI
import SwiftUI

/// Where the rating is, against where it is going.
///
/// ## Why this exists
///
/// Replacing the winding path with three squares was correct — the three steps
/// repeat daily and a journey was the wrong shape for them — but it removed the
/// one thing the path was genuinely good at: implying somewhere to *get to*. A
/// screen of today-only work is honest and slightly airless.
///
/// This is the honest version of that promise. The app has exactly one purpose,
/// which is to move a rating to 2000, and until now that number appeared
/// nowhere in the product. A path node cannot be reached early or lost; this
/// bar can move backwards, which is the truthful thing about a rating and the
/// reason it is worth watching.
///
/// ## Why the floor is 800 and not zero
///
/// A bar from zero would sit 55% full on the first day and crawl, which
/// flatters the beginner and then bores them for a year. 800 is roughly where a
/// new player who knows the rules lands, so the bar starts near empty and every
/// rung of real progress is visible in it.
struct TodayClimbStrip: View {

    /// Nil until a rating has been read — the strip renders its rails and no
    /// claim, rather than a zeroed bar that would read as "no progress".
    let rating: Int?

    /// The goal. Named here rather than passed in because it is the product's
    /// premise, not a per-screen parameter.
    static let target = 2000
    /// The bottom of the scale. See the type's note on why it is not zero.
    static let floor = 800

    private var progress: Double? {
        guard let rating else { return nil }
        let span = Double(Self.target - Self.floor)
        return min(max(Double(rating - Self.floor) / span, 0), 1)
    }

    private var remaining: Int? {
        guard let rating else { return nil }
        return max(0, Self.target - rating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("The climb")
                    .typeRole(.label, appliesForeground: false)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if let remaining {
                    Text(remaining == 0 ? "Arrived" : "\(remaining) to go")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            track

            HStack {
                Text(verbatim: "\(Self.floor)")
                Spacer(minLength: 8)
                Text(verbatim: "\(Self.target)")
            }
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceSunken.dynamic)

                if let progress {
                    Capsule()
                        .fill(Palette.accent.dynamic)
                        .frame(width: max(6, proxy.size.width * progress))
                }
            }
        }
        .frame(height: 10)
    }

    private var accessibilityLabel: String {
        guard let rating, let remaining else { return "Progress to 2000, not yet measured" }
        return remaining == 0
            ? "Rating \(rating). Target of 2000 reached."
            : "Rating \(rating). \(remaining) points to 2000."
    }
}

#Preview("Climb strip") {
    VStack(spacing: 12) {
        TodayClimbStrip(rating: 1051)
        TodayClimbStrip(rating: 1960)
        TodayClimbStrip(rating: nil)
    }
    .padding()
    .background(Palette.surfaceGround.dynamic)
}
