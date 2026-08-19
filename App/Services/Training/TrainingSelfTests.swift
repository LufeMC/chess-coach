//
//  TrainingSelfTests.swift
//  ChessCoach
//

#if DEBUG

import ChessKit
import Database
import Foundation
import TrainingCore

/// Fixtures shared by the training and coaching checks.
enum TrainingFixtures {

    /// Position after 1.e4 e5 2.Bc4 Nc6 3.Qh5, Black to move.
    ///
    /// The stored FEN of a Lichess puzzle is the position *before* the
    /// opponent's setup move, so this is the shape the corpus actually holds:
    /// Black blunders with 3...Nf6, and the solver has to find 4.Qxf7#.
    static let scholarFEN = "r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 4 3"
    static let scholarLine = ["g8f6", "h5f7"]

    /// A castling-free position, so the file mirror is legal.
    static let bareKingsFEN = "8/8/8/4k3/8/8/8/K6Q w - - 0 1"

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    static func puzzle(
        id: String,
        rating: Int = 1000,
        themes: ThemeMask = ThemeMask([.fork]),
        fen: String = scholarFEN,
        moves: [String] = scholarLine
    ) -> Puzzle {
        Puzzle(
            id: id,
            fen: fen,
            moves: moves.joined(separator: " "),
            rating: rating,
            themes: themes
        )
    }

    static func card(
        id: UUID = UUID(),
        stability: Double,
        reps: Int = 1,
        due: Date,
        lastReview: Date,
        rating: Int = 1000
    ) -> TrainingCard {
        TrainingCard(
            id: id,
            state: CardState(
                stability: stability,
                difficulty: 5,
                state: .review,
                due: due,
                lastReview: lastReview,
                reps: reps
            ),
            origin: .freshPuzzle,
            primaryTheme: .fork,
            puzzleRating: rating
        )
    }

    /// A legal 20-ply game: knights out and back. Deliberately trivial — the
    /// metric maths does not care what was played, only that the moves replay,
    /// and a real game would make the expected numbers unverifiable by hand.
    static let shuffleGameUCI: [String] = {
        var moves: [String] = []
        for index in 0..<10 {
            if index % 2 == 0 {
                moves += ["g1f3", "g8f6"]
            } else {
                moves += ["f3g1", "f6g8"]
            }
        }
        return moves
    }()

    static func game(id: UUID = UUID(), startedAt: Date, result: String? = "1-0") -> Database.Game {
        Database.Game(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            mode: GameMode.sparring,
            userColor: PlayerColor.white,
            opponentRating: 1_100,
            result: result
        )
    }

    static func moves(forGame gameID: UUID, uci: [String] = shuffleGameUCI) -> [GameMove] {
        uci.enumerated().map { index, move in
            GameMove(
                gameID: gameID,
                ply: index + 1,
                san: move,
                uci: move,
                thinkTimeMs: 6_000
            )
        }
    }

    static func moment(
        gameID: UUID,
        ply: Int,
        causeTag: String,
        deltaEP: Double,
        fen: String = startFEN
    ) -> Database.Moment {
        Database.Moment(
            gameID: gameID,
            ply: ply,
            fen: fen,
            kind: "mistake",
            causeTag: causeTag,
            stepTag: "S5",
            playedSAN: "Nf3",
            playedUCI: "g1f3",
            bestSAN: "e4",
            bestUCI: "e2e4",
            deltaEP: deltaEP,
            score: deltaEP
        )
    }
}

// MARK: - Suite

enum TrainingSelfTests {

    static func run() -> SelfCheckReport {
        var failures: [String] = []
        let suites: [() -> SelfCheck] = [
            boardTransforms,
            solveMachine,
            sessionAssembly,
            cardLadder,
            metricComputation,
            latencyBands,
            drillCriteria
        ]
        for suite in suites {
            failures.append(contentsOf: suite().failures)
        }
        return SelfCheckReport(failures: failures, checks: suites.count)
    }

    // MARK: FEN transforms

    static func boardTransforms() -> SelfCheck {
        var check = SelfCheck("BoardTransform")

        // Colour flip is an involution: applying it twice must return the
        // original text exactly, castling order included.
        for fen in [TrainingFixtures.scholarFEN, TrainingFixtures.bareKingsFEN, TrainingFixtures.startFEN] {
            guard let once = BoardTransform.colorFlipped.apply(toFEN: fen) else {
                check.expect(false, "colour flip failed for \(fen)")
                continue
            }
            let twice = BoardTransform.colorFlipped.apply(toFEN: once)
            check.equal(twice, fen, "colour flip round trip")
            check.expect(Position(fen: once) != nil, "flipped position must parse: \(once)")
        }

        // The start position flipped is the start position with Black to move.
        check.equal(
            BoardTransform.colorFlipped.apply(toFEN: TrainingFixtures.startFEN),
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1",
            "flipped start position"
        )

        // Castling rights swap colour and stay in canonical KQkq order.
        let asymmetric = "r3k3/8/8/8/8/8/8/4K2R w Kq - 0 1"
        check.equal(
            FENFields(asymmetric)?.colorFlipped().castling,
            "Qk",
            "castling rights swap and re-order"
        )

        // A mirror is refused while any castling right survives, because the
        // rights describe squares the mirror moves.
        check.expect(
            !BoardTransform.mirrored.isLegal(for: TrainingFixtures.scholarFEN),
            "mirror must be refused with castling rights"
        )
        check.equal(
            BoardTransform.resolved(for: .mirrored, fen: TrainingFixtures.scholarFEN),
            .colorFlipped,
            "mirror falls back to colour flip"
        )

        // ...and allowed once they are gone.
        check.expect(
            BoardTransform.mirrored.isLegal(for: TrainingFixtures.bareKingsFEN),
            "mirror must be legal without castling rights"
        )
        if let mirrored = BoardTransform.mirrored.apply(toFEN: TrainingFixtures.bareKingsFEN) {
            check.expect(Position(fen: mirrored) != nil, "mirrored position must parse")
            check.equal(
                BoardTransform.mirrored.apply(toFEN: mirrored),
                TrainingFixtures.bareKingsFEN,
                "mirror round trip"
            )
        } else {
            check.expect(false, "mirror produced nothing")
        }

        // Moves travel with the board.
        check.equal(BoardTransform.colorFlipped.apply(toUCI: "e2e4"), "e7e5", "flip a move")
        check.equal(BoardTransform.mirrored.apply(toUCI: "e2e4"), "d7d5", "mirror a move")
        check.equal(BoardTransform.colorFlipped.apply(toUCI: "e7e8q"), "e2e1q", "promotion suffix survives")
        check.equal(BoardTransform.identity.apply(toUCI: "a1h8"), "a1h8", "identity")

        // En passant travels too, or the transformed position is a different
        // position from the one that was stored.
        check.equal(
            FENFields("8/8/8/3pP3/8/8/8/K6k w - d6 0 1")?.colorFlipped().enPassant,
            "d3",
            "en passant square flips rank"
        )

        // A transformed puzzle's line must still be a solution to the
        // transformed position — the whole point of transforming both.
        let item = SolvableItem(puzzle: TrainingFixtures.puzzle(id: "p1"))
        if let presented = PresentedPuzzle(item: item, transform: .colorFlipped),
           var machine = presented.machine() {
            machine.start()
            for move in presented.line.dropFirst() {
                _ = machine.play(uci: move)
            }
            check.equal(machine.phase, .solved, "flipped puzzle still solves")
        } else {
            check.expect(false, "could not present flipped puzzle")
        }

        return check
    }

    // MARK: Solve state machine

    static func solveMachine() -> SelfCheck {
        var check = SelfCheck("PuzzleSolveMachine")

        func fresh(_ policy: PuzzleSolveMachine.RetryPolicy = .endOnFirstMistake) -> PuzzleSolveMachine? {
            PuzzleSolveMachine(
                fen: TrainingFixtures.scholarFEN,
                line: TrainingFixtures.scholarLine,
                retryPolicy: policy
            )
        }

        // The setup move belongs to the opponent and is played for the user.
        guard var machine = fresh() else {
            check.expect(false, "machine did not build")
            return check
        }
        check.equal(machine.phase, .ready, "starts un-started")
        check.equal(machine.start(), "g8f6", "setup move")
        check.equal(machine.phase, .awaitingUser, "user to move after setup")
        check.equal(machine.expectedMove, "h5f7", "expected user move")

        // The full line solves.
        check.equal(machine.play(uci: "h5f7"), .solved, "correct move solves")
        check.equal(machine.phase, .solved, "phase")
        check.expect(machine.attempt(latencyMs: 5_000, bandMedianLatencyMs: 9_000).correct, "attempt is correct")
        check.equal(
            machine.attempt(latencyMs: 5_000, bandMedianLatencyMs: 9_000).rating(),
            .easy,
            "fast unaided solve grades easy"
        )

        // A legal but wrong move ends the attempt.
        guard var wrong = fresh() else { return check }
        wrong.start()
        check.equal(wrong.play(uci: "h5e5"), .failed(expected: "h5f7"), "wrong move fails")
        check.equal(wrong.phase, .failed(.wrongMove(played: "h5e5", expected: "h5f7")), "failure reason")
        check.expect(!wrong.attempt(latencyMs: 1_000, bandMedianLatencyMs: 9_000).correct, "attempt is incorrect")

        // An illegal move is a mis-tap, not an answer: nothing is scored and the
        // machine is still waiting.
        guard var illegal = fresh() else { return check }
        illegal.start()
        check.equal(illegal.play(uci: "a1a5"), .illegal, "illegal move rejected")
        check.equal(illegal.phase, .awaitingUser, "still awaiting the user")
        check.equal(illegal.wrongAttempts, 0, "illegal move is not a wrong attempt")

        // A hint loses the attempt even when the line is then played perfectly.
        guard var hinted = fresh() else { return check }
        hinted.start()
        check.equal(hinted.revealHint(), "h5f7", "hint reveals the move")
        check.equal(hinted.play(uci: "h5f7"), .solved, "line still playable after a hint")
        let hintedAttempt = hinted.attempt(latencyMs: 1_000, bandMedianLatencyMs: 9_000)
        check.expect(hintedAttempt.usedHint, "hint recorded")
        check.equal(hintedAttempt.rating(), .again, "a hinted solve grades again")

        // A relearn item gets one retry, and taking it grades `.hard`.
        guard var retrying = fresh(.allowRetries(1)) else { return check }
        retrying.start()
        check.equal(
            retrying.play(uci: "h5e5"),
            .retry(expected: "h5f7", retriesRemaining: 1),
            "first mistake offers a retry"
        )
        check.equal(retrying.phase, .awaitingUser, "retry keeps the machine alive")
        check.equal(retrying.play(uci: "h5f7"), .solved, "retry solves")
        let retryAttempt = retrying.attempt(latencyMs: 1_000, bandMedianLatencyMs: 9_000)
        check.expect(retryAttempt.retried, "retry recorded")
        check.equal(retryAttempt.rating(), .hard, "a retried solve grades hard")

        // A two-move line: the opponent's reply between the user's moves is
        // played automatically, and the user is never asked for it.
        if var long = PuzzleSolveMachine(
            fen: TrainingFixtures.startFEN,
            line: ["e2e4", "e7e5", "g1f3", "b8c6"]
        ) {
            check.equal(long.start(), "e2e4", "setup move is the opponent's")
            check.equal(long.expectedMove, "e7e5", "user answers first")
            // A move for the side that is not to move is not a wrong answer,
            // it is not a move at all.
            check.equal(long.play(uci: "d2d4"), .illegal, "a move for the wrong side is illegal")
            check.equal(
                long.play(uci: "e7e5"),
                .advanced(opponentReply: "g1f3"),
                "the opponent's reply is auto-played"
            )
            check.equal(long.expectedMove, "b8c6", "user is asked for the next move, not the reply")
            check.equal(long.play(uci: "b8c6"), .solved, "line completes")
            check.equal(long.cursor, 4, "whole line consumed")
        } else {
            check.expect(false, "two-move machine did not build")
        }

        // A position mined from the user's own game has no setup move.
        if var mined = PuzzleSolveMachine(
            fen: TrainingFixtures.startFEN,
            line: ["e2e4"],
            opponentMovesFirst: false
        ) {
            check.equal(mined.start(), nil, "no setup move to play")
            check.equal(mined.phase, .awaitingUser, "user moves immediately")
            check.equal(mined.play(uci: "e2e4"), .solved, "single-move line solves")
        } else {
            check.expect(false, "mined position machine did not build")
        }

        return check
    }

    // MARK: Session assembly

    static func sessionAssembly() -> SelfCheck {
        var check = SelfCheck("SessionAssembler")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lastReview = now.addingTimeInterval(-10 * 86_400)

        // Twelve due cards, decreasing stability. Lower stability at the same
        // elapsed time means lower retrievability, so card 11 is closest to
        // being forgotten and must go first.
        var cards: [TrainingCard] = []
        var positions: [TrainingCard.ID: SolvableItem] = [:]
        for index in 0..<12 {
            let card = TrainingFixtures.card(
                stability: Double(60 - index * 4),
                due: now.addingTimeInterval(-3_600),
                lastReview: lastReview
            )
            cards.append(card)
            positions[card.id] = SolvableItem(puzzle: TrainingFixtures.puzzle(id: "due-\(index)"))
        }

        let fresh = (0..<10).map { TrainingFixtures.puzzle(id: "fresh-\($0)") }
        let session = SessionAssembler.assemble(
            SessionAssembler.Inputs(
                dueCards: cards,
                positions: positions,
                generalPuzzles: fresh,
                now: now
            )
        )

        // Seven reviews is the cap, and the session tops up to ten.
        check.equal(session.items.count, 10, "session size")
        check.equal(session.items.filter { $0.kind.isReview }.count, 7, "review cap")
        check.equal(session.items.filter { !$0.kind.isReview }.count, 3, "fresh backfill")

        // Ordered by lowest retrievability: the least stable card leads.
        let scheduler = FSRS6()
        let servedIDs = session.items.compactMap(\.kind.cardID)
        let servedRetrievability = servedIDs.compactMap { id in
            cards.first { $0.id == id }.map { scheduler.retrievability(card: $0.state, now: now) }
        }
        check.equal(servedRetrievability.count, 7, "retrievability sampled")
        check.expect(
            zip(servedRetrievability, servedRetrievability.dropFirst()).allSatisfy { $0 <= $1 },
            "reviews must be ordered by ascending retrievability, got \(servedRetrievability)"
        )
        check.equal(
            servedIDs.first,
            cards.last?.id,
            "least stable card is served first"
        )

        // With no due cards the whole session is fresh, split 60/40 toward the
        // weekly focus.
        let focus = WeeklyFocus(habit: .calcToQuiet)
        let biased = SessionAssembler.assemble(
            SessionAssembler.Inputs(
                focusThemedPuzzles: (0..<10).map { TrainingFixtures.puzzle(id: "focus-\($0)") },
                generalPuzzles: (0..<10).map { TrainingFixtures.puzzle(id: "general-\($0)") },
                focus: focus,
                now: now
            )
        )
        check.equal(biased.items.count, 10, "all fresh")
        check.equal(biased.mix.focusThemed, 6, "60% focus themed")
        check.equal(biased.items.filter(\.isFocusThemed).count, 6, "six focus puzzles served")
        check.expect(
            biased.items.prefix(6).allSatisfy(\.isFocusThemed),
            "focus puzzles come first so an abandoned session still holds the week's work"
        )

        // Fresh slots shrink to what the corpus can supply rather than the
        // session refusing to start.
        let thin = SessionAssembler.assemble(
            SessionAssembler.Inputs(generalPuzzles: [TrainingFixtures.puzzle(id: "only")], now: now)
        )
        check.equal(thin.items.count, 1, "thin corpus shrinks the session")

        // Same-day retries are appended at the end, not inline.
        guard let firstCardID = servedIDs.first else { return check }
        let withRetries = SessionAssembler.appendingRelearnRetries(to: session, failedCardIDs: [firstCardID])
        check.equal(withRetries.items.count, 11, "one retry appended")
        if case let .relearn(cardID) = withRetries.items.last?.kind {
            check.equal(cardID, firstCardID, "retry is for the failed card")
        } else {
            check.expect(false, "last item should be a relearn")
        }
        check.equal(withRetries.items.last?.retryPolicy, .allowRetries(1), "a retry allows a second try")

        // Retired cards are reported, not queued.
        var retired = TrainingFixtures.card(stability: 100, due: now.addingTimeInterval(-1), lastReview: lastReview)
        retired.isGeneralized = true
        retired.siblingPassedAtLongInterval = true
        let withRetired = SessionAssembler.assemble(
            SessionAssembler.Inputs(
                dueCards: [retired],
                positions: [retired.id: SolvableItem(puzzle: TrainingFixtures.puzzle(id: "retired"))],
                now: now
            )
        )
        check.equal(withRetired.retired, [retired.id], "retired card reported")
        check.equal(withRetired.items.filter { $0.kind.isReview }.count, 0, "retired card not queued")

        return check
    }

    // MARK: Anti-memorization ladder

    static func cardLadder() -> SelfCheck {
        var check = SelfCheck("CardLadderState")
        let cardID = UUID()
        let start = Date(timeIntervalSince1970: 1_600_000_000)

        func log(_ rating: Int, elapsedDays: Double, dayOffset: Double) -> ReviewLog {
            ReviewLog(
                cardID: cardID,
                reviewedAt: start.addingTimeInterval(dayOffset * 86_400),
                rating: rating,
                stateBefore: Database.SRSState.review.rawValue,
                elapsedDays: elapsedDays,
                scheduledDays: elapsedDays
            )
        }

        check.equal(CardLadderState.derive(from: []), CardLadderState(), "no history, no ladder")

        // A pass at a short interval is not evidence of anything.
        check.equal(
            CardLadderState.derive(from: [log(3, elapsedDays: 3, dayOffset: 3)]).consecutiveLongIntervalPasses,
            0,
            "short-interval pass does not count"
        )

        // Two long-interval passes earn a sibling but do not yet mean the card
        // is generalized — the sibling has not been shown.
        let earned = CardLadderState.derive(from: [
            log(3, elapsedDays: 25, dayOffset: 25),
            log(4, elapsedDays: 30, dayOffset: 55)
        ])
        check.equal(earned.consecutiveLongIntervalPasses, 2, "two long passes")
        check.expect(!earned.isGeneralized, "not generalized until the sibling is served")

        var card = TrainingFixtures.card(stability: 60, due: start, lastReview: start)
        card.consecutiveLongIntervalPasses = earned.consecutiveLongIntervalPasses
        card.isGeneralized = earned.isGeneralized
        if case .themeSibling = CardPolicy.presentation(for: card) {
            check.expect(true, "")
        } else {
            check.expect(false, "policy should ask for a theme sibling")
        }

        // The next review *is* the sibling.
        let served = CardLadderState.derive(from: [
            log(3, elapsedDays: 25, dayOffset: 25),
            log(4, elapsedDays: 30, dayOffset: 55),
            log(3, elapsedDays: 5, dayOffset: 60)
        ])
        check.expect(served.isGeneralized, "sibling served")
        check.expect(!served.siblingPassedAtLongInterval, "sibling has not passed at a long interval yet")

        // And a long-interval pass on the sibling retires the card.
        let retired = CardLadderState.derive(from: [
            log(3, elapsedDays: 25, dayOffset: 25),
            log(4, elapsedDays: 30, dayOffset: 55),
            log(3, elapsedDays: 5, dayOffset: 60),
            log(3, elapsedDays: 40, dayOffset: 100)
        ])
        check.expect(retired.siblingPassedAtLongInterval, "sibling passed")
        card.isGeneralized = retired.isGeneralized
        card.siblingPassedAtLongInterval = retired.siblingPassedAtLongInterval
        check.equal(CardPolicy.presentation(for: card), .retire, "card retires")

        // A failure resets the streak.
        let lapsed = CardLadderState.derive(from: [
            log(3, elapsedDays: 25, dayOffset: 25),
            log(1, elapsedDays: 30, dayOffset: 55)
        ])
        check.equal(lapsed.consecutiveLongIntervalPasses, 0, "failure resets")

        return check
    }

    // MARK: Metrics

    static func metricComputation() -> SelfCheck {
        var check = SelfCheck("MetricComputer")
        let tuning = DomainTuning.default
        let threshold = MetricComputer.hangingPieceEPThreshold(tuning: tuning.curriculum)

        // 300cp from equality is a quarter of a point, give or take.
        check.expect(
            threshold > 0.2 && threshold < 0.3,
            "hanging-piece EP threshold should be ≈0.25, got \(threshold)"
        )

        // One game, ten user moves, three hanging moments — one of them below
        // the curriculum's severity threshold and therefore not counted.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gameID = UUID()
        let single = AnalysedGame(
            game: TrainingFixtures.game(id: gameID, startedAt: now),
            moves: TrainingFixtures.moves(forGame: gameID),
            moments: [
                TrainingFixtures.moment(gameID: gameID, ply: 1, causeTag: "hungMovedPiece", deltaEP: 0.4),
                TrainingFixtures.moment(gameID: gameID, ply: 3, causeTag: "hungLeftPiece", deltaEP: 0.4),
                TrainingFixtures.moment(gameID: gameID, ply: 5, causeTag: "hungMovedPiece", deltaEP: 0.1)
            ]
        )

        let statistics = MetricComputer.statistics(for: single, tuning: tuning)
        check.equal(statistics.userMoves, 10, "user moves in a 20-ply game")
        check.equal(statistics.causeCounts["hungMovedPiece"], 1, "sub-threshold hang excluded")
        check.equal(statistics.causeCounts["hungLeftPiece"], 1, "left-piece hang counted")

        let computed = MetricComputer.compute(games: [single], counters: MetricCounters(), tuning: tuning)
        let hanging = computed[MetricAddress(key: .hangingPiecePer100, window: .lastGames(8))]
        check.close(hanging?.value ?? -1, 20, "two hangs over ten moves is 20 per 100")
        check.equal(hanging?.sampleCount, 10, "sample count is the move count")

        // Window handling: the older games carry more mistakes, so a wider
        // window must report a worse rate. If the slice were ignored the two
        // numbers would be identical.
        var games: [AnalysedGame] = []
        for index in 0..<12 {
            let id = UUID()
            let momentCount = index < 8 ? 1 : 3
            games.append(
                AnalysedGame(
                    game: TrainingFixtures.game(id: id, startedAt: now.addingTimeInterval(-Double(index) * 86_400)),
                    moves: TrainingFixtures.moves(forGame: id),
                    moments: (0..<momentCount).map {
                        TrainingFixtures.moment(gameID: id, ply: $0 * 2 + 1, causeTag: "hungMovedPiece", deltaEP: 0.4)
                    }
                )
            )
        }
        let windowed = MetricComputer.compute(games: games, counters: MetricCounters(), tuning: tuning)
        let last8 = windowed[MetricAddress(key: .hangingPiecePer100, window: .lastGames(8))]?.value ?? -1
        let last12 = windowed[MetricAddress(key: .hangingPiecePer100, window: .lastGames(12))]?.value ?? -1
        check.close(last8, 10, "8 mistakes over 80 moves")
        check.close(last12, 20.0 / 1.2, "20 mistakes over 120 moves")
        check.expect(last12 > last8, "a window reaching back into a worse patch must report worse")

        // Lifetime counters ride through untouched.
        var counters = MetricCounters()
        counters.puzzleRating = 1_234
        counters.themeAttempts[.fork] = 20
        counters.themeSolves[.fork] = 15
        counters.cleanRetryAttempts = 4
        counters.cleanRetrySuccesses = 3
        let lifetime = MetricComputer.compute(games: [single], counters: counters, tuning: tuning)
        check.close(lifetime[MetricAddress(key: .puzzleRating, window: .allTime)]?.value ?? 0, 1_234, "puzzle rating")
        let forks = lifetime[
            MetricAddress(
                key: .puzzleThemeSuccess(.fork, ratingFloor: tuning.curriculum.themeRatingFloor),
                window: .allTime
            )
        ]
        check.close(forks?.value ?? 0, 0.75, "fork success rate")
        check.equal(forks?.sampleCount, 20, "attempts are the sample count")
        check.close(
            lifetime[MetricAddress(key: .cleanRetryRate, window: .lastGames(8))]?.value ?? 0,
            0.75,
            "clean retry rate"
        )

        // A metric with no data source must stay unwritten, so the curriculum
        // reports it as unmeasured rather than failed.
        check.expect(
            lifetime[MetricAddress(key: .prophylacticFindRate, window: .lastGames(12))] == nil,
            "unsupported metrics are not fabricated"
        )

        // Development counting: four vacated home squares after both knights
        // and both bishops have moved.
        if let position = Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") {
            check.equal(MetricComputer.developedMinors(in: position, white: true), 0, "nothing developed at the start")
        }
        if let position = Position(fen: "rnbqkbnr/pppppppp/8/8/8/2N2N2/PPPPPPPP/R1BQKB1R w KQkq - 0 1") {
            check.equal(MetricComputer.developedMinors(in: position, white: true), 2, "two knights out")
        }

        // Clock pressure needs a tail of snap judgements, not one fast move.
        check.expect(
            MetricComputer.endedInClockPressure(userThinkTimes: Array(repeating: 8_000, count: 20), termination: nil)
                == false,
            "a steady game is not clock pressure"
        )
        check.expect(
            MetricComputer.endedInClockPressure(
                userThinkTimes: Array(repeating: 8_000, count: 12) + Array(repeating: 500, count: 8),
                termination: nil
            ),
            "a tail of snap moves is clock pressure"
        )
        check.expect(
            MetricComputer.endedInClockPressure(userThinkTimes: [], termination: "timeout"),
            "an explicit timeout short-circuits"
        )

        return check
    }

    // MARK: Latency bands

    static func latencyBands() -> SelfCheck {
        var check = SelfCheck("LatencyBandMedian")

        check.equal(TrainingVocabulary.latencyBand(forRating: 0), 0, "band floor")
        check.equal(TrainingVocabulary.latencyBand(forRating: 1_250), 6, "1250 is band 6")
        check.expect(
            LatencyBandMedian.seed(band: 6) > LatencyBandMedian.seed(band: 2),
            "harder bands seed slower"
        )

        // Frugal-1U converges on the median of a stationary stream.
        //
        // Two things here are deliberate. The stream is **seeded**, because a
        // self-check that ships in the app and consults the system RNG is a
        // check that fails on some launches and not others — which teaches
        // whoever sees it to ignore it. And the assertion is on the **mean of
        // the tail**, not on the final value, because a single terminal reading
        // is not something Frugal-1U promises: the estimator does a random walk
        // whose step is 6% of the estimate, so it is always somewhere in a wide
        // band around the median and can be a long way off on any given sample.
        // Averaging the last quarter tests the property the algorithm actually
        // has. (Asserting the terminal value is what the earlier version did,
        // and it went red roughly one run in three.)
        var estimate = LatencyBandMedian.seed(band: 5)
        var rng = DeterministicStream(seed: 0x5EED_1A7E)
        var tail: [Double] = []
        let sampleCount = 400
        for index in 0..<sampleCount {
            let sample = 5_000 + rng.nextUnitInterval() * 20_000
            estimate = LatencyBandMedian.updated(estimate: estimate, sample: sample)
            if index >= sampleCount * 3 / 4 { tail.append(estimate) }
        }
        let settled = tail.reduce(0, +) / Double(tail.count)
        check.expect(
            settled > 13_000 && settled < 17_000,
            "estimate should settle near the 15s median, got \(settled)"
        )

        // ...and moves toward a sample rather than away from it.
        check.expect(
            LatencyBandMedian.updated(estimate: 10_000, sample: 30_000) > 10_000,
            "a slow sample raises the estimate"
        )
        check.expect(
            LatencyBandMedian.updated(estimate: 10_000, sample: 1_000) < 10_000,
            "a fast sample lowers it"
        )

        return check
    }

    /// A tiny SplitMix64, so the checks that need a sample stream get the same
    /// one on every device and every launch.
    ///
    /// Local to the self-checks rather than exposed: nothing in the app should
    /// be reaching for a seeded generator, and a shared one would invite it.
    private struct DeterministicStream {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in `0..<1`, from the top 53 bits — the low bits of an LCG-ish
        /// generator are the least well distributed.
        mutating func nextUnitInterval() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }

    // MARK: Drills

    static func drillCriteria() -> SelfCheck {
        var check = SelfCheck("EndgameDrillRun")

        // Every catalogue position must parse and put the user on move.
        for drill in EndgameDrill.catalogue {
            check.expect(Position(fen: drill.fen) != nil, "\(drill.id) has an unparseable FEN")
            check.expect(EndgameDrillRun(drill: drill) != nil, "\(drill.id) did not build a run")
        }

        // The KPK set must contain both won and drawn positions, or it tests
        // nothing: a user who always pushes would pass a set of six wins.
        let verdicts = EndgameDrill.kpkSet.compactMap { drill in
            Position(fen: drill.fen).flatMap(EndgameDrillRun.kpkOutcome)
        }
        check.equal(verdicts.count, EndgameDrill.kpkSet.count, "every KPK position probes")
        check.expect(verdicts.contains(.win), "the KPK set needs at least one win")
        check.expect(verdicts.contains(.draw), "the KPK set needs at least one draw")

        // Running out of moves fails a mate drill.
        if var run = EndgameDrillRun(drill: EndgameDrill.basicMates[0]) {
            check.equal(run.result, .inProgress, "starts in progress")
            check.expect(run.isUserToMove, "user moves first")
            // Shuffle the king back and forth past the budget.
            var toggle = true
            while run.result == .inProgress, run.userMoveCount < run.moveBudget + 2 {
                let userMove = toggle ? "a1a2" : "a2a1"
                let opponentMove = toggle ? "e5e6" : "e6e5"
                guard run.play(uci: userMove) else { break }
                if run.result == .inProgress { _ = run.play(uci: opponentMove) }
                toggle.toggle()
            }
            check.equal(run.result, .failed, "a mate drill that runs out of moves fails")
        }

        // A drill's streak metric maps to the key the curriculum reads.
        check.equal(EndgameDrillKind.kqk.streakMetricKey, .kqkDrillCleanStreak, "kqk key")
        check.equal(EndgameDrillKind.kpk.streakMetricKey, .kpkDrillCleanSetStreak, "kpk key")
        check.expect(EndgameDrillKind.kpk.isSetScored, "kpk is scored by sets")
        check.expect(!EndgameDrillKind.krk.isSetScored, "krk is scored by runs")

        check.expect(
            Curriculum.basicMateDrillIsClean(mate: .kqk, moves: 15),
            "15 moves is a clean KQK"
        )
        check.expect(
            !Curriculum.basicMateDrillIsClean(mate: .kqk, moves: 16),
            "16 moves is not"
        )

        return check
    }
}

#endif
