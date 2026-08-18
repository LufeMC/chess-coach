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
/// looks unowned. Sizes are chosen so nesting still reads: a 10pt chip inside a
/// 16pt card keeps a believable concentric relationship.
enum CornerRadius {
    /// Chips, capsule tags, small controls.
    static let chip: CGFloat = 10
    /// Cards, rows, tiles.
    static let card: CGFloat = 16
    /// Sheets and full-width floating surfaces.
    static let sheet: CGFloat = 22
}

/// The three depth levels.
///
/// The load-bearing rule: **level 1 has no shadow**. Drop shadows on cards is
/// the single most reliable tell of a mid-tier app, and on a dark background
/// they are invisible anyway — so elevation is carried by a solid fill plus a
/// 1pt hairline at 10% alpha. Shadows are reserved for something genuinely
/// lifted by a finger, like a dragged piece.
enum Elevation {
    /// Flat. The page, the board. No fill, no border.
    case ground
    /// Solid fill + 1pt hairline. Cards, rows, tiles.
    case raised
    /// Material, no border. Sheets and capsule toolbars — and *only* where
    /// content actually passes behind, otherwise it is an expensive grey.
    case floating
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
                .background(shape.fill((fill ?? Palette.surfaceRaised).dynamic))
                .overlay(shape.strokeBorder(Palette.hairline.dynamic, lineWidth: 1))
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
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
    }
}
