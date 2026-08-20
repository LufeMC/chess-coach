//
//  Palette.swift
//  ChessCoach
//
//  Design system — Colour.
//

import BoardUI
import SwiftUI

/// The app's semantic colour tokens — the Rookly palette.
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
/// ## One colour carries the brand
///
/// Every app people describe by its colour has exactly one. The whole system
/// here hangs off ``accent`` — a saturated royal violet — and everything else
/// is either a support role or a semantic that violet is deliberately *not*
/// allowed to take.
///
/// Violet, specifically, for three reasons. It is the one strong hue no chess
/// product has claimed: the category's two giants are green and monochrome, and
/// a green learning app in 2026 reads as a tribute act. It clears 5.8:1 with
/// white text, so the primary button is legible rather than merely loud. And it
/// leaves **green free to mean "correct"** — which in a training app is worth
/// more than any brand consideration, because the one colour a user must never
/// misread is the one that says their move was right.
///
/// ## The rules
///
/// Saturated fills stay saturated in both appearances — a brand colour that
/// desaturates at night stops being the brand. What changes after dark is the
/// ground and the lines, and both carry a violet cast rather than a neutral
/// grey: the brand tints the room, not just the buttons.
///
/// Every filled control carries a matching `…Edge` tone: the hard shadow drawn
/// as the control's bottom lip. That edge is the entire 3D illusion, so it is a
/// token, not a per-screen `opacity()` guess.
enum Palette {

    // MARK: Accent

    /// Royal violet — the brand, the primary action, the "go" of every screen.
    static let accent = DualColor(light: 0x7B2FF7, dark: 0x7B2FF7)

    /// The hard bottom lip under an accent fill.
    static let accentEdge = DualColor(light: 0x5F1FD9, dark: 0x521BBD)

    /// A violet wash for selected rows and tinted chips — the brand at the
    /// weight a *background* is allowed to carry.
    static let accentWash = DualColor(light: 0xF1E9FE, dark: 0x2C1F4A)

    /// Sky — selection, links, secondary-action labels. The one cool support
    /// role, kept clearly bluer than the violet so the two never read as a
    /// gradient of the same idea.
    static let blue = DualColor(light: 0x00A5E5, dark: 0x27B6EE)

    /// The hard bottom lip under a sky fill.
    static let blueEdge = DualColor(light: 0x0087BD, dark: 0x1793C4)

    /// Gold — streaks, crowns, completed path nodes. The reward colour, and the
    /// natural partner to violet: the pairing is older than the app by about
    /// six centuries.
    static let gold = DualColor(light: 0xFFB020, dark: 0xFFB020)

    /// The hard bottom lip under a gold fill.
    static let goldEdge = DualColor(light: 0xDE9410, dark: 0xC9850C)

    /// The streak flame — a warmer, deeper orange than the gold it sits beside.
    static let streakFlame = DualColor(light: 0xFF7A2F, dark: 0xFF7A2F)

    /// Coral — the occasional celebratory accent, and the Profile tab.
    static let coral = DualColor(light: 0xFF4E8A, dark: 0xFF4E8A)

    // MARK: Evaluation

    /// Advantage gained, and the "you were right" green.
    ///
    /// Green means exactly one thing in this app and it is not the brand. That
    /// is the whole reason the brand is violet.
    ///
    /// **Always paired with an arrow or a glyph.** Colour alone fails for the
    /// ~8% of men with a red/green deficiency, which in a chess app is not a
    /// rounding error.
    static let evalPositive = DualColor(light: 0x1B9E52, dark: 0x3ECB7D)

    /// Advantage lost. Cardinal red — the one meaning red carries app-wide.
    static let evalNegative = DualColor(light: 0xE23B36, dark: 0xFF6B66)

    /// "Note this", not "alarm". Time pressure, inaccuracies, pending states.
    static let caution = DualColor(light: 0xE08A00, dark: 0xFFB020)

    // MARK: Surfaces

    /// The page ground. Pages sit on a barely-warm white; after dark on a deep
    /// violet-black, never true black and never a neutral slate — the ground is
    /// where a brand colour does its quietest and most persistent work.
    static let surfaceGround = DualColor(light: 0xFFFFFF, dark: 0x151122)

    /// Cards, rows and tiles. Same white as the ground in light mode — the 2pt
    /// border is what draws the card, not a tone shift.
    static let surfaceRaised = DualColor(light: 0xFFFFFF, dark: 0x211B33)

    /// A recessed well inside a card: progress track, empty slot, skeleton bed.
    static let surfaceSunken = DualColor(light: 0xF3F1F7, dark: 0x1B1629)

    /// The chip behind captured-piece glyphs. Deliberately darker than
    /// ``surfaceSunken`` in the light appearance and lighter than it in the
    /// dark one: the chip's whole job is to contrast with *both* piece colours,
    /// and a well tuned to the page instead of to the pieces left white
    /// captures invisible on a white page.
    static let capturedTrayWell = DualColor(light: 0xDDDBE2, dark: 0x322A47)

    // MARK: Lines

    /// The 2pt solid border that draws every card. Solid, never an alpha wash —
    /// the lines in this system are crisp, and both tones carry a trace of the
    /// brand's violet so a card never reads as a neutral grey box.
    static let hairline = DualColor(light: 0xE6E3EC, dark: 0x392F52)

    /// A dashed "not yet" outline — tomorrow's slot, an unfilled step.
    static let hairlinePending = DualColor(
        light: Color(hex: 0xD9D5E1),
        dark: Color(hex: 0x392F52)
    )

    /// A day that was missed. A **plain grey**, never red — a gap in the
    /// record, not a wound. This token exists so that nobody has to decide,
    /// per screen, how to draw a miss.
    static let inactiveMark = DualColor(light: 0xE6E3EC, dark: 0x392F52)

    /// The grey a locked path node is filled with.
    static let lockedFill = DualColor(light: 0xE6E3EC, dark: 0x392F52)

    /// The hard bottom lip under a locked fill.
    static let lockedEdge = DualColor(light: 0xCFCAD9, dark: 0x2C2440)

    // MARK: Skeleton

    /// Loading placeholder fill.
    static let skeleton = DualColor(
        light: Color.secondary.opacity(0.12),
        dark: Color.white.opacity(0.08)
    )
}

// MARK: - Resolution

extension Color {
    /// `Color(hex: 0xE5E5E5)` — for the few places a `Color` (not `DualColor`)
    /// literal is needed.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

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
