//
//  MessageResponse.swift
//  ClaudeKit
//

import Foundation

/// A non-streaming `POST /v1/messages` response, and the `message` payload of
/// a `message_start` streaming event.
public struct MessageResponse: Codable, Sendable, Equatable {

    public var id: String
    public var type: String
    public var role: String
    public var model: String
    public var content: [ContentBlock]
    public var stopReason: StopReason?
    public var stopDetails: StopDetails?
    public var usage: Usage

    public init(
        id: String,
        type: String = "message",
        role: String = "assistant",
        model: String,
        content: [ContentBlock],
        stopReason: StopReason? = nil,
        stopDetails: StopDetails? = nil,
        usage: Usage = Usage()
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopDetails = stopDetails
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case model
        case content
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
        case usage
    }

    /// All `text` blocks concatenated — the shape structured outputs arrive in.
    public var text: String {
        content.compactMap(\.text).joined()
    }

}

// MARK: - Stop reason

/// Why generation stopped.
///
/// Modelled as a `RawRepresentable` struct rather than an enum so a stop reason
/// the API adds tomorrow decodes into `.init(rawValue:)` instead of throwing
/// and discarding a response we already paid for.
public struct StopReason: RawRepresentable, Codable, Sendable, Hashable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let endTurn = StopReason(rawValue: "end_turn")
    public static let maxTokens = StopReason(rawValue: "max_tokens")
    public static let stopSequence = StopReason(rawValue: "stop_sequence")
    public static let toolUse = StopReason(rawValue: "tool_use")
    public static let pauseTurn = StopReason(rawValue: "pause_turn")
    /// The model declined. Never surfaced to the student as coaching.
    public static let refusal = StopReason(rawValue: "refusal")
    public static let modelContextWindowExceeded = StopReason(rawValue: "model_context_window_exceeded")

}

/// `stop_details` — a structured companion to `stop_reason`.
public struct StopDetails: Codable, Sendable, Equatable {
    public var type: String

    public init(type: String) {
        self.type = type
    }
}

// MARK: - Usage

public struct Usage: Codable, Sendable, Equatable {

    public var inputTokens: Int
    public var outputTokens: Int

    /// Tokens written *into* the cache on this call (billed at a premium).
    public var cacheCreationInputTokens: Int?

    /// Tokens served *from* the cache (billed at a discount). The coaching
    /// system prompt should land here on every call after the first.
    public var cacheReadInputTokens: Int?

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `message_delta` carries only output_tokens; treat the rest as zero.
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
        cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

}

// MARK: - API error payload

/// The `{"type": "error", "error": {...}}` body the API returns on failure and
/// emits as an SSE `error` event mid-stream.
public struct APIErrorPayload: Codable, Sendable, Equatable {

    public struct Detail: Codable, Sendable, Equatable {
        public var type: String
        public var message: String

        public init(type: String, message: String) {
            self.type = type
            self.message = message
        }
    }

    public var type: String
    public var error: Detail

    public init(type: String = "error", error: Detail) {
        self.type = type
        self.error = error
    }

}
