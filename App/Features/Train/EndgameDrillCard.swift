//
//  EndgameDrillCard.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// How a drill family presents itself on the Train screen.
///
/// The catalogue in `EndgameDrills.swift` is the service's: it owns the
/// positions, the move budgets and the pass criteria. This is only the wording,
/// which belongs with the screen that shows it.
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

/// Speak's level-card shape, applied to an endgame drill.
///
/// Endgame drills are a *separate entry* rather than items mixed into the puzzle
/// queue, and that is a real distinction rather than a filing convenience: a
/// puzzle is one move to find, a drill is a technique played out against an
/// engine for twenty moves. Interleaving them would mean the ten-puzzle counter
/// silently sometimes meant ten minutes and sometimes forty.
///
/// The footer is mastery, not completion: a short inline bar and `2 of 3 clean`.
/// A ring here would be the donut the conventions rule out, and a percentage
/// would obscure the thing that actually matters — that the runs have to be
/// *consecutive*, so one sloppy attempt sends it back to zero.
struct EndgameDrillCard: View {

    let family: DrillFamilyPresentation
    let mastery: DrillMastery
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(family.title)
                    .font(.headline)

                Text(family.classifier)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))

                Spacer(minLength: 8)

                Button("Select", action: onSelect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Text(family.teaches)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(mastery.isMastered ? Color.green : Color.accentColor)
                            .frame(width: max(0, proxy.size.width * mastery.fraction))
                    }
                }
                .frame(height: 3)

                Text(mastery.label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            .frame(height: 14)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary))
    }
}

#Preview {
    VStack(spacing: 12) {
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
