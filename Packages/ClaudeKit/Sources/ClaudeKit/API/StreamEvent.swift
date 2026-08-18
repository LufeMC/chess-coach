//
//  StreamEvent.swift
//  ClaudeKit
//

import Foundation

/// One decoded server-sent event from a streaming `/v1/messages` call.
public enum StreamEvent: Sendable, Equatable {

    /// Opening event: the message shell, with usage already populated for the
    /// input side (including cache hits).
    case messageStart(MessageResponse)

    case contentBlockStart(index: Int, block: ContentBlock)
    case contentBlockDelta(index: Int, delta: ContentDelta)
    case contentBlockStop(index: Int)

    /// Carries the final `stop_reason`/`stop_details` and the output token count.
    case messageDelta(stopReason: StopReason?, stopDetails: StopDetails?, usage: Usage)

    case messageStop

    /// Keep-alive. Yielded rather than swallowed so callers can reset an
    /// idle timer on it.
    case ping

    /// A mid-stream error. ``ClaudeClient/stream(_:)`` turns this into a thrown
    /// ``ClaudeError``; the case exists so SSE decoding stays total.
    case error(APIErrorPayload)

    /// An event type this package doesn't model yet.
    case unknown(type: String, payload: JSONValue)

}

/// The delta payload of a `content_block_delta` event.
public enum ContentDelta: Sendable, Equatable {
    case text(String)
    case other(type: String, payload: JSONValue)

    /// The appended text of a `text_delta`, `nil` for anything else.
    public var text: String? {
        if case let .text(text) = self { return text }
        return nil
    }
}

// MARK: - Decoding

extension StreamEvent {

    /// Decodes one SSE frame.
    ///
    /// The `data:` payload carries its own `type` field, so the `event:` line is
    /// only a fallback — the API is consistent about both, but the data field is
    /// the authoritative one.
    static func decode(frame: SSEFrame, decoder: JSONDecoder) throws -> StreamEvent {
        guard let data = frame.data.data(using: .utf8) else {
            throw ClaudeError.decodingFailed("SSE frame data was not valid UTF-8")
        }

        let value: JSONValue
        do {
            value = try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw ClaudeError.decodingFailed("SSE frame was not valid JSON: \(error)")
        }

        let type = value["type"]?.stringValue ?? frame.event ?? ""

        do {
            switch type {
            case "message_start":
                guard let message = value["message"] else {
                    throw ClaudeError.decodingFailed("message_start without a message")
                }
                return .messageStart(try decoder.decode(MessageResponse.self, from: try encode(message)))

            case "content_block_start":
                guard let index = value["index"]?.intValue, let block = value["content_block"] else {
                    throw ClaudeError.decodingFailed("content_block_start missing index or content_block")
                }
                return .contentBlockStart(index: index, block: try decoder.decode(ContentBlock.self, from: try encode(block)))

            case "content_block_delta":
                guard let index = value["index"]?.intValue, let delta = value["delta"] else {
                    throw ClaudeError.decodingFailed("content_block_delta missing index or delta")
                }
                let deltaType = delta["type"]?.stringValue ?? ""
                if deltaType == "text_delta", let text = delta["text"]?.stringValue {
                    return .contentBlockDelta(index: index, delta: .text(text))
                }
                return .contentBlockDelta(index: index, delta: .other(type: deltaType, payload: delta))

            case "content_block_stop":
                guard let index = value["index"]?.intValue else {
                    throw ClaudeError.decodingFailed("content_block_stop missing index")
                }
                return .contentBlockStop(index: index)

            case "message_delta":
                let delta = value["delta"]
                let stopReason = delta?["stop_reason"]?.stringValue.map(StopReason.init(rawValue:))
                let stopDetails = delta?["stop_details"]?["type"]?.stringValue.map(StopDetails.init(type:))
                let usage: Usage
                if let rawUsage = value["usage"] {
                    usage = try decoder.decode(Usage.self, from: try encode(rawUsage))
                } else {
                    usage = Usage()
                }
                return .messageDelta(stopReason: stopReason, stopDetails: stopDetails, usage: usage)

            case "message_stop":
                return .messageStop

            case "ping":
                return .ping

            case "error":
                guard
                    let error = value["error"],
                    let errorType = error["type"]?.stringValue,
                    let message = error["message"]?.stringValue
                else {
                    throw ClaudeError.decodingFailed("error event without a well-formed error object")
                }
                return .error(APIErrorPayload(error: .init(type: errorType, message: message)))

            default:
                return .unknown(type: type, payload: value)
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw ClaudeError.decodingFailed("failed to decode \(type) event: \(error)")
        }
    }

    /// Re-encodes a sub-value so the strongly typed models can decode it.
    /// Cheap relative to the network call, and it keeps one decoding path.
    private static func encode(_ value: JSONValue) throws -> Data {
        try JSONEncoder().encode(value)
    }

}
