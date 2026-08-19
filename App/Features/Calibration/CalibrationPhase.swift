//
//  CalibrationPhase.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// The two kinds of work calibration asks for.
enum CalibrationPhase: Int, CaseIterable, Sendable, Hashable, Identifiable {

    case games
    case puzzles

    var id: Int { rawValue }

    /// Name shown in the header's disclosure.
    var title: String {
        switch self {
        case .games: "Calibration games"
        case .puzzles: "Calibration puzzles"
        }
    }

    /// Singular noun for the counter: `Game 3 of 5`.
    var itemNoun: String {
        switch self {
        case .games: "Game"
        case .puzzles: "Puzzle"
        }
    }

    var step: CalibrationStep {
        switch self {
        case .games: .games
        case .puzzles: .puzzles
        }
    }
}

/// The four steps the user walks through, in order.
///
/// ## Why these are not the phases
///
/// ``CalibrationPhase`` names the two stretches that ask for *work*, which is
/// what a progress bar needs. It is not what a first-run user needs, because it
/// silently omits the two steps that bracket them: the question at the front and
/// the result at the back. A flow that says `Game 3 of 5` has answered "where am
/// I in this part" and left "how much of this is there" to be guessed — and the
/// guess someone makes on their first three minutes with an app is always the
/// pessimistic one, because they have no floor for it.
///
/// So every calibration screen, including the question and the reveal, carries
/// `Step n of 4`. The number never moves backwards and the last step is the
/// payoff, which is the shortest way to say that none of this is a detour.
enum CalibrationStep: Int, CaseIterable, Sendable, Hashable, Identifiable {

    case question
    case games
    case puzzles
    case result

    var id: Int { rawValue }

    /// 1-based position, for `Step 2 of 4`.
    var position: Int { rawValue + 1 }

    /// How many steps there are, so the denominator has one source.
    static var count: Int { allCases.count }

    /// Name in the step list, and on the two screens that have no item counter.
    var title: String {
        switch self {
        case .question: "Your experience"
        case .games: "Games"
        case .puzzles: "Puzzles"
        case .result: "Your rating"
        }
    }

    /// What this step contributes to the measurement.
    ///
    /// Shown in the expanded step list, because the question the disclosure is
    /// really being asked is not "how many are left" but "is any of this
    /// optional". Every line answers that the same way: it is all one number.
    var contribution: String {
        switch self {
        case .question: "Sets the difficulty the first game starts at."
        case .games: "Measures playing strength directly, with wide error."
        case .puzzles: "Measures tactics precisely, then converts to the playing scale."
        case .result: "Both halves, combined into one rating and a starting rung."
        }
    }
}

/// Progress across the whole calibration flow.
///
/// ## Why not one bar
///
/// Twenty-five items behind a single bar is the worst of both worlds: each item
/// moves it four percent, so it looks stuck, and it flattens two genuinely
/// different kinds of work — five ten-minute games and twenty ten-second puzzles
/// — into one undifferentiated length. `Docs/design-conventions.md` lists that
/// exact pattern as one to avoid.
///
/// So progress is expressed twice, and the two answer different questions:
///
/// * **The header** (`Game 3 of 5 — Calibration games`) answers "where am I in
///   the thing I am doing right now", which is the question a user actually has
///   mid-flow. SoFi's pattern, including the tappable phase name — a disclosure
///   is the cheapest possible way to answer "how much more of this is there"
///   without putting the answer permanently on screen.
/// * **The sectioned bar** answers "how much of the whole thing is left", and
///   answers it structurally: one section per phase, hairline gaps between them,
///   and only the current section filling. The user reads *both* "most of the
///   way through part 1" and "there are two parts" from one glance.
struct CalibrationProgress: Sendable, Hashable {

    /// Items required by each phase, in phase order.
    var required: [Int]
    /// Items finished in each phase.
    var completed: [Int]
    /// The phase the user is in.
    var phaseIndex: Int

    init(
        required: [Int] = [
            DomainTuning.default.calibration.gameCount,
            DomainTuning.default.calibration.puzzleCount
        ],
        completed: [Int] = [0, 0],
        phaseIndex: Int = 0
    ) {
        self.required = required
        self.completed = completed
        self.phaseIndex = phaseIndex
    }

    var phase: CalibrationPhase {
        CalibrationPhase(rawValue: min(phaseIndex, CalibrationPhase.allCases.count - 1)) ?? .games
    }

    var currentRequired: Int { required.indices.contains(phaseIndex) ? required[phaseIndex] : 0 }
    var currentCompleted: Int { completed.indices.contains(phaseIndex) ? completed[phaseIndex] : 0 }

    /// The item being *worked on*, so it reads 1 before the first game rather
    /// than 0.
    var currentPosition: Int {
        min(currentCompleted + 1, max(currentRequired, 1))
    }

    /// `Game 3 of 5`.
    var counterLabel: String {
        "\(phase.itemNoun) \(currentPosition) of \(currentRequired)"
    }

    /// Fill of each section, 0...1.
    ///
    /// Phases before the current one are full, the current one is partial, and
    /// phases after it are empty — never partially filled by a lookahead, which
    /// would suggest work has happened that has not.
    var sectionFractions: [Double] {
        required.indices.map { index in
            if index < phaseIndex { return 1 }
            if index > phaseIndex { return 0 }
            let total = required[index]
            guard total > 0 else { return 0 }
            let done = completed.indices.contains(index) ? completed[index] : 0
            return min(1, max(0, Double(done) / Double(total)))
        }
    }

    /// Relative widths of the sections.
    ///
    /// Equal, deliberately, even though one phase holds five items and the other
    /// twenty. The bar's job is to show that the flow *has parts*; sizing them
    /// by item count would shrink the games section to a stub and make the first
    /// phase — the long one in wall-clock time — look like a rounding error.
    var sectionWeights: [Double] { required.map { _ in 1 } }

    var isComplete: Bool {
        zip(required, completed).allSatisfy { $1 >= $0 }
    }

    // MARK: Mutation

    /// Records one finished item in the current phase, advancing the phase when
    /// it fills.
    mutating func recordItem() {
        guard completed.indices.contains(phaseIndex) else { return }
        completed[phaseIndex] += 1
        guard completed[phaseIndex] >= required[phaseIndex] else { return }
        if phaseIndex + 1 < required.count { phaseIndex += 1 }
    }
}
