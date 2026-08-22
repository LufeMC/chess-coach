//
//  CalibrationScoringTests.swift
//  ChessCoachTests
//

import ChessKit
import Testing
import TrainingCore

@testable import ChessCoach

private func position(_ fen: String) -> Position {
    guard let position = Position(fen: fen) else {
        Issue.record("bad fixture FEN: \(fen)")
        return .standard
    }
    return position
}

private func outcome(result: String, termination: String, userWon: Bool?) -> GameSession.Outcome {
    GameSession.Outcome(result: result, termination: termination, userWon: userWon)
}

private let fiftyMoves = Board.State.DrawReason.fiftyMoves.rawValue
private let stalemate = Board.State.DrawReason.stalemate.rawValue

/// What a hopeless game is worth to the measurement.
///
/// The calibration opponent is an engine weakened to the user's own level, and
/// converting a won endgame is exactly what a weakened engine fumbles. Without
/// this, a user reduced to a bare king could bank a draw against an 1100 —
/// rating the whole curriculum is then seeded from.
@Suite("Calibration scoring")
struct CalibrationScoringTests {

    @Test("A fifty-move draw from a bare king is scored as the loss it was")
    func hopelessDrawIsALoss() {
        // Black is a bare king against king and rook.
        let measured = CalibrationScoring.measuredOutcome(
            for: outcome(result: "1/2-1/2", termination: fiftyMoves, userWon: nil),
            finalPosition: position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1"),
            userColor: .black
        )
        #expect(measured == .loss)
    }

    @Test("A level fifty-move draw stays a draw")
    func levelDrawSurvives() {
        let measured = CalibrationScoring.measuredOutcome(
            for: outcome(result: "1/2-1/2", termination: fiftyMoves, userWon: nil),
            finalPosition: position("4k3/8/8/8/8/8/8/4K3 w - - 0 1"),
            userColor: .black
        )
        #expect(measured == .draw)
    }

    /// The asymmetry, pinned: failing to convert is a real weakness of the
    /// user's and the measurement should keep seeing it. This only ever removes
    /// credit that was not earned; it never invents any.
    @Test("A winning position thrown away is not promoted to a win")
    func squanderedWinStaysADraw() {
        let measured = CalibrationScoring.measuredOutcome(
            for: outcome(result: "1/2-1/2", termination: fiftyMoves, userWon: nil),
            finalPosition: position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1"),
            userColor: .white
        )
        #expect(measured == .draw)
    }

    /// Stalemate and perpetual check are defensive resources a player *earns*.
    @Test("Only the fifty-move rule is downgraded")
    func stalemateIsRespected() {
        let measured = CalibrationScoring.measuredOutcome(
            for: outcome(result: "1/2-1/2", termination: stalemate, userWon: nil),
            finalPosition: position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1"),
            userColor: .black
        )
        #expect(measured == .draw, "saving a lost game by stalemate is a skill, not a fluke")
    }

    @Test("Decided games pass through untouched")
    func decidedGamesAreUnchanged() {
        let won = CalibrationScoring.measuredOutcome(
            for: outcome(result: "1-0", termination: "checkmate", userWon: true),
            finalPosition: position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1"),
            userColor: .white
        )
        let lost = CalibrationScoring.measuredOutcome(
            for: outcome(result: "0-1", termination: "checkmate", userWon: false),
            finalPosition: position("4k3/8/8/8/8/8/8/R3K3 w - - 0 1"),
            userColor: .black
        )
        #expect(won == .win)
        #expect(lost == .loss)
    }

    @Test("An unknown final position is not evidence of anything")
    func withoutAPositionNothingChanges() {
        let measured = CalibrationScoring.measuredOutcome(
            for: outcome(result: "1/2-1/2", termination: fiftyMoves, userWon: nil),
            finalPosition: nil,
            userColor: .black
        )
        #expect(measured == .draw)
    }
}

/// FIDE 6.9: a flag is only a loss if the other side could still mate.
@Suite("Mating material")
struct MatingMaterialTests {

    @Test("A lone king, and a king with one minor, cannot mate")
    func insufficientForces() {
        #expect(!MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/4K3 w - - 0 1")))
        #expect(!MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/3BK3 w - - 0 1")))
        #expect(!MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/3NK3 w - - 0 1")))
    }

    @Test("Bishops confined to one colour can never mate")
    func sameColourBishops() {
        // c1 and e3 are both dark squares.
        #expect(!MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/4B3/8/2B1K3 w - - 0 1")))
        // c1 dark, f1 light — now the pair covers everything.
        #expect(MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/2B1KB2 w - - 0 1")))
    }

    @Test("Anything that can force or help-force mate counts")
    func sufficientForces() {
        #expect(MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/3RK3 w - - 0 1")))
        #expect(MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")))
        // Two knights cannot *force* mate, but a cooperating king can be mated,
        // which is the line FIDE draws and every online implementation follows.
        #expect(MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/2NNK3 w - - 0 1")))
        #expect(MatingMaterial.canMate(.white, in: position("4k3/8/8/8/8/8/8/2NBK3 w - - 0 1")))
    }

    @Test("Flagging against a bare king is a draw, not a loss")
    func timeoutAgainstABareKing() {
        // White flags; Black has only a king and cannot mate.
        let bareKing = position("4k3/8/8/8/8/8/8/3QK3 w - - 0 1")
        #expect(MatingMaterial.timeoutIsDraw(flagged: .white, position: bareKing))
        // Black flags; White has a queen and mates easily.
        #expect(!MatingMaterial.timeoutIsDraw(flagged: .black, position: bareKing))
    }
}

// MARK: - Between games

/// The card that stands between two calibration games.
///
/// The five games used to run into each other: record, drop the session, and the
/// next starting position arrived on the same frame. Checkmate, a flag and a
/// fifty-move draw were indistinguishable from the chair, and the reveal then
/// told a user who had never seen a result that they had won every game.
@Suite("Calibration between games")
struct CalibrationInterludeTests {

    private func card(
        gameNumber: Int = 1,
        termination: GameTermination = .checkmate,
        measured: GameOutcome = .win,
        userWon: Bool? = true,
        opponentRating: Int = 1_100,
        totalGames: Int = 5
    ) -> CalibrationInterlude {
        CalibrationInterlude.result(
            gameNumber: gameNumber,
            outcome: outcome(
                result: userWon == true ? "1-0" : "0-1",
                termination: termination.rawValue,
                userWon: userWon
            ),
            measured: measured,
            opponentRating: opponentRating,
            totalGames: totalGames
        )
    }

    @Test("A finished game names how it ended and which game it was")
    func namesTheResult() {
        let win = card()
        #expect(win.title == "Game 1 — you won by checkmate")
        #expect(win.actionTitle == "Play game 2")

        let loss = card(termination: .timeout, measured: .loss, userWon: false)
        #expect(loss.title.contains("ran out of time"))
    }

    /// The ladder moving is the honest part of this phase, and until now the
    /// only trace of it was the opponent's number changing on the next board.
    @Test("The card names where the ladder goes next")
    func namesTheLadderStep() {
        #expect(card(measured: .win).detail.contains("1200"))
        #expect(card(termination: .resignation, measured: .loss, userWon: false).detail.contains("1000"))

        let drawn = card(termination: .agreement, measured: .draw, userWon: nil)
        #expect(drawn.detail.contains("stays at about 1100"))
    }

    /// `GameSession` reports an unknown-termination draw once its opponent
    /// retries are spent. That is the engine giving up, not a result the user
    /// played, and half a rating point of evidence about them would be invented
    /// by recording it.
    @Test("A game the engine abandoned is not counted, and is offered again")
    func abandonedGameIsNotCounted() {
        let abandoned = card(gameNumber: 3, termination: .unknown, measured: .draw, userWon: nil)
        #expect(abandoned.measuredOutcome == nil)
        #expect(abandoned.actionTitle == "Play game 3 again")
        #expect(abandoned.title.contains("stopped"))
    }

    @Test("A counted game carries the outcome the combiner is told about")
    func countedGameCarriesItsOutcome() {
        #expect(card(measured: .win).measuredOutcome == .win)
    }

    /// The fifty-move override is the one place the card and the scoring could
    /// disagree, and a card reading "drawn" over a result recorded as a loss
    /// would be the app keeping two sets of books.
    @Test("A fifty-move draw scored as a loss says so")
    func fiftyMoveOverrideIsStated() {
        let scored = card(termination: .fiftyMoves, measured: .loss, userWon: nil)
        #expect(scored.title.contains("scored as a loss"))
        #expect(scored.measuredOutcome == .loss)
    }

    @Test("The last game hands over to the puzzles rather than to a sixth board")
    func lastGameLeadsToPuzzles() {
        let last = card(gameNumber: 5, totalGames: 5)
        #expect(last.actionTitle == "Start the puzzles")
        #expect(last.detail.contains("Twenty puzzles"))
    }

    /// The draft holds finished games only, so an interrupted game restarts —
    /// and the counter, unchanged, says nothing happened.
    @Test("A resumed calibration says the interrupted game starts again")
    func resumeIsExplained() {
        let resumed = CalibrationInterlude.resumed(gameNumber: 3, totalGames: 5, opponentRating: 1_200)
        #expect(resumed.measuredOutcome == nil)
        #expect(resumed.detail.contains("starts again"))
        #expect(resumed.actionTitle == "Play game 3")
    }
}
