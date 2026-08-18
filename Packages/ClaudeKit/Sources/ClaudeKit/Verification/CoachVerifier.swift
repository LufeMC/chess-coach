//
//  CoachVerifier.swift
//  ClaudeKit
//

import ChessKit
import Foundation

/// Checks a model response against the request that produced it.
///
/// This type is the only thing standing between the model and a student being
/// told a variation that does not exist. Structured outputs constrain the
/// shape; the system prompt asks for the rest; neither *guarantees* anything.
/// So every claim the model makes about chess is re-derived here from data the
/// app already trusts — the engine's PVs and a real board — and anything that
/// doesn't reconcile is thrown away rather than shown.
///
/// Checks run in a fixed order (shape, lines, questions, vocabulary and
/// limits), and all violations are collected rather than short-circuited: the
/// repair attempt is far more likely to succeed if the model is told everything
/// that was wrong at once.
public struct CoachVerifier: Sendable {

    private let allowedHabitIDs: Set<String>
    private let allowedCauseTags: Set<String>

    public init(
        allowedHabitIDs: Set<String> = CoachingVocabulary.habitIDs,
        allowedCauseTags: Set<String> = Set(CoachingVocabulary.causeTags)
    ) {
        self.allowedHabitIDs = allowedHabitIDs
        self.allowedCauseTags = allowedCauseTags
    }

    public func verify(response: CoachResponse, against request: CoachRequest) -> VerificationResult {
        var violations: [Violation] = []

        // 1. Shape. momentID matching lives here rather than at the end because
        //    steps 2 and 3 cannot run without resolving a note to its moment.
        violations += verifyShape(response: response, request: request)

        let knownIDs = Set(request.moments.map(\.momentID))

        for (index, note) in response.momentNotes.enumerated() {
            guard knownIDs.contains(note.momentID), let moment = request.moment(id: note.momentID) else {
                continue  // already reported in step 1; nothing to verify against
            }

            // 2. Quoted lines must be root-anchored prefixes of a provided PV,
            //    with SAN re-derived on a board.
            violations += verify(
                line: note.keyLine,
                label: "keyLine",
                path: "momentNotes[\(index)].keyLine",
                moment: moment
            )

            if let alternative = note.alternativeLine {
                violations += verify(
                    line: alternative,
                    label: "alternativeLine",
                    path: "momentNotes[\(index)].alternativeLine",
                    moment: moment
                )
            }

            // 3. The Socratic question must not name a move.
            violations += verifyQuestion(note.question, path: "momentNotes[\(index)].question", moment: moment)
        }

        // 4. Vocabulary and character limits.
        violations += verifyVocabulary(response: response)
        violations += verifyLimits(response: response)

        return .from(violations)
    }

    // MARK: - 1. Shape

    private func verifyShape(response: CoachResponse, request: CoachRequest) -> [Violation] {
        var violations: [Violation] = []

        let requestIDs = request.moments.map(\.momentID)
        let known = Set(requestIDs)
        var seen: Set<String> = []

        for (index, note) in response.momentNotes.enumerated() {
            let path = "momentNotes[\(index)]"

            if !known.contains(note.momentID) {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).momentID",
                    kind: .shape,
                    message: "\"\(note.momentID)\" is not one of the moments in the request (\(requestIDs.joined(separator: ", ")))"
                ))
            } else if !seen.insert(note.momentID).inserted {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).momentID",
                    kind: .shape,
                    message: "moment \(note.momentID) was annotated more than once; exactly one note per moment is expected"
                ))
            }

            if note.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).question",
                    kind: .shape,
                    message: "question is empty"
                ))
            }

            if note.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).explanation",
                    kind: .shape,
                    message: "explanation is empty"
                ))
            }

            if note.keyLine.moves.isEmpty {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).keyLine.moves",
                    kind: .shape,
                    message: "keyLine has no moves; a note must show at least one move from a provided line"
                ))
            }

            if let alternative = note.alternativeLine, alternative.moves.isEmpty {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).alternativeLine.moves",
                    kind: .shape,
                    message: "alternativeLine is present but has no moves; omit it instead"
                ))
            }

            // Disagreeing with the tag is allowed and useful; disagreeing
            // without saying what the tag should be is not actionable.
            if !note.causeAffirmed, (note.suggestedTag ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "\(path).suggestedTag",
                    kind: .shape,
                    message: "causeAffirmed is false but no suggestedTag was given"
                ))
            }
        }

        for id in requestIDs where !seen.contains(id) {
            violations.append(Violation(
                momentID: id,
                field: "momentNotes",
                kind: .shape,
                message: "no note was returned for moment \(id)"
            ))
        }

        if response.gameNote.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(momentID: nil, field: "gameNote.headline", kind: .shape, message: "headline is empty"))
        }

        if response.gameNote.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(Violation(momentID: nil, field: "gameNote.body", kind: .shape, message: "body is empty"))
        }

        return violations
    }

    // MARK: - 2. Lines

    /// Verifies one quoted line against the PV it claims to come from.
    ///
    /// Two independent checks, because each catches a different lie:
    ///
    /// - **UCI prefix**: `moves[i].uci` must equal `pvUCI[i]`, for every `i`
    ///   from 0. Root-anchored, no gaps, no reordering, no continuing past the
    ///   end. This is what makes "copied from the engine" a checkable claim
    ///   rather than a stylistic request.
    /// - **SAN re-derivation**: replaying those UCI moves from `fenBefore`
    ///   yields the canonical SAN for each, which must match what the model
    ///   wrote. A correct UCI with a fabricated SAN reads to the student as a
    ///   completely different move, and the prefix check alone would pass it.
    private func verify(
        line: CoachResponse.Line,
        label: String,
        path: String,
        moment: CoachRequest.Moment
    ) -> [Violation] {
        var violations: [Violation] = []
        let id = moment.momentID

        guard moment.engineLines.indices.contains(line.sourcePVIndex) else {
            let available = moment.engineLines.isEmpty
                ? "the moment provides no engine lines"
                : "valid indices are 0...\(moment.engineLines.count - 1)"
            return [Violation(
                momentID: id,
                field: "\(path).sourcePVIndex",
                kind: .pvIndexOutOfRange,
                message: "\(label) for \(id) names sourcePVIndex \(line.sourcePVIndex) but \(available)"
            )]
        }

        let pv = moment.engineLines[line.sourcePVIndex]

        guard var replay = MoveReplay(fen: moment.fenBefore) else {
            return [Violation(
                momentID: id,
                field: "\(path)",
                kind: .unverifiablePosition,
                message: "\(label) for \(id) cannot be verified: fenBefore (\(moment.fenBefore)) is not a valid position"
            )]
        }

        for (index, move) in line.moves.enumerated() {
            let movePath = "\(path).moves[\(index)]"

            guard index < pv.pvUCI.count else {
                violations.append(Violation(
                    momentID: id,
                    field: movePath,
                    kind: .lineTooLong,
                    message: "\(label) for \(id) runs past the end of PV \(line.sourcePVIndex): the line has \(line.moves.count) moves but the PV has \(pv.pvUCI.count)"
                ))
                break
            }

            let expectedUCI = pv.pvUCI[index]
            guard move.uci == expectedUCI else {
                violations.append(Violation(
                    momentID: id,
                    field: "\(movePath).uci",
                    kind: .lineDivergence,
                    message: "\(label) for \(id) diverges from PV \(line.sourcePVIndex) at ply \(index): model wrote \(move.uci), PV has \(expectedUCI)"
                ))
                // Everything after a divergence is measured from a position
                // that never occurred, so reporting it would be noise.
                break
            }

            if move.plyFromRoot != index {
                violations.append(Violation(
                    momentID: id,
                    field: "\(movePath).plyFromRoot",
                    kind: .plyIndexMismatch,
                    message: "\(label) for \(id) declares plyFromRoot \(move.plyFromRoot) for the move at position \(index); lines start at 0 and count up without gaps"
                ))
            }

            switch replay.apply(uci: move.uci) {
            case let .success(canonicalSAN):
                // The engine's own SAN is accepted alongside the replayed one:
                // both are trusted sources, and a disagreement between our SAN
                // renderer and the engine's is our problem, not a hallucination.
                let engineSAN = index < pv.pvSAN.count ? pv.pvSAN[index] : nil
                let written = normalize(move.san)

                if written != normalize(canonicalSAN), written != engineSAN.map(normalize) {
                    violations.append(Violation(
                        momentID: id,
                        field: "\(movePath).san",
                        kind: .sanMismatch,
                        message: "\(label) for \(id) has the wrong SAN at ply \(index): \(move.uci) is \(canonicalSAN) in this position, model wrote \(move.san)"
                    ))
                }

            case let .failure(failure):
                violations.append(Violation(
                    momentID: id,
                    field: "\(movePath).uci",
                    kind: .illegalMove,
                    message: "\(label) for \(id) cannot be replayed at ply \(index): \(move.uci) \(describe(failure))"
                ))
                // The board is now out of sync with the line; stop here.
                return violations
            }
        }

        return violations
    }

    private func describe(_ failure: MoveReplay.ReplayFailure) -> String {
        switch failure {
        case .malformedUCI: return "is not a well-formed UCI move"
        case .illegal: return "is not legal in the position reached at this point"
        case .missingPromotionPiece: return "reaches the back rank without naming a promotion piece"
        }
    }

    /// Strips notation that carries no information about *which* move it is.
    ///
    /// `!`/`?` annotations are commentary. Everything else — the piece letter,
    /// the disambiguator, the capture `x`, the check suffix — is left alone,
    /// because each of those changes what the student thinks the move was.
    private func normalize(_ san: String) -> String {
        var result = san.trimmingCharacters(in: .whitespaces)
        while let last = result.last, last == "!" || last == "?" {
            result.removeLast()
        }
        // Some sources write castling with zeroes.
        result = result.replacingOccurrences(of: "0-0-0", with: "O-O-O")
        result = result.replacingOccurrences(of: "0-0", with: "O-O")
        return result
    }

    // MARK: - 3. Questions

    private func verifyQuestion(_ question: String, path: String, moment: CoachRequest.Moment) -> [Violation] {
        let replay = MoveReplay(fen: moment.fenBefore)
        let matches = MoveNotationScanner.illegalToMention(in: question, replay: replay)

        guard !matches.isEmpty else { return [] }

        let listed = matches.map { "\"\($0.text)\"" }.joined(separator: ", ")
        return [Violation(
            momentID: moment.momentID,
            field: path,
            kind: .notationInQuestion,
            message: "question for \(moment.momentID) contains move notation (\(listed)); \(matches.count == 1 ? "it is a legal move" : "these are legal moves") in this position, and the question must not name the answer"
        )]
    }

    // MARK: - 4. Vocabulary and limits

    private func verifyVocabulary(response: CoachResponse) -> [Violation] {
        var violations: [Violation] = []

        let habitID = response.weeklyFocusSuggestion.habitID
        if !allowedHabitIDs.contains(habitID) {
            violations.append(Violation(
                momentID: nil,
                field: "weeklyFocusSuggestion.habitID",
                kind: .unknownVocabulary,
                message: "\"\(habitID)\" is not an allowed habit id (allowed: \(allowedHabitIDs.sorted().joined(separator: ", ")))"
            ))
        }

        for (index, note) in response.momentNotes.enumerated() {
            guard let tag = note.suggestedTag, !tag.isEmpty else { continue }
            if !allowedCauseTags.contains(tag) {
                violations.append(Violation(
                    momentID: note.momentID,
                    field: "momentNotes[\(index)].suggestedTag",
                    kind: .unknownVocabulary,
                    message: "\"\(tag)\" is not an allowed cause tag"
                ))
            }
        }

        for id in response.flags.disagreesWithCauseTag {
            let affirmed = response.momentNotes.first { $0.momentID == id }?.causeAffirmed
            if affirmed == true {
                violations.append(Violation(
                    momentID: id,
                    field: "flags.disagreesWithCauseTag",
                    kind: .shape,
                    message: "moment \(id) is flagged as disputed but its note sets causeAffirmed to true"
                ))
            }
        }

        return violations
    }

    private func verifyLimits(response: CoachResponse) -> [Violation] {
        var violations: [Violation] = []

        func check(_ text: String, limit: Int, field: String, momentID: String?) {
            guard text.count > limit else { return }
            violations.append(Violation(
                momentID: momentID,
                field: field,
                kind: .characterLimit,
                message: "\(field) is \(text.count) characters, limit is \(limit)"
            ))
        }

        check(response.gameNote.headline, limit: CoachResponse.Limits.headline, field: "gameNote.headline", momentID: nil)
        check(response.gameNote.body, limit: CoachResponse.Limits.body, field: "gameNote.body", momentID: nil)
        check(
            response.weeklyFocusSuggestion.rationale,
            limit: CoachResponse.Limits.rationale,
            field: "weeklyFocusSuggestion.rationale",
            momentID: nil
        )

        for (index, note) in response.momentNotes.enumerated() {
            check(
                note.question,
                limit: CoachResponse.Limits.question,
                field: "momentNotes[\(index)].question",
                momentID: note.momentID
            )
            check(
                note.explanation,
                limit: CoachResponse.Limits.explanation,
                field: "momentNotes[\(index)].explanation",
                momentID: note.momentID
            )
        }

        return violations
    }

}
