//
//  TodayStatHeader.swift
//  ChessCoach
//

import BoardUI
import SwiftUI

/// The header: the rating, big, with its movement beside it.
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
/// The streak is not here. It is drawn once, in the week strip below, beside
/// the seven day marks that explain what the number counts — a flame in the
/// header and the same count 150 points lower is two treatments of one number
/// on one screen, and the strip is where the brief puts it.
struct TodayStatHeader: View {

    /// Nil until the rating has actually been read — the header then renders the
    /// rung name alone rather than a placeholder figure that looks measured.
    let rating: Int?
    /// Change since the last recorded rating, if there is one to report.
    var ratingDelta: Int?

    /// The rating scales with the user's text size like everything else. A
    /// fixed 40pt is the one number on the screen that would stay put while the
    /// labels around it grew, which reads as a rendering fault.
    @ScaledMetric(relativeTo: .largeTitle) private var ratingSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Verbatim, always: a rating is an identifier, not a
                    // quantity, and the localised form prints "1,051".
                    Text(verbatim: rating.map { "\($0)" } ?? "—")
                        .font(.system(size: ratingSize, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(Palette.accent.dynamic)

                    if let ratingDelta, ratingDelta != 0 {
                        RatingDelta(value: ratingDelta)
                    }
                }

                // Named for the app, matching the Profile chart's headline
                // unit. The number under it is measured only against Rookly's
                // own opponents — `Docs/humanizer-calibration.md` is explicit
                // that self-play fixes the *spacing* between them and says
                // nothing about the absolute offset, so this ladder can be
                // uniformly a few hundred points away from a rated site and
                // these games would look identical either way. A bare "RATING"
                // beside a 40pt figure invites a club player to read it as the
                // rating they already hold; one word stops that, and the climb
                // strip below says the rest.
                Text("ROOKLY RATING")
                    .typeRole(.label, appliesForeground: false)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            NavigationLink {
                GameLibraryScreen()
            } label: {
                // Labelled, because a clock-arrow glyph is a generic history
                // icon and the game library is otherwise only findable by
                // tapping things. The word matches the title of the screen it
                // opens — a door and its room have to have one name.
                HeaderGlyph(symbol: "clock.arrow.circlepath", label: "Games")
            }
            .accessibilityLabel("Games")

            NavigationLink {
                SettingsScreen()
            } label: {
                HeaderGlyph(symbol: "gearshape.fill", label: "Settings")
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

/// A utility door: the glyph, and the word for what is behind it.
///
/// Both stay dim on purpose — these are doors, not the screen's business — but
/// dim and *unnamed* is a door only a user who already knows the app can find.
private struct HeaderGlyph: View {
    let symbol: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
            Text(label)
                .typeRole(.label, appliesForeground: false)
        }
        .foregroundStyle(DualColor(light: 0xA9A4B5, dark: 0x6B6280).dynamic)
        .frame(minWidth: 30)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

#Preview("Stat header") {
    NavigationStack {
        VStack(spacing: 0) {
            TodayStatHeader(rating: 1066, ratingDelta: 14)
            TodayStatHeader(rating: nil)
            Spacer()
        }
        .background(Palette.surfaceGround.dynamic)
    }
}
