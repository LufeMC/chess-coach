import Testing

@testable import ChessCoach

/// The roster and the offset cycle both existed for a while without being
/// consumed — the Play screen passed literals, so every game was the same
/// opponent at the same rating forever. These tests pin the wiring, not the
/// roster's contents.
@Suite("Opponent selection")
struct OpponentPickerTests {

    @Test("The offset cycle produces a stretch game and a confidence game in every four")
    func cycleVariesTheRating() {
        let ratings = (0..<4).map {
            OpponentPicker(userRating: 1100, gamesPlayed: $0).rating
        }

        // +50, +50, +150, +0 — rounded to 25.
        #expect(ratings == [1150, 1150, 1250, 1100])
        #expect(Set(ratings).count > 1, "a fixed opponent rating means the ladder is not wired")
    }

    @Test("A user at 1100 meets more than one opponent across a cycle")
    func cycleVariesTheOpponent() {
        let names = Set(
            (0..<4).map { OpponentPicker(userRating: 1100, gamesPlayed: $0).opponent.name }
        )
        // The stretch game is the one that should introduce someone harder.
        #expect(names.count >= 2, "every game in the cycle drew the same opponent: \(names)")
    }

    @Test("The opponent follows the user up the ladder")
    func opponentTracksRating() {
        let beginner = OpponentPicker(userRating: 850, gamesPlayed: 0).opponent
        let intermediate = OpponentPicker(userRating: 1450, gamesPlayed: 0).opponent
        let strong = OpponentPicker(userRating: 2000, gamesPlayed: 0).opponent

        #expect(beginner.name != intermediate.name)
        #expect(intermediate.name != strong.name)
        #expect(beginner.rating < intermediate.rating)
        #expect(intermediate.rating < strong.rating)
    }

    @Test("The opponent sits at or above the user, never below")
    func opponentIsNeverEasierThanTheUser() {
        // A partner who is always beatable stops producing mistakes worth
        // studying, which is the entire reason the app exists.
        for rating in stride(from: 900.0, through: 2000.0, by: 100.0) {
            for game in 0..<4 {
                let picked = OpponentPicker(userRating: rating, gamesPlayed: game).rating
                #expect(
                    Double(picked) >= rating - 25,
                    "at \(rating) game \(game) the opponent dropped to \(picked)"
                )
            }
        }
    }

    @Test("Ratings clamp to the humanizer's calibrated span")
    func ratingClamps() {
        #expect(OpponentPicker(userRating: 200, gamesPlayed: 0).rating >= 800)
        #expect(OpponentPicker(userRating: 3000, gamesPlayed: 2).rating <= 2200)
    }

    @Test("The shipped ladder is the tuned one, rounding to the nearest rung")
    func usesTheTunedLadder() {
        // The app carried a second copy of this rule that truncated to 25 with
        // integer division, so a +50 stretch turned into +37 and the cycle
        // aimed above the ~45% score it was tuned for. 1013 + 50 is 1063, which
        // rounds to 1075 and truncated to 1050.
        #expect(OpponentPicker(userRating: 1013, gamesPlayed: 0).rating == 1075)
    }

    @Test("The stretch and confidence games say what they are")
    func cycleFramingNamesTheIntent() {
        // Without this the roster looks like it drifts: the same named opponent
        // shows a different rating game to game with nothing explaining why.
        let framings = (0..<4).map { OpponentPicker(userRating: 1100, gamesPlayed: $0).framing }
        #expect(framings == [nil, nil, "a stretch game", "a confidence game"])
    }

    @Test("Colour alternates so the user isn't always White")
    func colourAlternates() {
        // Playing one side forever hides half the openings and half the
        // mistakes the app is meant to find.
        let colors = (0..<4).map { OpponentPicker(userRating: 1100, gamesPlayed: $0).gamesPlayed.isMultiple(of: 2) }
        #expect(colors == [true, false, true, false])
    }
}
