//
//  CapturedTray.swift
//  ChessCoach
//
//  Design system — Board readouts.
//

import BoardUI
import ChessKit
import SwiftUI

/// The pieces one side has captured, and how far ahead they are.
///
/// ## Why this earns its space in a training app
///
/// Counting material before committing to a trade is the single habit that
/// separates a 1200 from a 1600, and it is the one nobody practises, because
/// over the board it is invisible work. A board that keeps the count on screen
/// does not do that work *for* the user — the number is the result, not the
/// reasoning — but it does close the feedback loop: make a bad trade and the
/// number moves against you immediately, while the position that caused it is
/// still in front of you.
///
/// ## Why the glyphs are small and grey
///
/// This is a readout, not a scoreboard. The captured pieces sit at caption
/// height in the player's own tone, and the advantage rides as a single `+3`
/// beside them. Anything louder competes with the board, which is the one
/// surface on this screen that is allowed to be loud.
struct CapturedTray: View {

    /// The side whose row this is. The glyphs shown are the pieces *this* side
    /// has captured, which are the other side's losses.
    let side: Piece.Color
    let position: Position
    /// The piece artwork, so the tray matches the board it sits under.
    var renderer: PieceRenderer = .staunty
    /// Big enough to tell a rook from a queen at arm's length.
    ///
    /// Two earlier passes were too small for a reason worth recording: they went
    /// through `PieceView` at face value, and `PieceView` insets every piece to
    /// ``BoardMetrics/pieceScale`` so a board's pieces never touch their square
    /// edges. That inset is correct on a board and pure loss in a readout — it
    /// silently shrank the drawn glyph below the size asked for, so raising the
    /// number kept not working. The view now asks `PieceView` for
    /// `glyphSize / pieceScale` and clips the frame back down, so the *artwork*
    /// is the size this number says.
    var glyphSize: CGFloat = 30

    /// The size handed to `PieceView` so the drawn piece comes out at
    /// ``glyphSize`` after the board inset is applied.
    private var compensatedSize: CGFloat { glyphSize / BoardMetrics.pieceScale }

    /// The most glyphs one tray will draw.
    ///
    /// The overlap below was meant to solve this and does not go far enough. At
    /// ``glyphSize`` 30, with a third of each piece tucked under the last, nine
    /// captures is 188pt of tray; two of those plus the badge and the padding
    /// comes to roughly 434pt, which is wider than any iPhone. Nothing in the
    /// column constrains its width, so what actually happened was that the
    /// *whole screen* grew to fit — the board overflowed both edges and the task
    /// line above it lost its first word.
    ///
    /// The glyphs are the working and the badge is the answer, so dropping the
    /// least valuable of them costs the reader nothing the number does not
    /// already tell them. Accessibility still reads the full list.
    static let maxGlyphs = 5

    private var captured: [Piece.Kind] {
        CapturedMaterial.lost(by: side.opposite, in: position)
    }

    /// Ordered most valuable first by ``CapturedMaterial/lost(by:in:)``, so the
    /// prefix keeps the pieces actually worth looking at.
    private var visibleGlyphs: [Piece.Kind] {
        Array(captured.prefix(Self.maxGlyphs))
    }

    private var advantage: Int {
        CapturedMaterial.advantage(for: side, in: position)
    }

    var body: some View {
        HStack(spacing: 5) {
            // Overlapped slightly: eight pawns in a row is wider than the
            // screen, and a fanned stack reads as "a pile of these" at a glance
            // without needing to be counted.
            //
            // The stack sits on a sunken chip. Size was never this readout's
            // real problem — contrast was: half the time the captured pieces
            // are *white*, and white artwork on the app's near-white page is
            // invisible at any size. The chip puts a mid grey behind every
            // glyph, and the extra drop shadow re-cuts the silhouette that the
            // page was swallowing.
            if !captured.isEmpty {
                HStack(spacing: -glyphSize * 0.34) {
                    ForEach(Array(visibleGlyphs.enumerated()), id: \.offset) { _, kind in
                        PieceView(kind: kind, color: side.opposite, renderer: renderer, size: compensatedSize)
                            .frame(width: glyphSize, height: glyphSize)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.capturedTrayWell.dynamic))
            }

            // Only ever shown to the side that is ahead. A `−3` under the losing
            // player states the same fact twice and puts the worse half of it in
            // front of the person who needs it least.
            //
            // Drawn as a filled badge rather than grey caption text, because the
            // score is the *point* of this row — the glyphs are the working, the
            // number is the answer. As quiet secondary text it was the one thing
            // on the screen nobody could find.
            if advantage > 0 {
                Text(verbatim: "+\(advantage)")
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Palette.accent.dynamic)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        // Reserves its own height whether or not anything has been captured, so
        // the board does not shift down the first time a pawn comes off.
        .frame(height: glyphSize + 2)
    }

    private var accessibilityLabel: String {
        guard !captured.isEmpty else { return "No captures" }
        var counts: [Piece.Kind: Int] = [:]
        for kind in captured { counts[kind, default: 0] += 1 }
        let phrases = CapturedMaterial.fullArmyOrder
            .compactMap { kind -> String? in
                guard let count = counts[kind] else { return nil }
                return "\(count) \(name(for: kind))\(count == 1 ? "" : "s")"
            }
        let list = phrases.joined(separator: ", ")
        return advantage > 0 ? "Captured \(list). Ahead by \(advantage)." : "Captured \(list)."
    }

    private func name(for kind: Piece.Kind) -> String {
        switch kind {
        case .pawn: "pawn"
        case .knight: "knight"
        case .bishop: "bishop"
        case .rook: "rook"
        case .queen: "queen"
        case .king: "king"
        }
    }
}

extension Piece.Color {
    var opposite: Piece.Color { self == .white ? .black : .white }
}

/// Both trays in one row: the user's captures leading, the opponent's trailing.
///
/// Every surface with a live board shows this row — sparring, calibration
/// games, puzzles, drills, review. That is a training decision, not a layout
/// convenience: the app teaches counting material on every trade, and a habit
/// only forms if the readout is in the same place on every board the user ever
/// looks at. One screen that hides it is one screen where the habit lapses.
struct CapturedTrayRow: View {

    /// The side the user is playing (or reviewing from) — shown first.
    let perspective: Piece.Color
    let position: Position

    var body: some View {
        HStack(spacing: 12) {
            CapturedTray(
                side: perspective,
                position: position,
                renderer: BoardAppearance.shared.style.pieceSet
            )
            Spacer(minLength: 8)
            CapturedTray(
                side: perspective.opposite,
                position: position,
                renderer: BoardAppearance.shared.style.pieceSet
            )
        }
    }
}

#Preview("Captured tray") {
    let position = Position(fen: "r1bqk3/pppp1ppp/8/8/8/8/PPP2PPP/RNBQK3 w Qq - 0 1") ?? .standard
    return VStack(alignment: .leading, spacing: 14) {
        CapturedTray(side: .white, position: position)
        CapturedTray(side: .black, position: position)
    }
    .padding()
}
