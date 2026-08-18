//
//  FallbackRenderer.swift
//  ClaudeKit
//

import Foundation

/// Builds a coaching note from engine data alone.
///
/// Used when the model has failed verification twice for a moment. The note it
/// produces is duller than a good model note and better than a wrong one: the
/// question comes from a hand-written bank keyed by cause tag, and the line is
/// copied straight out of the engine's PV, so a templated note is verifiable by
/// construction — it cannot contain a move the engine didn't produce, because
/// every move in it *is* the engine's.
public struct FallbackRenderer: Sendable {

    /// How many plies of the best PV a templated explanation shows.
    public static let previewPlies = 6

    /// One Socratic question per cause tag.
    ///
    /// Each is written to be answerable from the position, in words only — no
    /// notation, no square names that could parse as a move — because these
    /// questions go through exactly the same verification as the model's.
    public static let questionBank: [String: String] = [
        "hungMovedPiece":
            "Before you let go of that piece, what would be attacking it on the square you picked?",
        "hungLeftPiece":
            "Which of your pieces was being defended by the piece you just moved away?",
        "missedNewThreat":
            "Their last move changed something — what does it attack now that it did not attack a moment ago?",
        "ignoredStandingThreat":
            "You already knew about their threat; did the move you chose actually deal with it, or only ignore it politely?",
        "allowedShallowTactic":
            "If you play this, what is their most forcing reply — every check and every capture, not just the natural-looking move?",
        "allowedDeepTactic":
            "After the obvious recapture, does your position still hold, or does a second forcing move arrive right behind it?",
        "miscalculatedTactic":
            "At the end of the line you calculated, whose pieces are still hanging?",
        "missedForcingIdea":
            "Before settling on a quiet move, which checks and captures did you look at?",
        "forcingBias":
            "You went for the forcing move; what would you have played if none of the checks and captures worked?",
        "miscountedExchange":
            "How many defenders does that square really have, and in what order do they arrive?",
        "planlessTrade":
            "What does this trade improve for you — and what does it improve for them?",
        "kingExposure":
            "After this pawn move, which squares around your own king is nothing covering any more?",
        "endgameTechnique":
            "What is the winning method in this endgame, and what is the very first step of it?",
        "openingPrinciple":
            "Which of your pieces is still sitting on its starting square, and does this move help it get out?",
        "positionalDrift":
            "Which of your pieces is doing the least work right now, and how would you give it something to do?"
    ]

    /// Used when the cause tag isn't in the bank — a new detector shipping
    /// ahead of its question shouldn't leave the student with nothing.
    public static let defaultQuestion =
        "What did you want this move to achieve, and what did it allow in return?"

    private let questions: [String: String]

    public init(questions: [String: String] = FallbackRenderer.questionBank) {
        self.questions = questions
    }

    /// The canned question for a cause tag.
    public func question(forCauseTag causeTag: String) -> String {
        questions[causeTag] ?? Self.defaultQuestion
    }

    /// A templated note for one moment.
    ///
    /// Returns `nil` only when the moment has no engine line to quote — with
    /// nothing verifiable to show, silence beats a note with an empty line.
    public func note(for moment: CoachRequest.Moment) -> CoachResponse.MomentNote? {
        guard let index = moment.bestLineIndex else { return nil }

        let line = moment.engineLines[index]
        let plies = min(Self.previewPlies, min(line.pvSAN.count, line.pvUCI.count))
        guard plies > 0 else { return nil }

        let moves = (0..<plies).map { ply in
            CoachResponse.MoveRef(san: line.pvSAN[ply], uci: line.pvUCI[ply], plyFromRoot: ply)
        }

        let preview = line.pvSAN.prefix(plies).joined(separator: " ")
        let explanation = truncate(
            "The engine preferred \(moment.bestSAN): \(preview)",
            to: CoachResponse.Limits.explanation
        )

        return CoachResponse.MomentNote(
            momentID: moment.momentID,
            question: truncate(question(forCauseTag: moment.causeTag), to: CoachResponse.Limits.question),
            explanation: explanation,
            keyLine: CoachResponse.Line(sourcePVIndex: index, moves: moves),
            alternativeLine: nil,
            // The template neither affirms nor disputes the app's own tag; it
            // was produced without a second opinion, so it defers to it.
            causeAffirmed: true,
            suggestedTag: nil
        )
    }

    /// A whole templated response, for when nothing usable came back at all.
    public func response(for request: CoachRequest) -> CoachResponse {
        let notes = request.moments.compactMap { note(for: $0) }

        return CoachResponse(
            gameNote: CoachResponse.GameNote(
                headline: truncate(headline(for: request.game), to: CoachResponse.Limits.headline),
                body: truncate(body(for: request), to: CoachResponse.Limits.body),
                tone: request.game.result == .win ? .direct : .encouraging
            ),
            momentNotes: notes,
            weeklyFocusSuggestion: CoachResponse.WeeklyFocusSuggestion(
                habitID: fallbackHabitID(for: request),
                rationale: truncate(
                    "Keeping this week's focus: the micro-goal for \(request.profile.weeklyFocus.microGoal.metricID) is not met yet.",
                    to: CoachResponse.Limits.rationale
                )
            ),
            flags: CoachResponse.Flags()
        )
    }

    /// The habit to fall back to: the student's current one if it is still
    /// valid, otherwise whichever habit answers their biggest leak.
    public func fallbackHabitID(for request: CoachRequest) -> String {
        let current = request.profile.weeklyFocus.habitID
        if CoachingVocabulary.habitIDs.contains(current) { return current }

        if let leak = request.profile.leakTop3.first,
           let habit = CoachingVocabulary.habit(forCauseTag: leak.causeTag) {
            return habit.id
        }

        return CoachingVocabulary.habits[0].id
    }

    // MARK: Private

    private func headline(for game: CoachRequest.Game) -> String {
        switch game.result {
        case .win: return "You won — here is where it was closest"
        case .loss: return "Three moments decided this one"
        case .draw: return "A draw, and where the chances were"
        }
    }

    private func body(for request: CoachRequest) -> String {
        let accuracy = String(format: "%.0f%%", request.game.accuracyUser)

        return """
            You played at \(accuracy) accuracy over \(request.game.moveCount) moves. \
            Work through the moments below on the board: for each one, answer the question \
            before you play through the engine's line.
            """
    }

    /// Truncates on a word boundary so a clipped sentence still reads.
    private func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }

        let clipped = String(text.prefix(limit - 1))
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: space, to: clipped.endIndex) < 16 {
            return String(clipped[clipped.startIndex..<space]) + "…"
        }
        return clipped + "…"
    }

}
