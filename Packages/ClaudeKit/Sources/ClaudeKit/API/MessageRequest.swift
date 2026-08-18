//
//  MessageRequest.swift
//  ClaudeKit
//

import Foundation

/// The body of `POST /v1/messages`.
public struct MessageRequest: Codable, Sendable, Equatable {

    /// Model id. Defaults come from ``ClaudeClient/Configuration``.
    public var model: String

    /// Hard cap on sampled tokens. Required by the API.
    public var maxTokens: Int

    /// System prompt, always as an array of blocks.
    ///
    /// The string form of `system` is accepted by the API but cannot carry a
    /// `cache_control` breakpoint, and the coaching contract is large and
    /// static — caching it is where nearly all of the cost saving lives.
    public var system: [SystemBlock]?

    public var messages: [Message]

    /// Structured outputs plus the effort knob.
    public var outputConfig: OutputConfig?

    public var stream: Bool?

    public var temperature: Double?

    public var stopSequences: [String]?

    public init(
        model: String,
        maxTokens: Int,
        system: [SystemBlock]? = nil,
        messages: [Message],
        outputConfig: OutputConfig? = nil,
        stream: Bool? = nil,
        temperature: Double? = nil,
        stopSequences: [String]? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.outputConfig = outputConfig
        self.stream = stream
        self.temperature = temperature
        self.stopSequences = stopSequences
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case outputConfig = "output_config"
        case stream
        case temperature
        case stopSequences = "stop_sequences"
    }

}

// MARK: - System blocks

public extension MessageRequest {

    /// One system-prompt text block, optionally carrying a cache breakpoint.
    struct SystemBlock: Codable, Sendable, Equatable {
        public var type: String
        public var text: String
        public var cacheControl: CacheControl?

        public init(text: String, cacheControl: CacheControl? = nil) {
            self.type = "text"
            self.text = text
            self.cacheControl = cacheControl
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case cacheControl = "cache_control"
        }
    }

    /// A prompt-cache breakpoint. Everything *up to and including* the block
    /// carrying it becomes the cached prefix, which is why the breakpoint goes
    /// on the last system block rather than the first.
    struct CacheControl: Codable, Sendable, Equatable {
        public var type: String

        public init(type: String = "ephemeral") {
            self.type = type
        }

        public static let ephemeral = CacheControl()
    }

}

// MARK: - Messages

public extension MessageRequest {

    struct Message: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable {
            case user
            case assistant
        }

        public var role: Role
        public var content: [ContentBlock]

        public init(role: Role, content: [ContentBlock]) {
            self.role = role
            self.content = content
        }

        /// Convenience for the common single-text-block case.
        public init(role: Role, text: String) {
            self.init(role: role, content: [.text(text)])
        }
    }

}

// MARK: - Output configuration

public extension MessageRequest {

    /// `output_config` — structured outputs and reasoning effort.
    struct OutputConfig: Codable, Sendable, Equatable {
        public var format: OutputFormat?

        /// How much thinking the model spends before answering. Routine move
        /// annotations run at `.medium`; the weekly-focus call is cheap enough
        /// to justify `.high`.
        public var effort: Effort?

        public init(format: OutputFormat? = nil, effort: Effort? = nil) {
            self.format = format
            self.effort = effort
        }
    }

    enum Effort: String, Codable, Sendable, CaseIterable {
        case low
        case medium
        case high
    }

    /// `output_config.format`. Only the JSON-schema form is modelled; that is
    /// the only one the coaching contract uses.
    struct OutputFormat: Codable, Sendable, Equatable {
        public var type: String
        public var schema: JSONValue

        public init(jsonSchema: JSONValue) {
            self.type = "json_schema"
            self.schema = jsonSchema
        }
    }

}

// MARK: - Content blocks

/// A content block in either direction.
///
/// `other` is a deliberate escape hatch: the API adds block types (thinking,
/// server tool results, …) faster than this package needs them, and a decoding
/// failure on an unknown block would take down an otherwise fine response.
public enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case other(type: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        if type == "text" {
            self = .text(try container.decode(String.self, forKey: .text))
        } else {
            self = .other(type: type, payload: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .text(text):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .other(_, payload):
            try payload.encode(to: encoder)
        }
    }

    /// The text of a `text` block, `nil` for anything else.
    public var text: String? {
        if case let .text(text) = self { return text }
        return nil
    }
}
