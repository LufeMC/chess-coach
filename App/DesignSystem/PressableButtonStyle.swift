//
//  PressableButtonStyle.swift
//  ChessCoach
//
//  Design system — Micro-interactions.
//

import SwiftUI

/// The press response every button in the app shares: scale to 0.97 with a
/// small opacity dip, on ``Motion/snappy``.
///
/// A colour change alone is the cheap-feeling option — it is a state swap, and
/// it tells the finger nothing about whether the tap was received or how hard.
/// Scale plus alpha reads as the surface yielding, which is the whole illusion.
///
/// Note the asymmetry: the press is animated *out*, not in. Selection feedback
/// must be instantaneous or it feels laggy; it is the release that gets the
/// spring.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    var pressedOpacity: Double = 0.82

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// The one filled accent button a screen is allowed.
///
/// If a screen needs a second action, it takes ``SecondaryActionButtonStyle``.
/// Two filled buttons on one screen means neither is the answer to "what now",
/// and the user has to read both to find out.
struct PrimaryActionButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeRole(.headline, appliesForeground: false)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(Palette.accent.dynamic)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A bordered, unfilled action.
///
/// Used wherever the action is genuinely optional. A filled button that leads to
/// extra work after the day is done trains people to distrust filled buttons,
/// which costs far more than the one tap it wins.
struct SecondaryActionButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeRole(.headline, appliesForeground: false)
            .foregroundStyle(Palette.accent.dynamic)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .elevation(.raised, cornerRadius: CornerRadius.card)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// A quiet text action — the third tier, for "or do this instead".
struct TertiaryActionButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typeRole(.body, appliesForeground: false)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

extension ButtonStyle where Self == SecondaryActionButtonStyle {
    static var secondaryAction: SecondaryActionButtonStyle { SecondaryActionButtonStyle() }
}

extension ButtonStyle where Self == TertiaryActionButtonStyle {
    static var tertiaryAction: TertiaryActionButtonStyle { TertiaryActionButtonStyle() }
}
