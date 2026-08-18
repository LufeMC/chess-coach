//
//  Fixtures.swift
//  ClaudeKitTests
//

import Foundation
@testable import ClaudeKit

/// Shared fixtures.
///
/// The positions are deliberately ordinary — the start position and the
/// position after 1.e4 e5 — because the verifier's job is mechanical and the
/// tests should fail for verification reasons, not because a fixture FEN was
/// mistyped.
enum Fixtures {

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let afterE4E5FEN = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

    // MARK: Moments

    /// Start position. PV 0 is `1.d4 d5 2.c4 e6`, PV 1 is what was played.
    static let momentOne = CoachRequest.Moment(
        momentID: "m1",
        ply: 0,
        fenBefore: startFEN,
        phase: .opening,
        playedSAN: "a4",
        playedUCI: "a2a4",
        bestSAN: "d4",
        bestUCI: "d2d4",
        deltaEP: 0.12,
        judgment: .inaccuracy,
        causeTag: "openingPrinciple",
        stepTag: "opening",
        modifiers: ["earlyFlankPawn"],
        thinkTimeMs: 2_400,
        criticalityGap: 0.05,
        engineLines: [
            CoachRequest.EngineLine(
                label: .best,
                evalCp: 25,
                pvSAN: ["d4", "d5", "c4", "e6"],
                pvUCI: ["d2d4", "d7d5", "c2c4", "e7e6"]
            ),
            CoachRequest.EngineLine(
                label: .played,
                evalCp: 0,
                pvSAN: ["a4", "d5", "d4"],
                pvUCI: ["a2a4", "d7d5", "d2d4"]
            )
        ]
    )

    /// Position after 1.e4 e5. PV 0 is `2.Nf3 Nc6 3.Bb5 a6`.
    static let momentTwo = CoachRequest.Moment(
        momentID: "m2",
        ply: 2,
        fenBefore: afterE4E5FEN,
        phase: .opening,
        playedSAN: "Qh5",
        playedUCI: "d1h5",
        bestSAN: "Nf3",
        bestUCI: "g1f3",
        deltaEP: 0.31,
        judgment: .mistake,
        causeTag: "openingPrinciple",
        stepTag: "opening",
        modifiers: [],
        thinkTimeMs: 900,
        criticalityGap: 0.11,
        engineLines: [
            CoachRequest.EngineLine(
                label: .best,
                evalCp: 30,
                pvSAN: ["Nf3", "Nc6", "Bb5", "a6"],
                pvUCI: ["g1f3", "b8c6", "f1b5", "a7a6"]
            ),
            CoachRequest.EngineLine(
                label: .alt,
                evalCp: 20,
                pvSAN: ["Bc4", "Nf6"],
                pvUCI: ["f1c4", "g8f6"]
            )
        ]
    )

    // MARK: Request

    static let profile = CoachRequest.Profile(
        ratingEstimate: 1_180,
        ratingUncertainty: 85,
        rung: .init(id: "rung2", title: "Tactical Vision"),
        weeklyFocus: .init(
            habitID: "checkOpponentThreats",
            stepTag: "threats",
            microGoal: .init(metricID: "ignoredStandingThreatRate", target: 0.2, current: 0.44)
        ),
        leakTop3: [
            .init(causeTag: "ignoredStandingThreat", epLostPerGame: 0.31, trend: .flat),
            .init(causeTag: "hungMovedPiece", epLostPerGame: 0.22, trend: .improving),
            .init(causeTag: "openingPrinciple", epLostPerGame: 0.10, trend: .worsening)
        ]
    )

    static let game = CoachRequest.Game(
        result: .loss,
        userColor: .white,
        accuracyUser: 78.4,
        accuracyOpponent: 84.1,
        timeControl: "10+0",
        moveCount: 41,
        opening: "Queen's Pawn Game",
        phaseAccuracy: .init(opening: 81, middlegame: 74, endgame: 80)
    )

    static func request(moments: [CoachRequest.Moment] = [momentOne, momentTwo]) -> CoachRequest {
        CoachRequest(profile: profile, game: game, moments: moments)
    }

    // MARK: Responses

    /// A note that passes every check for `m1`.
    static let validNoteOne = CoachResponse.MomentNote(
        momentID: "m1",
        question: "Which of your pieces is still sitting at home, and does this move help any of them get out?",
        explanation: "A flank pawn move does not develop anything. The engine takes the centre first and brings pieces out behind it.",
        keyLine: .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "d4", uci: "d2d4", plyFromRoot: 0),
                .init(san: "d5", uci: "d7d5", plyFromRoot: 1),
                .init(san: "c4", uci: "c2c4", plyFromRoot: 2)
            ]
        ),
        alternativeLine: nil,
        causeAffirmed: true,
        suggestedTag: nil
    )

    /// A note that passes every check for `m2`.
    static let validNoteTwo = CoachResponse.MomentNote(
        momentID: "m2",
        question: "Before bringing your queen out this early, what will their pieces do to her while they develop?",
        explanation: "The queen sortie invites development with tempo. Developing a knight first keeps every option open.",
        keyLine: .init(
            sourcePVIndex: 0,
            moves: [
                .init(san: "Nf3", uci: "g1f3", plyFromRoot: 0),
                .init(san: "Nc6", uci: "b8c6", plyFromRoot: 1)
            ]
        ),
        alternativeLine: nil,
        causeAffirmed: true,
        suggestedTag: nil
    )

    static func response(
        notes: [CoachResponse.MomentNote] = [validNoteOne, validNoteTwo],
        headline: String = "You gave the centre away early",
        habitID: String = "followOpeningPrinciples"
    ) -> CoachResponse {
        CoachResponse(
            gameNote: .init(
                headline: headline,
                body: "Two of the three moments came from the same place: pieces left at home while the centre changed hands. Fix the order and the middlegames get easier.",
                tone: .direct
            ),
            momentNotes: notes,
            weeklyFocusSuggestion: .init(
                habitID: habitID,
                rationale: "Development order is costing you more than anything tactical right now."
            ),
            flags: .init(disagreesWithCauseTag: [])
        )
    }

    /// The JSON body of a successful, non-streaming Messages response whose
    /// single text block is `text`.
    static func messageJSON(text: String, stopReason: String = "end_turn") -> String {
        // Built through JSONValue rather than string interpolation so a payload
        // containing quotes or newlines is escaped correctly.
        let value: JSONValue = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "claude-opus-5",
            "content": [["type": "text", "text": .string(text)]],
            "stop_reason": .string(stopReason),
            "usage": [
                "input_tokens": 1_200,
                "output_tokens": 300,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 980
            ]
        ]

        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    /// The same, carrying an encoded `CoachResponse`.
    static func messageJSON(coachResponse: CoachResponse) -> String {
        let encoder = JSONEncoder()
        let data = try! encoder.encode(coachResponse)
        return messageJSON(text: String(decoding: data, as: UTF8.self))
    }

    static func messageJSON(weeklyFocus: WeeklyFocusResponse) -> String {
        let data = try! JSONEncoder().encode(weeklyFocus)
        return messageJSON(text: String(decoding: data, as: UTF8.self))
    }

}
