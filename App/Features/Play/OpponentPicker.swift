import Database
import Foundation
import TrainingCore

/// Chooses who you play next.
///
/// The roster and the offset cycle both existed before this type, but nothing
/// consumed them: the Play screen passed a literal `1100` and a literal game
/// index of `0`, so every sparring game was against the same opponent at the
/// same rating no matter how the user's own rating moved. This reads the two
/// real inputs — the stored rating, and how many sparring games have actually
/// been played — so the ladder and the roster do what they were written to do.
struct OpponentPicker: Sendable {

    /// The user's playing rating, read from settings rather than recomputed.
    ///
    /// Settings is where that number lives and the only place it is written:
    /// calibration seeds it, and the Elo ladder is the only thing entitled to
    /// move it afterwards. Estimating strength a second time here, from game
    /// history, would give the app two answers to one question — and the one
    /// the Play screen showed would not be the one the curriculum gates on.
    var userRating: Double

    /// How many sparring games have been played. Only its remainder matters —
    /// it drives the +50/+50/+150/0 offset cycle, so the user gets a stretch
    /// game and a confidence game in every four rather than a permanent grind,
    /// and its parity is what alternates the colour they play.
    var gamesPlayed: Int

    /// Conservative defaults for a user who hasn't calibrated yet.
    static let unmeasured = OpponentPicker(userRating: 1100, gamesPlayed: 0)

    /// The ladder rule itself lives in `TrainingCore`, where it is tuned and
    /// tested. The app had a second copy of it that rounded down instead of to
    /// nearest and ignored `DomainTuning`, which quietly shaved the stretch
    /// games; calling the real one is what makes the shipped ladder the
    /// measured one.
    var rating: Int {
        EloLadder.opponentRating(userRating: userRating, gameIndex: gamesPlayed)
    }

    var opponent: OpponentRoster.Opponent {
        OpponentRoster.opponent(forRating: rating)
    }

    /// Why this game sits where it does on the ladder, or nil for the two
    /// ordinary games in the cycle.
    ///
    /// The cycle moves the opponent by as much as 150 points, and from the
    /// user's side that reads as the same named person drifting in rating
    /// between games — which undercuts the whole point of naming them. Saying
    /// "a stretch game" turns the drift back into a plan.
    var framing: String? {
        let cycle = DomainTuning.default.ladder.opponentOffsetCycle
        guard let hardest = cycle.max(), let easiest = cycle.min(), hardest != easiest else { return nil }
        let offset = cycle[((gamesPlayed % cycle.count) + cycle.count) % cycle.count]
        switch offset {
        case hardest: return "a stretch game"
        case easiest: return "a confidence game"
        default: return nil
        }
    }

    /// Loads the real inputs, falling back to the unmeasured default when the
    /// database is unavailable — a user with no working store should still be
    /// able to play.
    static func current() -> OpponentPicker {
        guard let database = AppDatabase.sharedIfAvailable else { return .unmeasured }
        return current(database: database)
    }

    /// The same read against an already-open database, for callers that hold
    /// one. Today's load runs off the main actor with the database in hand, and
    /// reaching back through the shared accessor there would be a second lookup
    /// for an answer already known.
    static func current(database: AppDatabase) -> OpponentPicker {
        let rating = (try? database.settings.current().userRating) ?? unmeasured.userRating
        return OpponentPicker(userRating: rating, gamesPlayed: sparringGames(in: database))
    }

    /// The name the next game will be played against.
    ///
    /// Today's CTA names the opponent, and it has to be the name the Play screen
    /// then shows — a button promising Oscar that delivers Petra is worse than
    /// one that promised nothing. So this goes through the whole computation
    /// rather than a cheaper guess from the rating alone: the cycle's stretch
    /// game shifts the pick by 150 points, which is a whole roster entry.
    static func nextOpponentName(database: AppDatabase) -> String {
        current(database: database).opponent.name
    }

    /// Sparring games only.
    ///
    /// Calibration is five games back to back, so counting those would spend the
    /// entire cycle before the user's first training game — they would meet the
    /// roster through the +150 stretch opponent, and the same count is what
    /// fixes the colour they play, so they would be handed Black as well.
    ///
    /// `Game.isRated` is the wrong filter here, and interestingly it selects the
    /// exact opposite set: sparring carries second-try, which is precisely what
    /// makes it unrated, while calibration turns every interruption off and so
    /// is the only rated thing in the table. The mode is the honest question —
    /// this cycle is about who you meet next, not about what counted.
    private static func sparringGames(in database: AppDatabase) -> Int {
        let recent = (try? database.games.recent(limit: countWindow)) ?? []
        return recent.filter { $0.gameMode == GameMode.sparring }.count
    }

    /// How far back the count reads.
    ///
    /// Bounded rather than a full count, because only the remainder is ever used
    /// and every row pulled out of the table drags its PGN along with it.
    private static let countWindow = 200
}
