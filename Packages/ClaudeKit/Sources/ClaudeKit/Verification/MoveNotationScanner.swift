//
//  MoveNotationScanner.swift
//  ClaudeKit
//

import Foundation

/// Finds move notation hiding in prose.
///
/// Rule 1 of the coaching contract says a Socratic question must not name the
/// move. Enforcing that is a two-step test, and both steps matter:
///
/// 1. A SAN-shaped regex. Broad on purpose — it matches `Nf3`, `exd5`, `Qxh7+`,
///    `e8=Q`, `O-O-O` and also plenty of innocent text.
/// 2. Legality in the position. `Be` never matches, but `b4` matches the regex
///    inside an ordinary sentence about the b4 square, and "d4" is a perfectly
///    normal way to name a square in words. Requiring the match to also be a
///    legal move here is what keeps the check from firing on square names and
///    pawn-structure talk while still catching the thing we actually care
///    about: the model handing the student the answer.
///
/// The test is deliberately asymmetric. A missed detection costs one weak
/// question; a false positive throws away a good note and replaces it with a
/// template, so the legality gate errs toward letting prose through.
struct MoveNotationScanner {

    /// SAN-ish shapes, plus castling.
    static let sanPattern = #"\b([KQRBN]?[a-h]?[1-8]?x?[a-h][1-8](=[QRBN])?[+#]?|O-O(-O)?)\b"#

    /// UCI shapes (`g1f3`, `e7e8q`). Not in the brief's regex, but a question
    /// reading "why not g1f3" gives the answer away just as completely, and
    /// four-character square pairs do not occur in English.
    static let uciPattern = #"\b[a-h][1-8][a-h][1-8][qrbn]?\b"#

    /// A notation match with enough context to explain itself.
    struct Match: Equatable {
        var text: String
        var isLegalMove: Bool
        var style: Style

        enum Style: Equatable {
            case san
            case uci
        }
    }

    /// Every notation-shaped substring in `text`, flagged with whether it is
    /// also a legal move in `replay`'s position.
    static func matches(in text: String, replay: MoveReplay?) -> [Match] {
        var results: [Match] = []

        for (pattern, style) in [(sanPattern, Match.Style.san), (uciPattern, Match.Style.uci)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)

            for result in regex.matches(in: text, range: range) {
                guard let matchRange = Range(result.range, in: text) else { continue }
                let matched = String(text[matchRange])

                let isLegal: Bool
                switch style {
                case .san:
                    isLegal = replay?.isLegalSAN(matched) ?? false
                case .uci:
                    // A UCI-shaped token is checked by parsing it as a move on
                    // the board; if it isn't legal it's just four characters.
                    isLegal = replay.map { replayed in
                        var copy = replayed
                        if case .success = copy.apply(uci: matched) { return true }
                        return false
                    } ?? false
                }

                results.append(Match(text: matched, isLegalMove: isLegal, style: style))
            }
        }

        return results
    }

    /// The matches that are also legal moves — the ones that count as a
    /// violation.
    static func illegalToMention(in text: String, replay: MoveReplay?) -> [Match] {
        matches(in: text, replay: replay).filter(\.isLegalMove)
    }

}
