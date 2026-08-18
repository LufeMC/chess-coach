//
//  CoachSelfTests.swift
//  ChessCoach
//

#if DEBUG

import ClaudeKit
import Database
import Foundation
import TrainingCore

enum CoachSelfTests {

    static func run() -> SelfCheckReport {
        var failures: [String] = []
        let suites: [() -> SelfCheck] = [
            vocabulary,
            lineNotation,
            requestConstruction,
            partialTextScanner
        ]
        for suite in suites {
            failures.append(contentsOf: suite().failures)
        }
        return SelfCheckReport(failures: failures, checks: suites.count)
    }

    // MARK: Vocabulary

    static func vocabulary() -> SelfCheck {
        var check = SelfCheck("CoachVocabularyBridge")

        // Every curriculum habit must map to an id the verifier will accept.
        // Without this the model is handed an unknown habit in the profile and
        // its answer is rejected on the way back — silently, and every time.
        for habit in Habit.allCases {
            let id = CoachVocabularyBridge.habitID(for: habit)
            check.expect(
                CoachingVocabulary.habitIDs.contains(id),
                "\(habit.rawValue) maps to \"\(id)\", which is not a contract habit id"
            )
            // The micro-goal metric must belong to that habit or the weekly
            // validator rejects it.
            check.expect(
                CoachingVocabulary.metric(CoachVocabularyBridge.metricID(for: habit), belongsTo: id),
                "\(habit.rawValue)'s metric does not belong to \(id)"
            )
            check.expect(!CoachVocabularyBridge.stepTag(for: habit).isEmpty, "\(habit.rawValue) has no step tag")
        }

        // And every contract habit must map back to something the curriculum
        // measures, or accepting the model's suggestion would strand the user.
        for habit in CoachingVocabulary.habits {
            check.expect(
                CoachVocabularyBridge.habit(forID: habit.id, rung: 2) != nil,
                "contract habit \(habit.id) maps back to nothing"
            )
        }

        check.equal(
            CoachVocabularyBridge.habit(forID: "followOpeningPrinciples", rung: 1),
            .blunderCheck,
            "opening errors at rung 1 are a blunder-check problem"
        )
        check.equal(
            CoachVocabularyBridge.habit(forID: "followOpeningPrinciples", rung: 3),
            .candidatesFirst,
            "...and a move-choice problem above it"
        )
        check.equal(CoachVocabularyBridge.habit(forID: "notAHabit", rung: 1), nil, "unknown id maps to nothing")

        check.equal(CoachVocabularyBridge.trend(forDelta: 0), .flat, "no movement is flat")
        check.equal(CoachVocabularyBridge.trend(forDelta: 0.05), .worsening, "losing more points is worse")
        check.equal(CoachVocabularyBridge.trend(forDelta: -0.05), .improving, "losing fewer is better")

        return check
    }

    // MARK: SAN conversion

    static func lineNotation() -> SelfCheck {
        var check = SelfCheck("LineNotation")

        check.equal(
            LineNotation.san(forUCILine: ["e2e4", "e7e5", "g1f3", "b8c6"], fromFEN: TrainingFixtures.startFEN),
            ["e4", "e5", "Nf3", "Nc6"],
            "basic SAN conversion"
        )

        // Captures, checks and mate carry their notation.
        check.equal(
            LineNotation.san(forUCILine: ["h5f7"], fromFEN: "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 0 1"),
            ["Qxf7#"],
            "capture and mate"
        )

        // Promotion, with and without the check the new queen happens to give.
        check.equal(
            LineNotation.san(forUCILine: ["a7a8q"], fromFEN: "8/P7/8/4k3/8/8/8/K7 w - - 0 1"),
            ["a8=Q"],
            "promotion"
        )
        check.equal(
            LineNotation.san(forUCILine: ["a7a8q"], fromFEN: "8/P7/8/8/8/8/8/K6k w - - 0 1"),
            ["a8=Q+"],
            "promotion that gives check carries the annotation"
        )

        // The cap is applied, and it is the contract's cap.
        let long = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "d2d3", "f8c5", "b1c3", "d7d6"]
        let capped = LineNotation.san(forUCILine: long, fromFEN: TrainingFixtures.startFEN)
        check.equal(capped.count, CoachRequest.Caps.maxPVPlies, "PV truncated at the contract cap")

        // A line that stops replaying is truncated, never invented.
        check.equal(
            LineNotation.san(forUCILine: ["e2e4", "e2e4"], fromFEN: TrainingFixtures.startFEN),
            ["e4"],
            "an unplayable continuation truncates the line"
        )
        check.equal(
            LineNotation.san(forUCILine: ["e2e4"], fromFEN: "not a fen"),
            [],
            "a bad FEN yields no line"
        )

        check.equal(LineNotation.plies("e2e4 e7e5  g1f3"), ["e2e4", "e7e5", "g1f3"], "PV splitting")

        return check
    }

    // MARK: Request construction

    static func requestConstruction() -> SelfCheck {
        var check = SelfCheck("CoachRequestBuilder")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gameID = UUID()

        var settings = AppSettings()
        settings.userRating = 1_320
        settings.puzzleRD = 85

        // Five moments and a twelve-ply PV: both caps must bite.
        let moments = (0..<5).map { index in
            Database.Moment(
                gameID: gameID,
                ply: index * 2 + 1,
                fen: TrainingFixtures.startFEN,
                kind: "mistake",
                causeTag: "hungMovedPiece",
                stepTag: "S5",
                playedSAN: "Nf3",
                playedUCI: "g1f3",
                bestSAN: "e4",
                bestUCI: "e2e4",
                deltaEP: 0.5 - Double(index) * 0.05,
                score: 1 - Double(index) * 0.1
            )
        }

        let longPV = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "d2d3", "f8c5", "b1c3", "d7d6", "c1g5", "h7h6"]
        let evals = moments.map { moment in
            PlyEval(
                gameID: gameID,
                ply: moment.ply,
                pv1Cp: 40,
                pv1: longPV.joined(separator: " "),
                pv2Cp: 10,
                pv2: "d2d4 e7e5"
            )
        }

        let inputs = CoachRequestBuilder.Inputs(
            game: TrainingFixtures.game(id: gameID, startedAt: now),
            moves: TrainingFixtures.moves(forGame: gameID),
            evals: evals,
            moments: moments,
            settings: settings,
            rung: Curriculum.default[1],
            focus: WeeklyFocus(habit: .blunderCheck),
            microGoal: MicroGoalState(
                metricKey: .hangingPiecePer100,
                window: .lastGames(8),
                target: 1.0,
                comparison: .lessThan,
                current: 2.4
            ),
            leaks: [
                Leak(causeTag: .hungMovedPiece, habit: .blunderCheck, weightedEPLost: 2, epLostPerGame: 0.25, count: 8, deltaVsPreviousWeek: 0.03),
                Leak(causeTag: .missedNewThreat, habit: .whatChanged, weightedEPLost: 1, epLostPerGame: 0.12, count: 4, deltaVsPreviousWeek: -0.02),
                Leak(causeTag: .positionalDrift, habit: .candidatesFirst, weightedEPLost: 0.5, epLostPerGame: 0.06, count: 3, deltaVsPreviousWeek: 0),
                Leak(causeTag: .kingExposure, habit: .scanThreats, weightedEPLost: 0.2, epLostPerGame: 0.02, count: 1, deltaVsPreviousWeek: 0)
            ]
        )

        let request = CoachRequestBuilder.build(inputs)

        // Caps.
        check.equal(request.moments.count, CoachRequest.Caps.maxMoments, "at most three moments")
        check.equal(request.profile.leakTop3.count, 3, "top three leaks only")
        for moment in request.moments {
            for line in moment.engineLines {
                check.expect(
                    line.pvSAN.count <= CoachRequest.Caps.maxPVPlies,
                    "PV over the cap: \(line.pvSAN.count) plies"
                )
                check.equal(line.pvSAN.count, line.pvUCI.count, "SAN and UCI must stay index-aligned")
            }
        }

        // Highest-scoring moments win the three slots.
        check.equal(request.moments.first?.momentID, moments[0].id.uuidString, "best moment first")
        check.expect(
            !request.moments.contains { $0.momentID == moments[4].id.uuidString },
            "lowest-scoring moment dropped"
        )

        // SAN conversion is real, not a copy of the UCI.
        let best = request.moments.first?.engineLines.first { $0.label == .best }
        check.equal(best?.pvSAN.prefix(4).map { $0 }, ["e4", "e5", "Nf3", "Nc6"], "PV converted to SAN")
        check.equal(best?.pvUCI.prefix(2).map { $0 }, ["e2e4", "e7e5"], "UCI preserved for the verifier")
        check.equal(best?.evalCp, 40, "eval carried")
        check.expect(
            request.moments.first?.engineLines.contains { $0.label == .alt } == true,
            "the second PV is offered as an alternative line"
        )

        // Profile.
        check.equal(request.profile.ratingEstimate, 1_320, "rating")
        check.equal(request.profile.ratingUncertainty, 85, "uncertainty")
        check.equal(request.profile.rung.id, "r2", "rung id")
        check.equal(request.profile.weeklyFocus.habitID, "blunderCheckBeforeMoving", "focus habit id")
        check.close(request.profile.weeklyFocus.microGoal.target, 1.0, "micro-goal target")
        check.close(request.profile.weeklyFocus.microGoal.current, 2.4, "micro-goal current")
        check.equal(request.profile.leakTop3.first?.trend, .worsening, "leak trend")
        check.equal(request.profile.leakTop3.last?.trend, .flat, "an undefined comparison reads as flat")

        // Game summary.
        check.equal(request.game.result, .win, "white won")
        check.equal(request.game.userColor, .white, "user colour")
        check.equal(request.game.moveCount, 10, "20 plies is 10 moves")
        check.expect(request.game.opening.hasPrefix("1.g1f3"), "opening names the moves actually played")
        check.equal(request.game.timeControl, "unknown", "no time control in the blob is 'unknown', not a guess")
        check.equal(
            CoachRequestBuilder.timeControl(from: "{\"baseSeconds\":600,\"incrementSeconds\":5}"),
            "10+5",
            "time control parsed when present"
        )

        // A moment with no stored evaluation still offers the one line we can
        // vouch for, rather than none.
        let bare = CoachRequestBuilder.engineLines(for: moments[0], eval: nil)
        check.equal(bare.count, 1, "one fallback line")
        check.equal(bare.first?.pvUCI, ["e2e4"], "the moment's own best move")

        // `capped()` is idempotent — the builder applies it, so applying it
        // again on the way out of ClaudeKit must change nothing.
        check.equal(request.capped(), request, "capping is idempotent")

        return check
    }

    // MARK: Streaming scanner

    static func partialTextScanner() -> SelfCheck {
        var check = SelfCheck("PartialCoachTextScanner")

        var scanner = PartialCoachTextScanner()

        // Nothing usable yet.
        check.equal(scanner.consume("{\"gameNote\":{\"headline\":\"Nice\",").count, 0, "no moments yet")

        // A moment id with a half-written question.
        var fragments = scanner.consume("\"momentNotes\":[{\"momentID\":\"m-1\",\"question\":\"What did the")
        check.equal(fragments.count, 1, "one moment in flight")
        check.equal(fragments.first?.momentID, "m-1", "id read")
        check.equal(fragments.first?.question, "What did the", "partial question")
        check.expect(fragments.first?.isComplete == false, "not complete")

        // ...then the rest of it and the explanation.
        fragments = scanner.consume(" knight attack?\",\"explanation\":\"It forked the")
        check.equal(fragments.first?.question, "What did the knight attack?", "question completed")
        check.equal(fragments.first?.explanation, "It forked the", "partial explanation")
        check.expect(fragments.first?.isComplete == false, "still incomplete")

        fragments = scanner.consume(" king and rook.\",\"causeAffirmed\":true},")
        check.equal(fragments.first?.explanation, "It forked the king and rook.", "explanation completed")
        check.expect(fragments.first?.isComplete == true, "complete once the closing quote lands")

        // A second note does not steal the first one's fields.
        fragments = scanner.consume("{\"momentID\":\"m-2\",\"question\":\"And here?\"")
        check.equal(fragments.count, 2, "two moments")
        check.equal(fragments[0].question, "What did the knight attack?", "first note unchanged")
        check.equal(fragments[1].momentID, "m-2", "second id")
        check.equal(fragments[1].question, "And here?", "second question")
        check.equal(fragments[1].explanation, "", "second explanation has not arrived")

        // Escapes are decoded rather than shown raw.
        var escaping = PartialCoachTextScanner()
        let escaped = escaping.consume(
            "[{\"momentID\":\"m\",\"question\":\"line one\\nline \\\"two\\\"\",\"explanation\":\"done\"}]"
        )
        check.equal(escaping.fragments().count, 1, "one fragment")
        check.equal(escaped.first?.question, "line one\nline \"two\"", "escapes decoded")

        // A dangling escape at the buffer edge is dropped, not emitted raw.
        var dangling = PartialCoachTextScanner()
        let partial = dangling.consume("[{\"momentID\":\"m\",\"question\":\"ends with a backslash\\")
        check.equal(partial.first?.question, "ends with a backslash", "dangling escape withheld")

        return check
    }
}

/// Runs every self-check in the training and coaching layers.
enum ServiceSelfTests {
    static func run() -> SelfCheckReport {
        let training = TrainingSelfTests.run()
        let coach = CoachSelfTests.run()
        return SelfCheckReport(
            failures: training.failures + coach.failures,
            checks: training.checks + coach.checks
        )
    }
}

#endif
