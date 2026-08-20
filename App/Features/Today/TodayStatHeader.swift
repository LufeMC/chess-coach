//
//  TodayStatHeader.swift
//  ChessCoach
//

import BoardUI
import SwiftUI

/// The header: the rating, big, and the streak beside it.
///
/// ## Why this is not a row of counters
///
/// It was, and the row was Duolingo's: a flame with a number, a gem-shaped
/// shield with a number, a couple of utility glyphs pushed to the right. Two
/// problems with that, one cosmetic and one substantive.
///
/// The cosmetic one is that a row of small icon-plus-number pairs across the top
/// of a learning app is the single most imitated component of the last decade,
/// and ours was a faithful copy down to the flame.
///
/// The substantive one is that **it buried the only number this app is about.**
/// Rookly exists to move a rating from wherever it is to 2000. That figure was
/// rendered at the same size as a streak, in a shield borrowed from a gem
/// economy this app does not have and should never grow. So the rating is now
/// the header — set at display size, with the delta beside it — and everything
/// else is subordinate to it, because everything else *is* subordinate to it.
///
/// The streak stays, small, because the habit is real and worth acknowledging.
/// It is a line of text rather than a flame: heat metaphors only escalate, and
/// by day 200 there is nowhere left for a flame to go.
struct TodayStatHeader: View {

    /// Days in a row.
    let streakDays: Int
    /// Nil until the rating has actually been read — the header then renders the
    /// rung name alone rather than a placeholder figure that looks measured.
    let rating: Int?
    /// Change since the last recorded rating, if there is one to report.
    var ratingDelta: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Verbatim, always: a rating is an identifier, not a
                    // quantity, and the localised form prints "1,051".
                    Text(verbatim: rating.map { "\($0)" } ?? "—")
                        .font(.system(size: 40, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent.dynamic)

                    if let ratingDelta, ratingDelta != 0 {
                        RatingDelta(value: ratingDelta)
                    }
                }

                Text("RATING")
                    .typeRole(.label, appliesForeground: false)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if streakDays > 0 {
                StreakBadge(days: streakDays)
            }

            NavigationLink {
                GameLibraryScreen()
            } label: {
                HeaderGlyph(symbol: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Past games")

            NavigationLink {
                SettingsScreen()
            } label: {
                HeaderGlyph(symbol: "gearshape.fill")
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceGround.dynamic)
        .accessibilityElement(children: .contain)
    }
}

/// The signed change since the last rating, with an arrow doing the work colour
/// cannot — the same rule the evaluation tokens follow.
private struct RatingDelta: View {
    let value: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: value > 0 ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .black))
            Text(verbatim: "\(abs(value))")
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .monospacedDigit()
        }
        .foregroundStyle(
            (value > 0 ? Palette.evalPositive : Palette.evalNegative).dynamic
        )
        .accessibilityLabel(value > 0 ? "up \(value)" : "down \(abs(value))")
    }
}

/// The streak, as a number and a word rather than a flame.
private struct StreakBadge: View {
    let days: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: "\(days)")
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .monospacedDigit()
            Text(days == 1 ? "day" : "days")
                .font(.system(.caption, design: .rounded, weight: .bold))
        }
        .foregroundStyle(Palette.gold.dynamic)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Palette.gold.dynamic.opacity(0.14))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days == 1 ? "1 day streak" : "\(days) day streak")
    }
}

/// A utility door, sized to sit under the rating without competing with it.
private struct HeaderGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(DualColor(light: 0xA9A4B5, dark: 0x6B6280).dynamic)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

#Preview("Stat header") {
    NavigationStack {
        VStack(spacing: 0) {
            TodayStatHeader(streakDays: 12, rating: 1066, ratingDelta: 14)
            TodayStatHeader(streakDays: 0, rating: nil)
            Spacer()
        }
        .background(Palette.surfaceGround.dynamic)
    }
}
