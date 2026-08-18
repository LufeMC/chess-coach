//
//  ClaudeClient.swift
//  ClaudeKit
//

import Foundation

/// Supplies the API key on demand.
///
/// The client asks for the key per request rather than holding it, so a key
/// rotated in settings takes effect immediately and no long-lived copy sits in
/// memory between calls.
public protocol APIKeyProviding: Sendable {
    func apiKey() async throws -> String
}

/// A key held in memory. Fine for previews and tests; the app uses
/// ``KeychainStore``.
public struct StaticAPIKey: APIKeyProviding {

    private let key: String

    public init(_ key: String) {
        self.key = key
    }

    public func apiKey() async throws -> String {
        guard !key.isEmpty else { throw ClaudeError.missingAPIKey }
        return key
    }

}

/// Anything that can answer a ``MessageRequest``.
///
/// ``CoachService`` depends on this rather than on ``ClaudeClient`` so the
/// coaching policy can be tested with canned model output and no transport
/// at all.
public protocol MessageSending: Sendable {
    func send(_ request: MessageRequest) async throws -> MessageResponse
}

/// The Anthropic Messages API client.
///
/// An `actor` because the retry policy is stateful in spirit (and because the
/// key provider may be, too); nothing here needs to run on the main actor.
public actor ClaudeClient {

    // MARK: Configuration

    public struct Configuration: Sendable {

        public var baseURL: URL
        public var apiVersion: String

        /// Default model for both the coaching and weekly-focus calls.
        public var defaultModel: String

        public var defaultMaxTokens: Int

        /// Default reasoning effort. `.medium` is the right price/quality point
        /// for routine per-game annotations; raise it for the weekly review.
        public var defaultEffort: MessageRequest.Effort

        public var retry: RetryPolicy

        /// Injected so backoff tests don't actually wait.
        public var sleep: @Sendable (TimeInterval) async throws -> Void

        public init(
            baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
            apiVersion: String = "2023-06-01",
            defaultModel: String = "claude-opus-5",
            defaultMaxTokens: Int = 4096,
            defaultEffort: MessageRequest.Effort = .medium,
            retry: RetryPolicy = RetryPolicy(),
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
        ) {
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.defaultModel = defaultModel
            self.defaultMaxTokens = defaultMaxTokens
            self.defaultEffort = defaultEffort
            self.retry = retry
            self.sleep = sleep
        }

    }

    /// Exponential backoff with full-width jitter on the last term.
    ///
    /// Jitter matters more than the base delay here: a batch of finished games
    /// syncing at once would otherwise retry in lockstep and re-hit the same
    /// rate limit.
    public struct RetryPolicy: Sendable, Equatable {

        /// Total attempts including the first. 1 disables retrying.
        public var maxAttempts: Int
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval
        /// Fraction of the computed delay that is randomised, 0...1.
        public var jitter: Double

        public init(
            maxAttempts: Int = 3,
            baseDelay: TimeInterval = 0.5,
            maxDelay: TimeInterval = 20,
            jitter: Double = 0.3
        ) {
            self.maxAttempts = maxAttempts
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.jitter = jitter
        }

        /// Delay before `attempt` (1-based: the delay after attempt 1 failed).
        func delay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
            // An explicit `retry-after` is the server telling us exactly when
            // the window reopens; honour it instead of guessing, but still
            // jitter so a fleet of clients doesn't stampede on the same second.
            let base = retryAfter ?? min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
            let capped = min(maxDelay, base)
            guard jitter > 0 else { return capped }
            let spread = capped * jitter
            return max(0, capped - spread + Double.random(in: 0...(2 * spread)))
        }

    }

    // MARK: Stored properties

    private let keyProvider: any APIKeyProviding
    private let transport: any HTTPTransport
    private let configuration: Configuration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        keyProvider: any APIKeyProviding,
        transport: any HTTPTransport = URLSessionTransport(),
        configuration: Configuration = Configuration()
    ) {
        self.keyProvider = keyProvider
        self.transport = transport
        self.configuration = configuration

        let encoder = JSONEncoder()
        // Deterministic bodies keep prompt-cache prefixes byte-identical across
        // runs; a reordered `system` block would be a cache miss.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// The defaults a caller should build requests from.
    public nonisolated func defaultRequest(
        system: [MessageRequest.SystemBlock],
        messages: [MessageRequest.Message],
        schema: JSONValue? = nil,
        effort: MessageRequest.Effort? = nil,
        maxTokens: Int? = nil
    ) -> MessageRequest {
        MessageRequest(
            model: configuration.defaultModel,
            maxTokens: maxTokens ?? configuration.defaultMaxTokens,
            system: system,
            messages: messages,
            outputConfig: MessageRequest.OutputConfig(
                format: schema.map { MessageRequest.OutputFormat(jsonSchema: $0) },
                effort: effort ?? configuration.defaultEffort
            )
        )
    }

    // MARK: Sending

    /// Sends a request, retrying 429s and 5xxs.
    public func send(_ request: MessageRequest) async throws -> MessageResponse {
        var body = request
        body.stream = nil

        var attempt = 1
        while true {
            do {
                return try await performSend(body)
            } catch let error as ClaudeError where error.isRetryable && attempt < configuration.retry.maxAttempts {
                let delay = configuration.retry.delay(forAttempt: attempt, retryAfter: error.retryAfter)
                try await configuration.sleep(delay)
                attempt += 1
            }
        }
    }

    private func performSend(_ request: MessageRequest) async throws -> MessageResponse {
        let urlRequest = try await makeURLRequest(for: request)
        let result = try await transport.send(urlRequest)

        guard (200..<300).contains(result.statusCode) else {
            throw ClaudeError.fromHTTP(status: result.statusCode, headers: result.headers, body: result.body)
        }

        let response: MessageResponse
        do {
            response = try decoder.decode(MessageResponse.self, from: result.body)
        } catch {
            throw ClaudeError.decodingFailed(String(describing: error))
        }

        // A refusal is a successful HTTP call with content that must never be
        // shown as coaching, so it leaves through the error path.
        if response.stopReason == .refusal {
            throw ClaudeError.refusal(response)
        }

        return response
    }

    // MARK: Streaming

    /// Streams a request as decoded events.
    ///
    /// The stream throws rather than yields on failure: an `error` event, a
    /// refusal, or a connection that ended without `message_stop` all mean the
    /// accumulated text is not a usable structured response.
    ///
    /// Streaming is not retried — by the time a stream fails, tokens have been
    /// delivered to the caller and silently starting over would duplicate them.
    public nonisolated func stream(_ request: MessageRequest) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        _ request: MessageRequest,
        into continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws {
        var body = request
        body.stream = true

        let urlRequest = try await makeURLRequest(for: body)
        let result = try await transport.stream(urlRequest)

        guard (200..<300).contains(result.statusCode) else {
            // Drain the body so the error payload can be decoded — the head
            // arrives before the body even on failures.
            var errorBody = Data()
            for try await chunk in result.body {
                errorBody.append(chunk)
            }
            throw ClaudeError.fromHTTP(status: result.statusCode, headers: result.headers, body: errorBody)
        }

        var parser = SSEParser()
        var sawMessageStop = false
        var stopReason: StopReason?

        for try await chunk in result.body {
            for frame in parser.consume(chunk) {
                let event = try StreamEvent.decode(frame: frame, decoder: decoder)

                switch event {
                case let .error(payload):
                    throw ClaudeError.streamError(payload)
                case let .messageDelta(reason, _, _):
                    stopReason = reason
                case .messageStop:
                    sawMessageStop = true
                default:
                    break
                }

                continuation.yield(event)
            }
        }

        for frame in parser.finish() {
            let event = try StreamEvent.decode(frame: frame, decoder: decoder)
            if case let .error(payload) = event { throw ClaudeError.streamError(payload) }
            if case .messageStop = event { sawMessageStop = true }
            continuation.yield(event)
        }

        guard sawMessageStop else {
            throw ClaudeError.streamTruncated
        }

        if stopReason == .refusal {
            throw ClaudeError.refusal(nil)
        }
    }

    /// Convenience: run a stream to completion and assemble the full text.
    public func streamedText(_ request: MessageRequest) async throws -> String {
        var text = ""
        for try await event in stream(request) {
            if case let .contentBlockDelta(_, delta) = event, let chunk = delta.text {
                text += chunk
            }
        }
        return text
    }

    // MARK: Request building

    private func makeURLRequest(for request: MessageRequest) async throws -> URLRequest {
        let key = try await keyProvider.apiKey()
        guard !key.isEmpty else { throw ClaudeError.missingAPIKey }

        var urlRequest = URLRequest(url: configuration.baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if request.stream == true {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        }

        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw ClaudeError.decodingFailed("Could not encode request: \(error)")
        }

        return urlRequest
    }

}

extension ClaudeClient: MessageSending {}
