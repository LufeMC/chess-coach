//
//  Palette.swift
//  ChessCoach
//
//  Design system — Colour.
//

import BoardUI
import SwiftUI

/// The app's semantic colour tokens.
///
/// ## Why `DualColor` and not a third convention
///
/// `BoardUI` already solved this exact problem: the package ships no asset
/// catalog, so it needed a value type carrying an explicit light value and an
/// explicit dark value. That type is `DualColor`, it is `public`, and the app
/// already links `BoardUI`. Inventing a parallel `AppColor` here would mean two
/// vocabularies for one idea and a guaranteed drift the first time somebody
/// tunes the board but not the cards. So: import it.
///
/// ## Dark is designed, not computed
///
/// Every pair below has two hand-picked values. None is derived from the other
/// by an opacity multiply or a brightness shift, because that is what produces
/// the muddy inverted look — a saturated red that is legible on white is a
/// vibrating smear on near-black. The dark values are **desaturated and
/// brightened**, and surfaces get *lighter* with elevation rather than darker,
/// since a shadow on black is invisible.
///
/// ## The accent is rationed
///
/// One accent, one use per screen: the primary action and the current
/// selection. Never a section header, never a decorative icon, never a second
/// filled button.
enum Palette {

    // MARK: Accent

    /// The single accent. A cool blue-teal rather than the system blue so the
    /// board's warm squares have something to sit against.
    ///
    /// Dark is lighter *and* less saturated: full-chroma blue on black is the
    /// classic halation problem.
    static let accent = DualColor(light: 0x1F6F8B, dark: 0x63B5CE)

    // MARK: Evaluation

    /// Advantage gained. Never used for "success", "confirm", or "online" —
    /// a semantic colour that means three things means none of them.
    ///
    /// **Always paired with an arrow glyph.** Colour alone fails for the ~8% of
    /// men with a red/green deficiency, which in a chess app is not a rounding
    /// error.
    static let evalPositive = DualColor(light: 0x2E7D52, dark: 0x6FCB93)

    /// Advantage lost. The one meaning red is allowed to carry, app-wide.
    ///
    /// Time pressure routes through ``caution`` plus weight; destructive
    /// actions route through a tinted row inside a sheet. If red also meant
    /// "time low" and "delete", the eval bar would stop being readable.
    static let evalNegative = DualColor(light: 0xB03A34, dark: 0xE8837C)

    /// "Note this", not "alarm". Time pressure, inaccuracies, pending states.
    ///
    /// Saturation is pulled well down deliberately — a fully saturated amber
    /// competes with the accent and reads as an error.
    static let caution = DualColor(light: 0xA9741C, dark: 0xE0B25C)

    // MARK: Surfaces

    /// The page ground. Level 0.
    static let surfaceGround = DualColor(light: 0xF5F4F1, dark: 0x0F1113)

    /// Cards, rows and tiles. Level 1.
    ///
    /// Lighter than the ground in dark mode and *very slightly* lighter in
    /// light mode — elevation is carried by lightness plus a hairline, never a
    /// shadow.
    static let surfaceRaised = DualColor(light: 0xFFFFFF, dark: 0x1B1F23)

    /// A recessed well inside a card: progress track, empty slot, skeleton bed.
    static let surfaceSunken = DualColor(light: 0xE8E6E1, dark: 0x14171A)

    // MARK: Lines

    /// The 1pt border that replaces every card shadow.
    ///
    /// Expressed as an alpha over the ground rather than a solid, so it stays
    /// correct on any surface it is drawn against.
    static let hairline = DualColor(
        light: Color.black.opacity(0.10),
        dark: Color.white.opacity(0.10)
    )

    /// A dashed "not yet" outline — tomorrow's slot, an unfilled step.
    /// Deliberately fainter than ``hairline``: pending is quieter than present.
    static let hairlinePending = DualColor(
        light: Color.black.opacity(0.16),
        dark: Color.white.opacity(0.18)
    )

    /// A day that was missed. A **plain grey**, never red — a gap in the
    /// record, not a wound. This token exists so that nobody has to decide,
    /// per screen, how to draw a miss.
    static let inactiveMark = DualColor(
        light: Color.black.opacity(0.12),
        dark: Color.white.opacity(0.14)
    )

    // MARK: Skeleton

    /// Loading placeholder fill.
    static let skeleton = DualColor(
        light: Color.secondary.opacity(0.12),
        dark: Color.white.opacity(0.08)
    )
}

// MARK: - Resolution

extension DualColor {

    /// A single `Color` that resolves itself per trait collection.
    ///
    /// Without this, every consumer would have to read `@Environment(\.colorScheme)`
    /// and thread it down — which breaks the moment a colour is needed inside a
    /// `ShapeStyle` position, and silently produces the wrong appearance inside
    /// a view whose scheme was overridden by `.colorScheme(_:)` on an ancestor.
    /// A dynamic `UIColor` is the platform's own answer and resolves correctly
    /// in both cases.
    var dynamic: Color {
        #if canImport(UIKit)
            let lightUI = UIColor(light)
            let darkUI = UIColor(dark)
            return Color(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark ? darkUI : lightUI
                }
            )
        #else
            return light
        #endif
    }
}

extension ShapeStyle where Self == Color {
    /// `.fill(.token(Palette.surfaceRaised))` — a `ShapeStyle` position that
    /// still resolves per appearance.
    static func token(_ dual: DualColor) -> Color { dual.dynamic }
}
