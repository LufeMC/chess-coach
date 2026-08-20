//
//  Elevation.swift
//  ChessCoach
//
//  Design system — Depth.
//

import BoardUI
import SwiftUI

/// The three corner radii. There are three, and there are only three.
///
/// A screen with 8, 12, 14, 16 and 20pt radii on it does not look varied, it
/// looks unowned. Sizes are chosen so nesting still reads: a 12pt chip inside a
/// 16pt card keeps a believable concentric relationship.
enum CornerRadius {
    /// Chips, capsule tags, small controls.
    static let chip: CGFloat = 12
    /// Cards, rows, tiles, buttons.
    static let card: CGFloat = 16
    /// Sheets and full-width floating surfaces.
    static let sheet: CGFloat = 24
}

/// The three depth levels, drawn the Rookly way.
///
/// The load-bearing rule: **depth is a border and a lip, never a blur**. A
/// raised card is its fill plus a solid 2pt border plus a 2pt hard shadow-edge
/// under its bottom rim — the same construction as the buttons, so every
/// surface in the app agrees on what "3D" means. Soft drop shadows are reserved
/// for something genuinely lifted by a finger, like a dragged piece.
enum Elevation {
    /// Flat. The page, the board. No fill, no border.
    case ground
    /// Solid fill + solid 2pt border + bottom lip. Cards, rows, tiles.
    case raised
    /// Material, no border. Sheets and capsule toolbars — and *only* where
    /// content actually passes behind, otherwise it is an expensive grey.
    case floating
}

/// How thick the hard bottom lip is on cards and buttons.
enum EdgeDepth {
    /// Cards and passive surfaces.
    static let card: CGFloat = 2
    /// Buttons and tappable nodes — deep enough to visibly depress.
    static let control: CGFloat = 4
}

struct ElevationModifier: ViewModifier {
    let level: Elevation
    let cornerRadius: CGFloat
    /// Override the raised fill — used by selected/tinted rows.
    let fill: DualColor?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch level {
        case .ground:
            content
        case .raised:
            content
                // Face first, lip second: successive `.background`s stack
                // *behind* one another, so the offset lip peeks out under the
                // face's bottom rim. A card here is two stacked shapes,
                // not a blur.
                .background(shape.fill((fill ?? Palette.surfaceRaised).dynamic))
                .background(
                    shape
                        .fill(Palette.hairline.dynamic)
                        .offset(y: EdgeDepth.card)
                )
                .overlay(shape.strokeBorder(Palette.hairline.dynamic, lineWidth: 2))
                .contentShape(shape)
        case .floating:
            content
                .background(.regularMaterial, in: shape)
                .contentShape(shape)
        }
    }
}

extension View {

    /// Applies a depth level and one of the three sanctioned corner radii.
    ///
    /// - Parameters:
    ///   - level: ground, raised, or floating.
    ///   - cornerRadius: use a ``CornerRadius`` constant.
    ///   - fill: overrides the raised fill for tinted rows. Ignored at other
    ///     levels.
    func elevation(
        _ level: Elevation,
        cornerRadius: CGFloat = CornerRadius.card,
        fill: DualColor? = nil
    ) -> some View {
        modifier(ElevationModifier(level: level, cornerRadius: cornerRadius, fill: fill))
    }

    /// A dashed "not yet" container — the visual opposite of a miss.
    ///
    /// Pending conditions get a dashed slot, never an illustrated empty state.
    func pendingOutline(cornerRadius: CGFloat = CornerRadius.card) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Palette.hairlinePending.dynamic,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                )
        )
    }
}
