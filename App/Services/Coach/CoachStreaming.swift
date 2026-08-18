//
//  CoachStreaming.swift
//  ChessCoach
//

import ClaudeKit
import Foundation

// MARK: - Progressive text

/// Coaching text for one moment, as far as it has arrived.
struct MomentTextFragment: Sendable, Hashable, Identifiable {
    var momentID: String
    var question: String
    var explanation: String
    /// The explanation's closing quote has arrived, so this text is final.
    var isComplete: Bool

    var id: String { momentID }
}

/// Extracts per-moment coaching text out of a partially-received JSON response.
///
/// ## Why this exists
///
/// `ClaudeKit.CoachService` is not streaming — and it should not be, because it
/// owns verification, the repair attempt and the fallback, none of which can run
/// on half a response. But a coaching pass is thousands of tokens, and showing
/// the student a spinner for fifteen seconds when the first note was ready in
/// three is a worse product for no reason.
///
/// So the coordinator streams at the `ClaudeClient` level and feeds the raw
/// deltas through this scanner, which reads whatever complete-or-partial string
/// values it can find and publishes them for the UI to render *provisionally*.
/// The authoritative text is still whatever `CoachService` returns after
/// verification: a note the verifier rejects is replaced, and the UI swaps the
/// provisional text for the final text when the call completes.
///
/// ## How it reads half a JSON document
///
/// It does not parse JSON. It scans for the schema's key names in order
/// (`momentID`, then `question`, then `explanation`, which is the order
/// `CoachSchema` declares them and therefore the order they are generated in)
/// and reads each following string literal, tolerating one that has not been
/// closed yet. Anything it cannot make sense of is simply not emitted — a
/// scanner that guesses would put words in the coach's mouth.
struct PartialCoachTextScanner: Sendable {

    private var buffer = ""

    init() {}

    /// Appends a text delta and returns the fragments known so far.
    mutating func consume(_ delta: String) -> [MomentTextFragment] {
        buffer += delta
        return fragments()
    }

    /// The fragments in the buffer, in the order they appear.
    func fragments() -> [MomentTextFragment] {
        let characters = Array(buffer)
        var result: [MomentTextFragment] = []
        var index = 0

        while let idStart = Self.find(key: "momentID", in: characters, from: index) {
            guard let id = Self.readString(in: characters, from: idStart) else { break }

            // The next moment's id bounds this one's fields, so a `question`
            // belonging to note 2 can never be attached to note 1.
            let nextID = Self.find(key: "momentID", in: characters, from: id.end) ?? characters.count
            let question = Self.find(key: "question", in: characters, from: id.end, before: nextID)
                .flatMap { Self.readString(in: characters, from: $0) }
            let explanation = Self.find(key: "explanation", in: characters, from: id.end, before: nextID)
                .flatMap { Self.readString(in: characters, from: $0) }

            result.append(
                MomentTextFragment(
                    momentID: id.value,
                    question: question?.value ?? "",
                    explanation: explanation?.value ?? "",
                    isComplete: explanation?.isTerminated ?? false
                )
            )
            index = id.end
        }
        return result
    }

    // MARK: Scanning

    /// Index just past the `:` following `"<key>"`, or `nil`.
    private static func find(
        key: String,
        in characters: [Character],
        from start: Int,
        before limit: Int? = nil
    ) -> Int? {
        let needle = Array("\"\(key)\"")
        let end = min(limit ?? characters.count, characters.count)
        guard start < end else { return nil }

        var index = start
        while index + needle.count <= end {
            if Array(characters[index..<(index + needle.count)]) == needle {
                var cursor = index + needle.count
                while cursor < end, characters[cursor] == " " || characters[cursor] == "\n" { cursor += 1 }
                guard cursor < end, characters[cursor] == ":" else { return nil }
                cursor += 1
                while cursor < end, characters[cursor] == " " || characters[cursor] == "\n" { cursor += 1 }
                return cursor
            }
            index += 1
        }
        return nil
    }

    private struct ScannedString {
        var value: String
        /// The closing quote has arrived.
        var isTerminated: Bool
        /// Index just past the closing quote, or the end of the buffer.
        var end: Int
    }

    /// Reads a JSON string literal starting at `start`, which may be truncated.
    private static func readString(in characters: [Character], from start: Int) -> ScannedString? {
        guard start < characters.count, characters[start] == "\"" else { return nil }

        var value = ""
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else {
                    // A dangling backslash is the start of an escape whose body
                    // has not arrived. Stop here rather than emitting it raw.
                    return ScannedString(value: value, isTerminated: false, end: characters.count)
                }
                let escaped = characters[index + 1]
                switch escaped {
                case "n": value += "\n"
                case "t": value += "\t"
                case "r": value += "\r"
                case "u":
                    // A \uXXXX escape needs four more characters; if they have
                    // not arrived, stop cleanly.
                    guard index + 5 < characters.count else {
                        return ScannedString(value: value, isTerminated: false, end: characters.count)
                    }
                    let hex = String(characters[(index + 2)...(index + 5)])
                    if let scalar = UInt32(hex, radix: 16).flatMap(UnicodeScalar.init) {
                        value.append(Character(scalar))
                    }
                    index += 6
                    continue
                default: value.append(escaped)
                }
                index += 2
                continue
            }
            if character == "\"" {
                return ScannedString(value: value, isTerminated: true, end: index + 1)
            }
            value.append(character)
            index += 1
        }
        return ScannedString(value: value, isTerminated: false, end: characters.count)
    }
}

// MARK: - Streaming relay

/// A `MessageSending` client that streams under the hood.
///
/// This is the seam that gets progressive text *without* giving up verification:
/// `CoachService` keeps calling `send(_:)` and keeps doing its retry, repair and
/// fallback on a complete response, while every text delta is published as it
/// arrives. One request, one bill, two consumers.
///
/// Falls back to a plain non-streaming send when streaming fails before any text
/// has been delivered — a stream that dies on connect is a transport problem,
/// and re-issuing it as a normal request costs one round trip and saves the
/// coaching pass.
struct StreamingMessageRelay: MessageSending {

    private let client: ClaudeClient
    private let onDelta: @Sendable (String) -> Void

    init(client: ClaudeClient, onDelta: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.onDelta = onDelta
    }

    func send(_ request: MessageRequest) async throws -> MessageResponse {
        var text = ""
        var stopReason: StopReason?
        var model = request.model
        var identifier = "streamed"
        var usage = Usage()

        do {
            for try await event in client.stream(request) {
                switch event {
                case let .messageStart(message):
                    identifier = message.id
                    model = message.model
                case let .contentBlockDelta(_, delta):
                    guard let chunk = delta.text else { continue }
                    text += chunk
                    onDelta(chunk)
                case let .messageDelta(reason, _, deltaUsage):
                    stopReason = reason
                    usage = deltaUsage
                default:
                    break
                }
            }
        } catch {
            // Nothing was delivered, so nothing is duplicated by starting over.
            guard text.isEmpty else { throw error }
            return try await client.send(request)
        }

        return MessageResponse(
            id: identifier,
            model: model,
            content: [.text(text)],
            stopReason: stopReason,
            usage: usage
        )
    }
}
