//
//  PressableButtonStyle.swift
//  ChessCoach
//
//  Design system — Micro-interactions.
//

import BoardUI
import SwiftUI

/// The press response for surfaces that are not chunky buttons: scale to 0.97
/// with a small opacity dip, on ``Motion/snappy``.
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

// MARK: - The chunky button

/// The button chrome: a flat face sitting on a hard lip, and a press that
/// *physically depresses* the face onto the lip.
///
/// This one construction is the whole button system — primary, secondary and
/// node buttons all draw through it, so every tappable thing in the app agrees
/// on its depth, its radius and its travel.
///
/// ## What was kept, and why
///
/// The lip stays. An audit of this file called it the most recognisably
/// Duolingo thing in the app and that is fair, but an extruded control that
/// depresses under a thumb is older and broader than any one product, it is the
/// specific quality the app was praised for, and there is no chess-native
/// substitute that keeps the same tactility. Deleting it would cost more than
/// the resemblance does.
///
/// What went instead is the *radius*: this shape used to be
/// ``CornerRadius/card``, a 16pt candy corner, and now takes the tighter
/// ``CornerRadius/chip``. A button at 12pt still reads as soft to a thumb and
/// stops reading as a sweet. Together with the label change below — see
/// ``ChunkyLabel`` — that is where the borrowed look actually lived.
private struct ChunkyChrome: ViewModifier {
    let fill: DualColor
    let edge: DualColor
    /// Non-nil draws a 2pt border on the face (the secondary/white button).
    let border: DualColor?
    let isPressed: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill.dynamic))
            .overlay {
                if let border {
                    shape.strokeBorder(border.dynamic, lineWidth: 2)
                }
            }
            // Travel: the whole face moves down onto its lip. No scale, no
            // fade — the depth collapsing *is* the feedback. `offset` is
            // visual-only, so the lip drawn against the layout frame below
            // stays put.
            .offset(y: isPressed ? EdgeDepth.control : 0)
            .background(shape.fill(edge.dynamic).offset(y: EdgeDepth.control))
            .animation(Motion.snappy, value: isPressed)
    }
}

/// The label every chunky button wears.
///
/// ## Sentence case, and why it matters more than it sounds
///
/// This used to be `UPPERCASE`, tracked +0.8, at heavy weight. That combination
/// — uppercase, tracked, heavy, rounded, full-width — is not *a* Duolingo
/// detail, it is *the* Duolingo detail, and it sat on every primary action in
/// the app: Start, Continue, Next, Play Petra. Setting the same words in
/// sentence case at bold changes the read of six screens without moving a
/// single element.
///
/// It is also better copy. "Play Petra · ~10 min" is a sentence naming a person
/// and a cost; "PLAY PETRA · ~10 MIN" is the same sentence shouted, and a
/// button that shouts a person's name every day gets tiring long before the
/// habit it is trying to build takes hold.
private struct ChunkyLabel: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
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
            .modifier(ChunkyLabel(tint: .white))
            .modifier(
                ChunkyChrome(
                    fill: Palette.accent,
                    edge: Palette.accentEdge,
                    border: nil,
                    isPressed: configuration.isPressed
                )
            )
    }
}

/// The white bordered button — the second tier. Sky label, card fill,
/// same lip and travel as the primary.
struct SecondaryActionButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ChunkyLabel(tint: Palette.blue.dynamic))
            .modifier(
                ChunkyChrome(
                    fill: Palette.surfaceRaised,
                    edge: Palette.hairline,
                    border: Palette.hairline,
                    isPressed: configuration.isPressed
                )
            )
    }
}

/// A quiet text action — the third tier, for "or do this instead". Flat, sky,
/// sentence case like the two tiers above it.
struct TertiaryActionButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .foregroundStyle(Palette.blue.dynamic)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
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
