//
//  MainTabBar.swift
//  ChessCoach
//
//  Design system — Navigation chrome.
//

import BoardUI
import SwiftUI

/// The flat, icon-only tab bar.
///
/// ## Why this replaces the system bar
///
/// iOS 26's tab bar is a translucent floating capsule. It is a beautiful piece
/// of platform design and it is the single most off-brand element left on the
/// screen: the reference bar is *flat*, sits hard against the bottom edge, has
/// a solid 2pt top border, and carries no text labels at all — just four fat
/// glyphs, each in its own colour, with the selected one sitting in a tinted
/// rounded rect. Nothing about that is expressible as a tint on the system bar,
/// so the system bar is hidden and this is drawn instead.
///
/// ## Why no labels
///
/// Because the reference has none, and four icons this size are not ambiguous.
/// The words do not disappear, though — each button carries its label to
/// VoiceOver, which is the reader that actually needed them.
struct MainTabBar: View {

    @Binding var selection: AppModel.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                MainTabButton(
                    tab: tab,
                    isSelected: selection == tab.value,
                    action: {
                        // A tap on the tab you are already on is not a no-op
                        // worth animating; only a real change gets the spring.
                        guard selection != tab.value else { return }
                        // No haptic. Changing tab is navigation, which
                        // ``Haptics`` excludes by name — and this one was
                        // `pieceLifted`, so the switch a user reaches for to
                        // stop the board buzzing was silencing the tab bar
                        // instead of anything they had touched a piece with.
                        withAnimation(Motion.snappy) { selection = tab.value }
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        // The fill runs past the home indicator; the buttons stop above it.
        // Without the `ignoresSafeArea` the bar floats on a strip of page
        // colour, which is the exact floating look this replaced.
        .background {
            Palette.surfaceRaised.dynamic
                .ignoresSafeArea(edges: .bottom)
        }
        // The bar is separated by a line, not by a shadow or a blur.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.hairline.dynamic)
                .frame(height: 2)
        }
    }
}

/// One tab: its glyph, its colour, and the model value it selects.
///
/// A `CaseIterable` enum rather than four call-site literals so the bar cannot
/// drift out of order or lose a colour when a tab is added.
private enum MainTab: String, CaseIterable, Identifiable {
    case today
    case play
    case train
    case profile

    var id: String { rawValue }

    var value: AppModel.Tab {
        switch self {
        case .today: .today
        case .play: .play
        case .train: .train
        case .profile: .profile
        }
    }

    /// Filled glyphs only, and that rule is load-bearing.
    ///
    /// Two of these were breaking it. `chart.line.uptrend.xyaxis` has no filled
    /// variant at all, so Profile rendered as thin strokes beside three solid
    /// shapes and read as a different icon set; `chart.bar.fill` carries the
    /// same meaning with the same weight as its neighbours.
    ///
    /// `dumbbell.fill` went for a different reason: it is precisely the glyph
    /// the reference app uses for practice, which made the one tab most likely
    /// to be recognised the one most likely to be recognised *as theirs*. A
    /// puzzle piece is what this tab actually opens, and it matches the Puzzles
    /// square on Today.
    var symbol: String {
        switch self {
        case .today: "house.fill"
        case .play: "play.fill"
        case .train: "puzzlepiece.fill"
        case .profile: "chart.bar.fill"
        }
    }

    /// One colour per tab, which is what makes the row read as a set of places
    /// rather than a set of states — but all four drawn from the brand family,
    /// with the violet on Today so the tab you land on is the tab that states
    /// what colour this app is.
    var tint: DualColor {
        switch self {
        case .today: Palette.accent
        case .play: Palette.blue
        case .train: Palette.gold
        case .profile: Palette.coral
        }
    }

    var label: String {
        switch self {
        case .today: "Today"
        case .play: "Play"
        case .train: "Train"
        case .profile: "Profile"
        }
    }
}

private struct MainTabButton: View {
    let tab: MainTab
    let isSelected: Bool
    let action: () -> Void

    /// The selected pill is a fixed size and centred, rather than filling the
    /// button's quarter of the row. A pill as wide as its tap target reads as a
    /// selected *segment* — the wrong control entirely, and the thing that made
    /// these look oversized.
    private static let pillSize = CGSize(width: 62, height: 38)

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 22, weight: .bold))
                // The unselected tone was a pale grey that left three of the
                // four tabs looking disabled rather than merely inactive. This
                // is dark enough to read as a destination you can go to.
                .foregroundStyle(
                    isSelected
                        ? tab.tint.dynamic
                        : DualColor(light: 0x8B8695, dark: 0x7C7490).dynamic
                )
                .frame(width: Self.pillSize.width, height: Self.pillSize.height)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                            .fill(tab.tint.dynamic.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                                    .strokeBorder(tab.tint.dynamic.opacity(0.45), lineWidth: 2)
                            )
                    }
                }
                // The tap target stays the full quarter-width even though the
                // pill does not: a 62pt target in a 98pt slot is a miss waiting
                // to happen.
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview("Tab bar") {
    @Previewable @State var selection: AppModel.Tab = .today
    return VStack {
        Spacer()
        MainTabBar(selection: $selection)
    }
    .background(Palette.surfaceGround.dynamic)
}
