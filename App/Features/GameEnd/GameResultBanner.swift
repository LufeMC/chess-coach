import SwiftUI

/// Beat 2 of the handoff: the result, with the board still on screen.
///
/// The board is not dimmed, not blurred and not replaced. The player has just
/// finished a game and the first thing they want is to look at the position that
/// ended it — a full-screen result would take that away to show them a sentence
/// they could have read in a bar. So this is a bar, it rises from the bottom
/// edge into space the board was never using, and it carries a way to get out of
/// its own way.
struct GameResultBanner: View {

    let banner: GameEndBanner
    let onCollapse: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: banner.symbolName)
                    .font(.title3)
                    // Semantic foregrounds at full strength, semantic
                    // backgrounds at ~10%.
                    .foregroundStyle(iconTint)
                    .frame(width: 26, height: 26)

                Text(banner.headline)
                    .typeRole(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Put this away and look at the final position")
            }

            Button(banner.ctaTitle, action: onContinue)
                .buttonStyle(.primaryAction)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sheet, style: .continuous)
                .fill(backgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sheet, style: .continuous)
                .strokeBorder(borderTint, lineWidth: 1)
        )
    }

    /// Win is green. Loss and draw are neutral — a red loss banner would make
    /// red mean "you lost" as well as "advantage lost", and a red X after a
    /// defeat is on the list of things that make an app feel cheap.
    private var iconTint: Color {
        switch banner.kind {
        case .win: Palette.evalPositive.dynamic
        case .loss, .draw: .secondary
        }
    }

    private var backgroundTint: Color {
        switch banner.kind {
        case .win: Palette.evalPositive.dynamic.opacity(0.10)
        case .loss, .draw: Palette.surfaceRaised.dynamic
        }
    }

    private var borderTint: Color {
        switch banner.kind {
        case .win: Palette.evalPositive.dynamic.opacity(0.22)
        case .loss, .draw: Palette.hairline.dynamic
        }
    }
}

/// What the banner collapses to: one small capsule, still reachable, never in
/// the way of the position.
struct GameResultChip: View {

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                Text(title)
                    .typeRole(.caption, appliesForeground: false)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Palette.surfaceRaised.dynamic))
            .overlay(Capsule().strokeBorder(Palette.hairline.dynamic, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }
}

#Preview("Banner") {
    VStack(spacing: 16) {
        GameResultBanner(
            banner: GameEndBanner.make(
                outcome: .init(result: "1-0", termination: "checkmate", userWon: true),
                opponentName: "Oscar"
            ),
            onCollapse: {},
            onContinue: {}
        )
        GameResultBanner(
            banner: GameEndBanner.make(
                outcome: .init(result: "0-1", termination: "timeout", userWon: false),
                opponentName: "Oscar"
            ),
            onCollapse: {},
            onContinue: {}
        )
        GameResultChip(title: "Summary", action: {})
    }
    .padding()
    .background(Palette.surfaceGround.dynamic)
}
