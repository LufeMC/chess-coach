//
//  CheckerMotif.swift
//  ChessCoach
//
//  Design system — The signature mark.
//

import SwiftUI

/// A checkerboard fading into the corner of a filled surface.
///
/// ## Why the app needs one of these
///
/// Every element of this design system is defensible on its own and none of
/// them are *ours*: a saturated brand colour, a hard bottom lip, a rounded
/// heavy face and a unit banner describe a dozen apps, and the most famous of
/// them is a language course. The colour separates us from that app. This
/// separates us from the category.
///
/// It is the cheapest possible signature — no illustration to commission, no
/// asset to ship, nothing to localise — and it says the one thing about this
/// product that no colour can: *this is chess*. It also earns its place
/// semantically. The banner it sits on is the curriculum rung, and the rung is
/// measured in board understanding, so a board is the honest ornament.
///
/// ## Why it is nearly invisible
///
/// At 7% white it is felt more than seen, which is the correct weight for
/// ornament sitting behind a title that has to be read. A motif you notice on a
/// screen you open every day becomes a motif you resent by Thursday. The
/// gradient mask is what keeps it out of the text's way: full strength in the
/// far corner, gone entirely before it reaches the words.
struct CheckerMotif: View {

    /// Edge length of one square.
    var squareSide: CGFloat = 26
    /// Opacity of the filled squares. Tuned against the brand violet; a lighter
    /// fill would need less.
    var opacity: Double = 0.07
    /// Which corner the pattern is anchored to.
    var alignment: Alignment = .topTrailing

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / squareSide))
            let rows = Int(ceil(size.height / squareSide))
            let fill = GraphicsContext.Shading.color(.white.opacity(opacity))

            for row in 0..<rows {
                for column in 0..<columns {
                    // Only every other cell, which is what makes it a board and
                    // not a grid.
                    guard (row + column).isMultiple(of: 2) else { continue }
                    let rect = CGRect(
                        x: CGFloat(column) * squareSide,
                        y: CGFloat(row) * squareSide,
                        width: squareSide,
                        height: squareSide
                    )
                    context.fill(Path(rect), with: fill)
                }
            }
        }
        .mask {
            // Strongest in the anchored corner, gone before it reaches the
            // content. `startPoint` is the corner the pattern survives in.
            LinearGradient(
                colors: [.white, .white.opacity(0)],
                startPoint: maskStart,
                endPoint: maskEnd
            )
        }
        .allowsHitTesting(false)
    }

    private var maskStart: UnitPoint {
        switch alignment {
        case .topLeading: .topLeading
        case .bottomTrailing: .bottomTrailing
        case .bottomLeading: .bottomLeading
        default: .topTrailing
        }
    }

    private var maskEnd: UnitPoint {
        switch alignment {
        case .topLeading: .bottomTrailing
        case .bottomTrailing: .topLeading
        case .bottomLeading: .topTrailing
        default: .bottomLeading
        }
    }
}

extension View {

    /// Lays the signature checker into a filled surface, clipped to its shape.
    ///
    /// Applied *over* the fill and *under* the content, so it never sits on top
    /// of a glyph or a letterform.
    func checkerMotif(
        cornerRadius: CGFloat = CornerRadius.card,
        squareSide: CGFloat = 26,
        opacity: Double = 0.07
    ) -> some View {
        background {
            CheckerMotif(squareSide: squareSide, opacity: opacity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

#Preview("Checker motif") {
    VStack(spacing: 16) {
        Text("Board Vision")
            .font(.system(.title3, design: .rounded, weight: .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .checkerMotif()
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(Palette.accent.dynamic)
            )
    }
    .padding()
}
