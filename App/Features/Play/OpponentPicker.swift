import Database
import Foundation

/// Chooses who you play next.
///
/// The roster and the offset cycle both existed before this type, but nothing
/// consumed them: the Play screen passed a literal `1100` and a literal game
/// index of `0`, so every sparring game was against the same opponent at the
/// same rating no matter how the user's own rating moved. This reads the two
/// real inputs — the stored rating, and how many games have actually been
/// played — so the ladder and the roster do what they were written to do.
struct OpponentPicker: Sendable {

    /// The user's playing rating. Calibration seeds it; the Elo ladder moves it.
    var userRating: Double
    /// How many rated games have been played. Only its remainder matters — it
    /// drives the +50/+50/+150/0 offset cycle, so the user gets a stretch game
    /// and a confidence game in every four rather than a permanent grind.
    var gamesPlayed: Int

    /// Conservative defaults for a user who hasn't calibrated yet.
    static let unmeasured = OpponentPicker(userRating: 1100, gamesPlayed: 0)

    var rating: Int {
        OpponentLadder.rating(forUserRating: userRating, gameIndex: gamesPlayed)
    }

    var opponent: OpponentRoster.Opponent {
        OpponentRoster.opponent(forRating: rating)
    }

    /// Loads the real inputs, falling back to the unmeasured default when the
    /// database is unavailable — a user with no working store should still be
    /// able to play.
    static func current() -> OpponentPicker {
        guard let database = AppDatabase.sharedIfAvailable else { return .unmeasured }

        let rating = (try? database.settings.current().userRating) ?? unmeasured.userRating

        // Counting the recent window rather than the whole table: the cycle only
        // needs the count modulo four, and an unbounded count would grow with
        // the user's history for no benefit. The window is a multiple of the
        // cycle length so the phase stays stable as games accumulate.
        let played = (try? database.games.recent(limit: 200).count) ?? 0

        return OpponentPicker(userRating: rating, gamesPlayed: played)
    }
}
