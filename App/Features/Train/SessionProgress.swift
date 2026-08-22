//
//  SessionProgress.swift
//  ChessCoach
//

import Foundation
import TrainingCore

/// Progress through one training session.
///
/// A value type with no view and no service, so the accounting can be asserted
/// directly. That matters more here than it looks: the denominator is **not** a
/// constant. `SessionAssembler.appendingRelearnRetries` adds a same-day retry
/// for every card failed during the session, so a ten-puzzle set legitimately
/// finishes at twelve, and every derived number below has to survive the queue
/// growing underneath it mid-flight.
struct SessionProgress: Sendable, Hashable {

    /// Zero-based index of the puzzle currently on screen.
    ///
    /// Tracked separately from ``completed`` because the result banner holds the
    /// board on the item that was just answered: while the banner is up,
    /// `completed` has already advanced and `index` has not.
    var index: Int = 0

    /// Items the user has finished, answered or skipped.
    var completed: Int = 0

    /// Items currently in the queue.
    var total: Int = 0

    /// First-attempt solves. Excludes the same-day retries, which are counted
    /// in ``retriesSolved``.
    var solved: Int = 0
    var hinted: Int = 0

    /// Same-day retries finished, and how many of them were clean.
    ///
    /// Kept apart from ``solved`` because they measure different things. A
    /// retry is a second look at a position whose answer the user was shown
    /// minutes ago; folding it into the same fraction produced `8 / 12`, in
    /// which the denominator is the number of positions served and the
    /// numerator is a mix of recall and re-recall. Two honest numbers beat one
    /// that quietly means neither.
    var retries: Int = 0
    var retriesSolved: Int = 0

    /// Wall-clock time spent in the session.
    var elapsed: TimeInterval = 0

    /// Change in puzzle rating since the session started, already rounded.
    var ratingDelta: Int = 0

    /// Glicko's uncertainty about the puzzle rating, in rating points.
    ///
    /// Carried so the summary can decline to report a delta it cannot stand
    /// behind — see ``SessionSummaryView``.
    var ratingDeviation: Double = 0

    init(
        index: Int = 0,
        completed: Int = 0,
        total: Int = 0,
        solved: Int = 0,
        hinted: Int = 0,
        retries: Int = 0,
        retriesSolved: Int = 0,
        elapsed: TimeInterval = 0,
        ratingDelta: Int = 0,
        ratingDeviation: Double = 0
    ) {
        self.index = index
        self.completed = completed
        self.total = total
        self.solved = solved
        self.hinted = hinted
        self.retries = retries
        self.retriesSolved = retriesSolved
        self.elapsed = elapsed
        self.ratingDelta = ratingDelta
        self.ratingDeviation = ratingDeviation
    }

    /// The denominator actually shown.
    ///
    /// `max` of the two because the queue and the finished count can disagree
    /// for one frame: `TrainingService` increments its item index before the
    /// appended retries land in `session.items`, and `9 / 8` on screen — even
    /// for a frame — reads as a bug.
    var displayTotal: Int { max(1, max(total, completed)) }

    /// `3 / 10`, for the nav-bar counter.
    var counterLabel: String { "\(min(index + 1, displayTotal)) / \(displayTotal)" }

    /// Fill of the hairline bar, 0...1.
    var fraction: Double {
        min(1, max(0, Double(completed) / Double(displayTotal)))
    }

    // MARK: Summary rows

    /// Positions the user was seeing for the first time today.
    ///
    /// The retries are subtracted rather than counted separately at the source
    /// because the queue is what grows: `SessionAssembler.appendingRelearnRetries`
    /// appends one per failed card, so `displayTotal` is first attempts plus
    /// retries by construction.
    var firstAttempts: Int { max(1, displayTotal - retries) }

    var solvedLabel: String { "\(solved)/\(firstAttempts)" }

    /// `1/2 clean`, or nil when nothing came back for a second look.
    var retriesLabel: String? {
        guard retries > 0 else { return nil }
        return "\(retriesSolved)/\(retries) clean"
    }

    var hintsLabel: String { "\(hinted)" }

    /// `04:12`. Monospaced at the call site; zero-padded here so the column
    /// stays the same width from the first row to the last.
    var timeLabel: String {
        let seconds = max(0, Int(elapsed.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// `+12` / `-4` / `0`. Signed even when positive: an unsigned `12` in a
    /// delta column is ambiguous with an absolute rating.
    var ratingLabel: String {
        ratingDelta > 0 ? "+\(ratingDelta)" : "\(ratingDelta)"
    }
}

/// A puzzle the user did not solve, as it appears in the summary's `Missed`
/// section.
///
/// Deliberately carries no severity, colour or score. The heading is what is
/// tinted; the chips stay neutral, because ten orange chips would turn a list of
/// things to revisit into a list of accusations.
struct MissedItem: Sendable, Hashable, Identifiable {

    var id: UUID
    /// The concept, already humanised — `fork`, `back-rank mate`.
    var concept: String
    /// The move that was required, in UCI, so the row can be tapped through to
    /// the position later.
    var expected: String?

    init(id: UUID = UUID(), concept: String, expected: String? = nil) {
        self.id = id
        self.concept = concept
        self.expected = expected
    }
}
