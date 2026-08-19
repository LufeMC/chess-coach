//
//  CalibrationBoardSlot.swift
//  ChessCoach
//

import SwiftUI

/// A square grey standing in for the board while the next position is built.
///
/// Square because the board is square. The entire value of a skeleton is that
/// nothing moves when the real content lands, so a bar of guessed height would
/// hand the user a jump — which is strictly worse than the spinner it replaced,
/// because the spinner at least never implied where the content would be.
///
/// It is drawn through the `skeleton(if:placeholder:)` modifier, which keeps the
/// real board in the layout at zero opacity — that is what makes the match exact
/// rather than approximate — and which brings the 200ms grace period with it: a
/// position that loads in one frame shows nothing at all, because a placeholder
/// that flashes reads as a fault.
struct BoardSkeleton: View {

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            SkeletonView(width: side, height: side, cornerRadius: CornerRadius.chip)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The board's geometry with nothing in it.
///
/// Stands in for a `BoardView` that has no position yet, so the skeleton above
/// is measured against the real layout instead of a guess at it.
struct EmptyBoardSlot: View {

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
    }
}

#Preview {
    VStack {
        EmptyBoardSlot()
            .skeleton(if: true) { BoardSkeleton() }
    }
    .padding()
    .background(Palette.surfaceGround.dynamic)
}
