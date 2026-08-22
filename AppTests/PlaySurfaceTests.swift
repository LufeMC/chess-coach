import ChessKit
import Foundation
import Testing

@testable import ChessCoach

// The play surface's pure layer. None of this needs an engine, a database or a
// running game — which is the point of having factored it out, because these
// are exactly the derivations that are invisible in a screenshot and obvious in
// an assertion.

// MARK: - Clock

@Suite("Clock formatting")
struct ClockFormattingTests {

    @Test("Whole minutes and seconds above ten seconds")
    func minutesAndSeconds() {
        #expect(PlayClock.reading(milliseconds: 600_000).text == "10:00")
        #expect(PlayClock.reading(milliseconds: 599_000).text == "9:59")
        #expect(PlayClock.reading(milliseconds: 61_400).text == "1:01")
        #expect(PlayClock.reading(milliseconds: 30_000).text == "0:30")
    }

    @Test("Tenths appear under ten seconds, where the number is the game")
    func tenths() {
        let reading = PlayClock.reading(milliseconds: 9_450)
        #expect(reading.text == "9.4")
        #expect(reading.showsTenths)
        #expect(PlayClock.reading(milliseconds: 400).text == "0.4")
    }

    @Test("Ten seconds exactly is already in tenths")
    func boundaryShowsTenths() {
        // The bug this guards: a `<` instead of `<=` leaves the display in mm:ss
        // for the one tick where the switch matters most.
        #expect(PlayClock.reading(milliseconds: 10_000).showsTenths)
        #expect(!PlayClock.reading(milliseconds: 10_001).showsTenths)
    }

    @Test("A flagged clock reads zero, never a negative")
    func neverNegative() {
        #expect(PlayClock.reading(milliseconds: -5_000).text == "0.0")
        #expect(PlayClock.reading(milliseconds: 0).text == "0.0")
    }

    @Test("The reserved width covers the widest string of the game")
    func widthSample() {
        // "10:00" and "0:00" have different glyph counts; monospaced digits do
        // nothing about that, so the segment reserves the wide one.
        #expect(PlayClock.widthSample(baseSeconds: 600).count == "10:00".count)
        #expect(PlayClock.widthSample(baseSeconds: 180).count == "3:00".count)
        // 59 minutes of base plus increments can reach an hour.
        #expect(PlayClock.widthSample(baseSeconds: 3_540).count == "60:00".count)
    }
}

@Suite("Clock pressure tiers")
struct ClockPressureTests {

    @Test("Three tiers, at thirty and ten seconds")
    func tiers() {
        #expect(PlayClock.pressure(milliseconds: 120_000) == .none)
        #expect(PlayClock.pressure(milliseconds: 30_001) == .none)
        #expect(PlayClock.pressure(milliseconds: 30_000) == .low)
        #expect(PlayClock.pressure(milliseconds: 10_001) == .low)
        #expect(PlayClock.pressure(milliseconds: 10_000) == .critical)
        #expect(PlayClock.pressure(milliseconds: 0) == .critical)
    }

    @Test("Tiers are ordered so views can compare them")
    func ordering() {
        #expect(ClockPressure.none < .low)
        #expect(ClockPressure.low < .critical)
    }

    @Test("The ten-second haptic fires exactly once, on the crossing")
    func crossing() {
        #expect(PlayClock.crossedCritical(previousMs: 10_400, currentMs: 9_900))
        #expect(PlayClock.crossedCritical(previousMs: 10_001, currentMs: 10_000))
        // Already under: no second buzz. A clock that buzzes every tick in time
        // trouble is worse than one that never buzzes at all.
        #expect(!PlayClock.crossedCritical(previousMs: 9_000, currentMs: 8_000))
        #expect(!PlayClock.crossedCritical(previousMs: 40_000, currentMs: 39_000))
    }
}

@Suite("Live clock arithmetic")
struct LiveClockTests {

    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("A running clock charges the move in progress")
    func running() {
        let remaining = PlayClock.remainingMs(
            chargedMs: 60_000,
            startedAt: start,
            now: start.addingTimeInterval(12),
            isRunning: true
        )
        #expect(remaining == 48_000)
    }

    @Test("A stopped clock ignores the wall clock entirely")
    func stopped() {
        // This is what stops the idle side's clock from draining while the
        // opponent thinks.
        let remaining = PlayClock.remainingMs(
            chargedMs: 60_000,
            startedAt: start,
            now: start.addingTimeInterval(600),
            isRunning: false
        )
        #expect(remaining == 60_000)
    }

    @Test("Overrun clamps to zero rather than going negative")
    func overrun() {
        let remaining = PlayClock.remainingMs(
            chargedMs: 5_000,
            startedAt: start,
            now: start.addingTimeInterval(30),
            isRunning: true
        )
        #expect(remaining == 0)
    }
}

// MARK: - Eval

@Suite("Eval capsule: material")
struct EvalMaterialTests {

    @Test("Sign and glyph, never colour alone")
    func signs() {
        let ahead = PlayEvalReading.material(3)
        #expect(ahead.direction == .ahead)
        #expect(ahead.text == "+3")
        #expect(ahead.symbolName == "arrowtriangle.up.fill")

        let behind = PlayEvalReading.material(-2)
        #expect(behind.direction == .behind)
        // A real minus sign, not a hyphen: at monospaced-digit widths a hyphen
        // reads as a dash between two numbers. And no unit — material is in
        // pawns, which is what the captured tray beside it is counting.
        #expect(behind.text == "\u{2212}2")
        #expect(behind.symbolName == "arrowtriangle.down.fill")

        let level = PlayEvalReading.material(0)
        #expect(level.direction == .level)
        #expect(level.text == "EVEN")
        #expect(level.symbolName == "equal")
    }

    @Test("Magnitude buckets")
    func buckets() {
        #expect(PlayEvalReading.material(0).magnitude == .level)
        #expect(PlayEvalReading.material(1).magnitude == .slight)
        #expect(PlayEvalReading.material(-2).magnitude == .slight)
        #expect(PlayEvalReading.material(3).magnitude == .clear)
        #expect(PlayEvalReading.material(-5).magnitude == .clear)
        #expect(PlayEvalReading.material(6).magnitude == .decisive)
        #expect(PlayEvalReading.material(-9).magnitude == .decisive)
    }

    @Test("The starting position is even from both sides")
    func startingPosition() {
        let position = Position.standard
        #expect(PlayEvalReading.materialBalance(in: position, for: .white) == 0)
        #expect(PlayEvalReading.materialBalance(in: position, for: .black) == 0)
    }

    @Test("Balance is signed from the asking side's perspective")
    func perspective() {
        var board = Board(position: .standard)
        // 1. e4 d5 2. exd5 — White is a pawn up.
        _ = board.move(pieceAt: .e2, to: .e4)
        _ = board.move(pieceAt: .d7, to: .d5)
        _ = board.move(pieceAt: .e4, to: .d5)

        #expect(PlayEvalReading.materialBalance(in: board.position, for: .white) == 1)
        #expect(PlayEvalReading.materialBalance(in: board.position, for: .black) == -1)
        #expect(PlayEvalReading.material(-1).text == "\u{2212}1")
    }

    @Test("Kings are worth nothing, so a bare-kings position is even")
    func kingsAreFree() {
        #expect(PlayEvalReading.value(of: .king) == 0)
        #expect(PlayEvalReading.value(of: .queen) == 9)
        #expect(PlayEvalReading.value(of: .rook) == 5)
        #expect(PlayEvalReading.value(of: .bishop) == 3)
        #expect(PlayEvalReading.value(of: .knight) == 3)
        #expect(PlayEvalReading.value(of: .pawn) == 1)
    }
}

@Suite("Eval capsule: win percentage")
struct EvalWinPercentTests {

    @Test("Bucketed around even, and never printed as a number")
    func buckets() {
        #expect(PlayEvalReading.winPercent(50).direction == .level)
        #expect(PlayEvalReading.winPercent(52).direction == .level)
        #expect(PlayEvalReading.winPercent(48).direction == .level)

        let slight = PlayEvalReading.winPercent(58)
        #expect(slight.direction == .ahead)
        #expect(slight.magnitude == .slight)
        #expect(slight.text == "BETTER")

        let clear = PlayEvalReading.winPercent(30)
        #expect(clear.direction == .behind)
        #expect(clear.magnitude == .clear)
        #expect(clear.text == "WORSE")

        #expect(PlayEvalReading.winPercent(95).magnitude == .decisive)
        #expect(PlayEvalReading.winPercent(2).magnitude == .decisive)
    }

    @Test("A level reading says EVEN rather than a signed near-zero")
    func levelText() {
        #expect(PlayEvalReading.winPercent(53).text == "EVEN")
    }

    /// The source is the opponent's own depth-capped search, run on the position
    /// before its own move — so it is a weak opinion, one ply stale, and it
    /// moves only when the opponent moves. A number would claim a precision
    /// none of that supports, and would claim it in the same glyph, weight and
    /// grammar as an exact material count.
    @Test("The engine reading carries no digits and no verdict")
    func readingIsAWordNotANumber() {
        let digits = CharacterSet.decimalDigits
        for percent in stride(from: 0.0, through: 100.0, by: 5.0) {
            let reading = PlayEvalReading.winPercent(percent)
            #expect(
                reading.text.rangeOfCharacter(from: digits) == nil,
                "\(percent)% printed a number: \(reading.text)"
            )
            #expect(["BETTER", "EVEN", "WORSE"].contains(reading.text))
            // "You are winning" is the sentence guided mode spends a pause
            // trying not to say; a 1200 told it stops looking for counterplay.
            #expect(!reading.accessibilityText.lowercased().contains("winning"))
            #expect(!reading.accessibilityText.lowercased().contains("losing"))
            // And it is named as the estimate it is, where there is room to.
            #expect(reading.accessibilityText.hasPrefix("Estimate:"))
        }
    }

    /// Material stays a count, because it is one: derived from the board the
    /// user is looking at, exact, and changing only on captures.
    @Test("Material is still printed as a number")
    func materialKeepsItsDigits() {
        #expect(PlayEvalReading.material(3).text == "+3")
        #expect(PlayEvalReading.material(-2).text == "\u{2212}2")
    }
}

// MARK: - Second try

@Suite("Second-try sheet copy")
struct SecondTryCopyTests {

    @Test("The rung that costs the rating says so before it is tapped")
    func assistedRungNamesItsCost() {
        // `GameSession.resumeAfterSecondTry` sets `usedAssistedRetry` once the
        // refutation has been drawn, and `EloLadder` then scores the whole game
        // unrated. The app exists to move one number; a control that quietly
        // freezes it for ten minutes of play has to say so first.
        #expect(SecondTrySheet.hintTitle(hintLevel: 0) == "Show me why")
        #expect(SecondTrySheet.hintTitle(hintLevel: 1).contains("unrated"))

        #expect(SecondTrySheet.primaryTitle(hintLevel: 0) == "Try again")
        #expect(SecondTrySheet.primaryTitle(hintLevel: 1) == "Try again")
        #expect(
            SecondTrySheet.primaryTitle(
                hintLevel: GameSession.SecondTryState.assistedHintLevel
            ).contains("unrated")
        )
    }

    @Test("The primary describes what it does, not what already happened")
    func primaryIsNotATakeBack() {
        // The retraction runs before the phase that shows this sheet, so the
        // user watched the move come back before reading a word.
        for level in 0...2 {
            #expect(!SecondTrySheet.primaryTitle(hintLevel: level).contains("Take it back"))
        }
        #expect(SecondTrySheet.prompt(hintLevel: 0).hasPrefix("Taken back"))
    }

    @Test("Every rung names a mechanism rather than announcing an outcome")
    func promptsShowTheMethod() {
        // A pulsed square and an arrow are not an explanation. Each rung has to
        // say what to do with what is on the board — and none of them may claim
        // material, because the session knows the evaluation dropped and not
        // what the refutation wins.
        #expect(SecondTrySheet.prompt(hintLevel: 0).contains("board is live"))
        #expect(SecondTrySheet.prompt(hintLevel: 1).contains("highlighted square"))
        #expect(SecondTrySheet.prompt(hintLevel: 2).contains("Count"))
        for level in 0...2 {
            let prompt = SecondTrySheet.prompt(hintLevel: level)
            #expect(!prompt.lowercased().contains("wins a"))
            #expect(!prompt.contains("piece for free"))
        }
    }
}

// MARK: - Opponent line

@Suite("Opponent status line")
struct OpponentStatusLineTests {

    private func input(
        isThinking: Bool,
        ply: Int = 20,
        lastUserSAN: String? = nil,
        material: Int = 0,
        canAnswerLastCapture: Bool = true,
        guidedVerdict: Bool? = nil
    ) -> OpponentStatusLine.Input {
        OpponentStatusLine.Input(
            trait: "looks three moves ahead; still misses short tactics",
            isThinking: isThinking,
            ply: ply,
            lastUserSAN: lastUserSAN,
            materialBalance: material,
            canAnswerLastCapture: canAnswerLastCapture,
            guidedVerdict: guidedVerdict
        )
    }

    @Test("Not their move: the trait, in the same slot")
    func trait() {
        let line = OpponentStatusLine.line(for: input(isThinking: false))
        #expect(line.kind == .trait)
        #expect(line.text == "looks three moves ahead; still misses short tactics")
    }

    @Test("Thinking: the trait is replaced by a spoken line")
    func swap() {
        let idle = OpponentStatusLine.line(for: input(isThinking: false))
        let thinking = OpponentStatusLine.line(for: input(isThinking: true))
        #expect(thinking.kind == .speech)
        #expect(thinking.text != idle.text)
        // The swap is the entire "opponent is thinking" indicator; if it ever
        // returns the trait while thinking, the screen goes silent.
        #expect(!thinking.text.isEmpty)
    }

    @Test("Check and captures are answered specifically")
    func grounded() {
        let check = OpponentStatusLine.line(for: input(isThinking: true, lastUserSAN: "Qh5+"))
        #expect(check.text.contains("check"))

        let mateThreat = OpponentStatusLine.line(for: input(isThinking: true, lastUserSAN: "Rd8#"))
        #expect(mateThreat.text.contains("check"))

        let capture = OpponentStatusLine.line(for: input(isThinking: true, lastUserSAN: "Bxf7"))
        #expect(capture.text == "So we're trading, then.")
    }

    @Test("Openings are not agonised over, and not described in slang")
    func opening() {
        let line = OpponentStatusLine.line(for: input(isThinking: true, ply: 4, lastUserSAN: "Nf3"))
        #expect(line.text == "Still the opening, I think.")
    }

    @Test("Material shapes the line, from the opponent's side of it")
    func material() {
        // A positive balance is the *user* ahead, so the opponent is the one in
        // trouble. Getting this backwards would have the opponent gloating while
        // they lose.
        let behind = OpponentStatusLine.line(for: input(isThinking: true, ply: 30, material: 4))
        #expect(behind.text == "I need something here.")

        let ahead = OpponentStatusLine.line(for: input(isThinking: true, ply: 30, material: -4))
        #expect(ahead.text == "Let's keep this simple.")

        let levelGame = OpponentStatusLine.line(for: input(isThinking: true, ply: 30, material: 1))
        #expect(levelGame.text == "Give me a second.")
    }

    @Test("A quiet capture in the opening still reads as a trade")
    func capturePrecedence() {
        let line = OpponentStatusLine.line(for: input(isThinking: true, ply: 6, lastUserSAN: "exd5"))
        #expect(line.text == "So we're trading, then.")
    }

    /// A capture is only a trade if it can be answered, and the SAN cannot tell
    /// you: `Bxf7` is the same three characters whether the bishop is walking
    /// into a recapture or collecting a free piece. Calling a hanging knight a
    /// trade is the opponent describing a board that is not there — small, but
    /// it is the one place the app claims to be looking at the position.
    @Test("A capture nobody can answer is not called a trade")
    func unansweredCaptureIsNotATrade() {
        let free = OpponentStatusLine.line(
            for: input(isThinking: true, lastUserSAN: "Bxf7", canAnswerLastCapture: false)
        )
        #expect(free.kind == .speech)
        #expect(free.text != "So we're trading, then.")
        #expect(free.text == "You took that one.")

        let trade = OpponentStatusLine.line(
            for: input(isThinking: true, lastUserSAN: "Bxf7", canAnswerLastCapture: true)
        )
        #expect(trade.text == "So we're trading, then.")
    }

    /// The traits describe search horizon and error rate, because that is all
    /// `Humanizer` implements. The old ones described playing styles — material
    /// greed, early trades, endgame squeezes — that no profile has, so a user
    /// preparing against them was preparing against a player who did not exist.
    @Test("Every roster trait describes something the opponent actually does")
    func traitsAreAboutHorizonAndErrors() {
        let styleWords = ["trades", "positional", "sharp openings", "grabs material", "solid"]
        for rating in [850, 1050, 1250, 1450, 1650, 1900, 2150] {
            let trait = OpponentRoster.opponent(forRating: rating).trait
            #expect(!trait.isEmpty)
            for word in styleWords {
                #expect(!trait.contains(word), "\(rating) claims a style the humanizer has no lever for: \(trait)")
            }
        }
    }

    @Test("A guided verdict takes the slot, in the coach's voice and not the opponent's")
    func guidedVerdict() {
        // The pause asks a question and the next move is the answer; a game
        // that never says whether it landed has asked for nothing. It outranks
        // the thinking line because that line is small talk and this is not.
        let hit = OpponentStatusLine.line(for: input(isThinking: true, guidedVerdict: true))
        #expect(hit.kind == .coach)
        #expect(hit.text.hasPrefix("Found it"))

        let miss = OpponentStatusLine.line(for: input(isThinking: false, guidedVerdict: false))
        #expect(miss.kind == .coach)
        #expect(miss.text.hasPrefix("Missed"))
        // States the fact and points somewhere. No consolation, and no claim
        // about what the better move won — the grade does not know that.
        #expect(miss.text.contains("review"))
    }

    @Test("With no verdict outstanding the slot goes back to the opponent")
    func verdictIsTheExceptionNotTheRule() {
        let line = OpponentStatusLine.line(for: input(isThinking: false))
        #expect(line.kind == .trait)
    }
}
