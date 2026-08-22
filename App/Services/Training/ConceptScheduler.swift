//
//  ConceptScheduler.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// Chooses the one concept a set carries alongside its puzzles.
///
/// ## One slot, not a menu
///
/// The Train tab used to offer endgame drills as a second thing to choose,
/// which meant they were practised by exactly the people who already knew they
/// mattered. A set now carries a single concept slot and the app decides what
/// goes in it, for the same reason it decides the weekly focus: knowing which
/// of opening, endgame and positional play you are worst at is a judgement the
/// user does not have yet, and getting it wrong is expensive in a way that is
/// invisible to them.
///
/// ## The order it picks in
///
/// Anything never taught comes first, oldest-first after that. On top of both,
/// the family rotates: two endgames in a row is a worse set than one endgame
/// and one opening, even when the endgame is technically more overdue, because
/// a set that feels like one subject is a set the user starts skipping.
///
/// ## And when the games disagree
///
/// Rotation on its own is blind to evidence. With eighteen concepts sharing one
/// slot, a family comes round roughly every eighteen sets — so a player who
/// loses every game out of the opening keeps being served endgames while the
/// metrics that know it sit unread. A measured weakness therefore *overrides*
/// the rotation rather than joining it: see
/// ``next(rating:rung:states:lastFamily:focus:openingMistakesPerGame:)``.
///
/// ## And when the ladder is waiting on one
///
/// Ahead of all of that sits what the curriculum has actually asked for. A rung
/// gates on Lucena and Philidor; the only place either is taught is this slot;
/// so until they have been taught, an opening lesson nobody asked for is not a
/// reasonable thing to spend the slot on. Those come first — see `owed` below.
enum ConceptScheduler {

    /// What the scheduler needs to know about one concept.
    struct State: Sendable, Hashable {
        var id: String
        var isIntroduced: Bool
        var timesSeen: Int
        var lastSeenAt: Date?

        init(id: String, isIntroduced: Bool = false, timesSeen: Int = 0, lastSeenAt: Date? = nil) {
            self.id = id
            self.isIntroduced = isIntroduced
            self.timesSeen = timesSeen
            self.lastSeenAt = lastSeenAt
        }
    }

    /// What a set should show for the chosen concept.
    struct Selection: Sendable, Hashable {
        var concept: TrainingConcept
        /// True the first time: the lesson is shown before the exercise.
        var teachFirst: Bool
    }

    /// Opening mistakes per game above which the opening family jumps the
    /// queue.
    ///
    /// The same number `r3.opening` gates on, deliberately: the curriculum
    /// already calls half a mistake a game the line between "your openings are
    /// fine" and "they are not", and having the slot promote at one threshold
    /// while the ladder passes at another would mean the app teaching openings
    /// to somebody it has just told they have finished with them.
    static let openingPressureThreshold = 0.5

    /// Picks the concept for one set.
    ///
    /// - Parameters:
    ///   - rating: the user's puzzle rating, which gates the concepts the
    ///     curriculum has not asked for yet.
    ///   - rung: the rung they are standing on. Everything the ladder gates on
    ///     up to and including it is unlocked whatever the rating says, and is
    ///     served before anything else — the app cannot require a skill and
    ///     withhold the one screen that teaches it.
    ///   - states: progress by concept id. A concept with no row has never
    ///     been seen, which is the common case on the first sets.
    ///   - lastFamily: the family the previous set used, so this one can differ.
    ///   - focus: the week's habit, when the caller has one. Some habits are
    ///     taught by a family — the endgame technique habit is the endgame
    ///     family, more or less by definition — and where that is true the slot
    ///     follows the habit instead of the rotation. Habits with no family
    ///     (blunder-checking, clock discipline) are trained by the puzzle mix
    ///     and leave this alone.
    ///   - openingMistakesPerGame: measured from the user's own games. Above
    ///     ``openingPressureThreshold`` it promotes the opening family over
    ///     everything else, so a player losing games out of the opening stops
    ///     waiting eighteen sessions for the slot to come round to it.
    /// - Returns: nil only when the catalogue has nothing at this rating and
    ///   rung, which would mean a misconfigured catalogue rather than a finished
    ///   user.
    static func next(
        rating: Int,
        rung: Int,
        states: [String: State],
        lastFamily: TrainingConcept.Family? = nil,
        focus: Habit? = nil,
        openingMistakesPerGame: Double = 0
    ) -> Selection? {
        let required = Curriculum.requiredConcepts(throughRung: rung)
        let available = TrainingConcept.available(atRating: rating, curriculumRequires: required)
        guard !available.isEmpty else { return nil }

        // What the ladder is waiting on, and has not been taught yet. This beats
        // the rotation, the weekly focus and the opening-pressure override,
        // because those three are all the app's opinion about what would help
        // and this is a row on the user's ladder that cannot tick until the
        // lesson has been given.
        //
        // It does not beat the rotation *twice in a row*, hence the family
        // filter: rung 1 owes two basic mates and rung 3 owes two rook endings,
        // and a week of nothing but endgames is the set the user starts
        // skipping. Filtered to nothing means "not this set" rather than "serve
        // it anyway" — it comes round next set, when the last family has moved.
        let owed = available.filter {
            required.contains($0.id)
                && states[$0.id]?.isIntroduced != true
                && $0.family != lastFamily
        }
        if let first = owed.first {
            return selection(for: first, state: states[first.id], teachFirst: true)
        }

        let pool = self.pool(
            from: available,
            lastFamily: lastFamily,
            preferring: preferredFamily(focus: focus, openingMistakesPerGame: openingMistakesPerGame)
        )

        let untaught = pool.filter { states[$0.id]?.isIntroduced != true }
        if let first = untaught.first {
            return selection(for: first, state: states[first.id], teachFirst: true)
        }

        // Everything here has been taught: the one seen least recently is the
        // one most likely to have gone.
        let due = pool.min { lhs, rhs in
            let left = states[lhs.id]
            let right = states[rhs.id]
            if left?.timesSeen != right?.timesSeen {
                return (left?.timesSeen ?? 0) < (right?.timesSeen ?? 0)
            }
            // `.distantPast` for a concept taught but never exercised: it is
            // more overdue than one practised last week, not less.
            return (left?.lastSeenAt ?? .distantPast) < (right?.lastSeenAt ?? .distantPast)
        }

        return due.map { selection(for: $0, state: states[$0.id], teachFirst: false) }
    }

    /// The candidates this set may choose from.
    ///
    /// A preference beats the rotation rather than filtering it, because the two
    /// answer different questions: rotation exists so a set does not feel like
    /// one subject, and a measured weakness is a reason to spend two sets on one
    /// subject on purpose. Both give way rather than leave the slot empty.
    private static func pool(
        from available: [TrainingConcept],
        lastFamily: TrainingConcept.Family?,
        preferring preferred: TrainingConcept.Family?
    ) -> [TrainingConcept] {
        if let preferred {
            let matching = available.filter { $0.family == preferred }
            if !matching.isEmpty { return matching }
        }
        let rotated = available.filter { $0.family != lastFamily }
        return rotated.isEmpty ? available : rotated
    }

    /// The family the user's own games say is costing them, if any.
    private static func preferredFamily(
        focus: Habit?,
        openingMistakesPerGame: Double
    ) -> TrainingConcept.Family? {
        if openingMistakesPerGame > openingPressureThreshold { return .opening }
        guard let focus else { return nil }
        return family(taughtBy: focus)
    }

    /// The family that teaches a habit, for the habits a lesson can teach.
    ///
    /// Nil is the common answer and the honest one. Blunder-checking is not a
    /// subject with a lesson behind it; it is a thing you practise on positions,
    /// which is what the puzzle mix already weights toward the focus.
    private static func family(taughtBy habit: Habit) -> TrainingConcept.Family? {
        switch habit {
        case .endgameTechnique, .convertCleanly: return .endgame
        case .kingSafety: return .opening
        case .whatChanged, .scanThreats, .candidatesFirst, .calcToQuiet,
            .blunderCheck, .clockDiscipline:
            return nil
        }
    }

    /// Wraps a concept with the variation of its line this visit should serve.
    ///
    /// The main line first, then its alternatives, cycling on `timesSeen` — so
    /// the lesson and its first exercise agree, and the deviations arrive on the
    /// visits where the user has already played the main line once.
    private static func selection(
        for concept: TrainingConcept,
        state: State?,
        teachFirst: Bool
    ) -> Selection {
        let variations = concept.lineVariations
        guard variations.count > 1 else {
            return Selection(concept: concept, teachFirst: teachFirst)
        }
        let index = max(0, state?.timesSeen ?? 0) % variations.count
        return Selection(concept: concept.playing(variation: variations[index]), teachFirst: teachFirst)
    }
}
