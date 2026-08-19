//
//  EndgameDrillCard.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import SwiftUI
import TrainingCore

/// How a drill family presents itself on the Train screen.
///
/// The catalogue in `EndgameDrills.swift` is the service's: it owns the
/// positions, the move budgets and the pass criteria. This is only the wording,
/// which belongs with the screen that shows it.
///
/// Every entry is a **named pattern** — `Lucena`, `Philidor`, `Two bishops` —
/// and never a numbered level. A level number tells the user how far through a
/// list they are; a name is the thing they will later recognise across the board
/// in a real game, which is the entire point of drilling it.
struct DrillFamilyPresentation: Sendable, Hashable, Identifiable {

    var kind: EndgameDrillKind
    /// Short name, the way a chess player would say it.
    var title: String
    /// The classifier chip.
    var classifier: String
    /// One line on what the drill teaches. Not what it *is* — the title already
    /// says that — but what the user will be able to do afterwards.
    var teaches: String

    var id: EndgameDrillKind { kind }

    /// The family's first position, for the card's thumbnail.
    ///
    /// Read from the service's catalogue rather than duplicated here: a
    /// thumbnail showing a position the drill does not actually start from is a
    /// lie the user only discovers after tapping.
    var thumbnailPosition: Position? {
        EndgameDrill.drills(kind: kind).first.flatMap { Position(fen: $0.fen) }
    }

    static let all: [DrillFamilyPresentation] = [
        DrillFamilyPresentation(
            kind: .kqk,
            title: "Queen mate",
            classifier: "Basic mate",
            teaches: "Shrink the box with the queen, then bring the king up to finish."
        ),
        DrillFamilyPresentation(
            kind: .krk,
            title: "Rook mate",
            classifier: "Basic mate",
            teaches: "Cut the king off a rank at a time and take the opposition."
        ),
        DrillFamilyPresentation(
            kind: .kbbk,
            title: "Two bishops",
            classifier: "Basic mate",
            teaches: "Drive the king to a corner your bishops both cover."
        ),
        DrillFamilyPresentation(
            kind: .kpk,
            title: "King and pawn",
            classifier: "Pawn endgame",
            teaches: "Tell the won pawn endings from the drawn ones before you trade into them."
        ),
        DrillFamilyPresentation(
            kind: .lucena,
            title: "Lucena",
            classifier: "Rook endgame",
            teaches: "Build the bridge so your king can step out and the pawn queens."
        ),
        DrillFamilyPresentation(
            kind: .philidor,
            title: "Philidor",
            classifier: "Rook endgame",
            teaches: "Hold the third rank until the pawn advances, then check from behind."
        )
    ]
}

/// Mastery of one drill family.
struct DrillMastery: Sendable, Hashable {
    /// Consecutive clean runs so far.
    var cleanStreak: Int
    /// Clean runs the curriculum asks for.
    var required: Int

    var fraction: Double {
        guard required > 0 else { return 0 }
        return min(1, max(0, Double(cleanStreak) / Double(required)))
    }

    var isMastered: Bool { cleanStreak >= required }

    /// `2 of 3 clean`.
    var label: String { "\(min(cleanStreak, required)) of \(required) clean" }
}

/// One drill family, as a tile in the 2-up grid.
///
/// Endgame drills are a *separate entry* rather than items mixed into the puzzle
/// queue, and that is a real distinction rather than a filing convenience: a
/// puzzle is one move to find, a drill is a technique played out against an
/// engine for twenty moves. Interleaving them would mean the ten-puzzle counter
/// silently sometimes meant ten minutes and sometimes forty.
///
/// The tile is a thumbnail, a name and a mastery ring, and the whole card is the
/// control — a `Select` button inside a card the size of a thumb is a smaller
/// target than the card it sits in.
///
/// ``DrillFamilyPresentation/teaches`` is carried as the accessibility hint
/// rather than rendered. Two columns leave about 150pt of width, which truncates
/// those sentences mid-word, and half a teaching sentence teaches nothing; the
/// name plus the position is what a tile is for, and the sentence is read once
/// and remembered.
struct EndgameDrillCard: View {

    let family: DrillFamilyPresentation
    let mastery: DrillMastery
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(family.title)
                        .typeRole(.headline)
                        .lineLimit(1)
                    Text(family.classifier)
                        .typeRole(.caption)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    MasteryRing(mastery: mastery)
                    Text(mastery.label)
                        .typeRole(.caption, monospacedDigits: true)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(family.title), \(mastery.label)")
        .accessibilityHint(family.teaches)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let position = family.thumbnailPosition {
            // Hit testing off, so a tap anywhere on the tile reaches the button
            // rather than being swallowed by a board that cannot be played.
            // A still thumbnail: material feedback animates a capture that
            // is not happening here, and a grid of tiles twitching as they
            // scroll reads as a rendering bug.
            BoardView(position: position, style: BoardAppearance.shared.style.showingMaterialFeedback(false))
                .allowsHitTesting(false)
        } else {
            RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                .fill(Palette.surfaceSunken.dynamic)
                .aspectRatio(1, contentMode: .fit)
        }
    }
}

/// Mastery of one drill family, as a ring.
///
/// A ring is right here and wrong for a rating: this is a genuine 0-to-1 share
/// of a small, named requirement — two clean runs, or six — and the count sits
/// beside it in words. The completed state fills the ring and drops a check
/// inside it, the same mark a completed day carries on Today, rather than
/// turning green: green is the eval bar's "advantage gained" and would be a
/// third meaning for one token.
private struct MasteryRing: View {

    let mastery: DrillMastery

    private let size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.surfaceSunken.dynamic, lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: mastery.fraction)
                .stroke(Palette.accent.dynamic, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if mastery.isMastered {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.accent.dynamic)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
        EndgameDrillCard(
            family: DrillFamilyPresentation.all[4],
            mastery: DrillMastery(cleanStreak: 1, required: 2),
            onSelect: {}
        )
        EndgameDrillCard(
            family: DrillFamilyPresentation.all[3],
            mastery: DrillMastery(cleanStreak: 6, required: 6),
            onSelect: {}
        )
    }
    .padding()
}
