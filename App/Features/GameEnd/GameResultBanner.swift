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
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hide this and look at the final position")
            }

            Button(action: onContinue) {
                Text(banner.ctaTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(buttonTint)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(iconTint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(iconTint.opacity(0.22), lineWidth: 1)
        )
    }

    /// Win is green. Loss and draw are neutral — a red loss banner would make
    /// red mean "you lost" as well as "advantage lost", and a red X after a
    /// defeat is on the list of things that make an app feel cheap.
    private var iconTint: Color {
        switch banner.kind {
        case .win: .green
        case .loss, .draw: .secondary
        }
    }

    private var buttonTint: Color {
        switch banner.kind {
        case .win: .green
        case .loss, .draw: .accentColor
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
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(.quaternary))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
}
