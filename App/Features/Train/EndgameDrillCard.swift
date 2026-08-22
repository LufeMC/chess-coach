//
//  EndgameDrillCard.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// How a drill family presents itself on the Train screen.
///
/// The catalogue in `EndgameDrills.swift` is the service's: it owns the
/// positions, the move budgets and the pass criteria. This is only the wording,
/// which belongs with the screen that shows it.
///
/// ## There is no card here any more
///
/// The file is named for a 2-up grid of drill tiles that the Train tab no longer
/// has: drills arrive inside a set, chosen by `ConceptScheduler`, rather than as
/// a second thing to pick from a shelf. The tile, its board thumbnail and its
/// mastery ring were left behind compiling and unreachable, which is worse than
/// deleting them — dead UI reads as a surface that exists and reviews as one
/// that is merely broken. The mastery *number* did not go with them: it is the
/// record on the "Your training" row, built from ``DrillMastery`` below.
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
    /// Whether the streak counts whole *sets* rather than single positions,
    /// which is how the KPK gate is measured — six positions to a set, and the
    /// set is clean only if every one of them was.
    var countsSets: Bool = false

    var fraction: Double {
        guard required > 0 else { return 0 }
        return min(1, max(0, Double(cleanStreak) / Double(required)))
    }

    var isMastered: Bool { cleanStreak >= required }

    /// `2 of 3 clean`, or `1 of 2 clean sets`.
    var label: String {
        let unit = countsSets ? "clean sets" : "clean"
        return "\(min(cleanStreak, required)) of \(required) \(unit)"
    }
}
