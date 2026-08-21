//
//  ConceptScheduler.swift
//  ChessCoach
//

import Foundation

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

    /// Picks the concept for one set.
    ///
    /// - Parameters:
    ///   - rating: gates which concepts have been unlocked.
    ///   - states: progress by concept id. A concept with no row has never
    ///     been seen, which is the common case on the first sets.
    ///   - lastFamily: the family the previous set used, so this one can differ.
    /// - Returns: nil only when the catalogue has nothing at this rating, which
    ///   would mean a misconfigured catalogue rather than a finished user.
    static func next(
        rating: Int,
        states: [String: State],
        lastFamily: TrainingConcept.Family? = nil
    ) -> Selection? {
        let available = TrainingConcept.available(atRating: rating)
        guard !available.isEmpty else { return nil }

        // Prefer a family the user did not just do, but never at the cost of
        // serving nothing: if rotating leaves no candidates, rotation loses.
        let rotated = available.filter { $0.family != lastFamily }
        let pool = rotated.isEmpty ? available : rotated

        let untaught = pool.filter { states[$0.id]?.isIntroduced != true }
        if let first = untaught.first {
            return Selection(concept: first, teachFirst: true)
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

        return due.map { Selection(concept: $0, teachFirst: false) }
    }
}
