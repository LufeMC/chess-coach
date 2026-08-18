//
//  ErrorMappingTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

@Suite("Error mapping and retries")
struct ErrorMappingTests {

    private static let errorBody = #"{"type":"error","error":{"type":"invalid_request_error","message":"bad thing"}}"#

    private func send(status: Int, headers: [String: String] = [:]) async throws -> MessageResponse {
        let transport = MockTransport(onSend: { _ in
            .json(Self.errorBody, statusCode: status, headers: headers)
        })
        let client = makeClient(transport: transport, retry: .init(maxAttempts: 1))
        return try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))
    }

    @Test("Status codes map to typed errors", arguments: [
        (401, "unauthorized"),
        (403, "permissionDenied"),
        (404, "notFound"),
        (413, "requestTooLarge"),
        (429, "rateLimited"),
        (500, "serverError"),
        (503, "serverError"),
        (418, "httpError")
    ])
    func statusMapping(status: Int, expected: String) async throws {
        do {
            _ = try await send(status: status)
            Issue.record("expected an error for status \(status)")
        } catch let error as ClaudeError {
            let name: String
            switch error {
            case .unauthorized: name = "unauthorized"
            case .permissionDenied: name = "permissionDenied"
            case .notFound: name = "notFound"
            case .requestTooLarge: name = "requestTooLarge"
            case .rateLimited: name = "rateLimited"
            case .serverError: name = "serverError"
            case .httpError: name = "httpError"
            default: name = "other"
            }
            #expect(name == expected)

            // The API's own message survives, so the UI can show something
            // more specific than "request failed".
            #expect(error.errorDescription?.contains("bad thing") == true)
        }
    }

    @Test("429 surfaces retry-after")
    func retryAfterSurfaced() async throws {
        do {
            _ = try await send(status: 429, headers: ["Retry-After": "12"])
            Issue.record("expected a rate limit error")
        } catch let error as ClaudeError {
            #expect(error.retryAfter == 12)
            #expect(error.isRetryable)
        }
    }

    @Test("A 500 is retried with backoff and eventually succeeds")
    func retriesServerErrors() async throws {
        let attempts = RequestRecorder()
        let sleeps = SleepRecorder()

        let transport = MockTransport(onSend: { request in
            await attempts.record(request)
            let count = await attempts.count
            return count < 3
                ? .json(Self.errorBody, statusCode: 500)
                : .json(Fixtures.messageJSON(text: "ok"))
        })

        let client = makeClient(
            transport: transport,
            sleep: sleeps.hook,
            retry: .init(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.1)
        )

        let response = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))

        #expect(response.text == "ok")
        #expect(await attempts.count == 3)
        #expect(await sleeps.count == 2)
    }

    @Test("A 429 waits at least as long as retry-after suggests")
    func backoffHonoursRetryAfter() async throws {
        let attempts = RequestRecorder()
        let sleeps = SleepRecorder()

        let transport = MockTransport(onSend: { request in
            await attempts.record(request)
            let count = await attempts.count
            return count == 1
                ? .json(Self.errorBody, statusCode: 429, headers: ["retry-after": "4"])
                : .json(Fixtures.messageJSON(text: "ok"))
        })

        let client = makeClient(
            transport: transport,
            sleep: sleeps.hook,
            retry: .init(maxAttempts: 3, baseDelay: 0.01, maxDelay: 60, jitter: 0.3)
        )

        _ = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))

        let delays = await sleeps.delays
        #expect(delays.count == 1)
        // Jittered around 4s rather than the 0.01s base delay.
        #expect(delays[0] > 2.5)
        #expect(delays[0] < 5.5)
    }

    @Test("A 400 is never retried")
    func doesNotRetryClientErrors() async throws {
        let attempts = RequestRecorder()
        let sleeps = SleepRecorder()

        let transport = MockTransport(onSend: { request in
            await attempts.record(request)
            return .json(Self.errorBody, statusCode: 400)
        })

        let client = makeClient(transport: transport, sleep: sleeps.hook, retry: .init(maxAttempts: 4))

        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))
        }

        #expect(await attempts.count == 1)
        #expect(await sleeps.count == 0)
    }

    @Test("Retries stop after maxAttempts and rethrow the last error")
    func retriesAreBounded() async throws {
        let attempts = RequestRecorder()

        let transport = MockTransport(onSend: { request in
            await attempts.record(request)
            return .json(Self.errorBody, statusCode: 503)
        })

        let client = makeClient(transport: transport, retry: .init(maxAttempts: 2, baseDelay: 0.001, maxDelay: 0.002))

        await #expect(throws: ClaudeError.self) {
            _ = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))
        }

        #expect(await attempts.count == 2)
    }

    @Test("A refusal is an error, not content")
    func refusalIsAnError() async throws {
        let transport = MockTransport(onSend: { _ in
            .json(Fixtures.messageJSON(text: "I can't help with that.", stopReason: "refusal"))
        })
        let client = makeClient(transport: transport)

        do {
            _ = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))
            Issue.record("expected a refusal error")
        } catch let error as ClaudeError {
            guard case let .refusal(response) = error else {
                Issue.record("expected .refusal, got \(error)")
                return
            }
            #expect(response?.stopReason == .refusal)
            #expect(!error.isRetryable)
        }
    }

    @Test("A body that isn't a message is a decoding failure")
    func decodingFailure() async throws {
        let transport = MockTransport(onSend: { _ in .json(#"{"unexpected": true}"#) })
        let client = makeClient(transport: transport)

        do {
            _ = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))
            Issue.record("expected a decoding failure")
        } catch let error as ClaudeError {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
            #expect(!error.isRetryable)
        }
    }

    @Test("Usage decodes cache accounting")
    func usageDecoding() async throws {
        let transport = MockTransport(onSend: { _ in .json(Fixtures.messageJSON(text: "ok")) })
        let client = makeClient(transport: transport)

        let response = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))

        #expect(response.usage.inputTokens == 1200)
        #expect(response.usage.cacheReadInputTokens == 980)
        #expect(response.usage.cacheCreationInputTokens == 0)
    }

    @Test("An unknown stop reason decodes rather than throwing")
    func unknownStopReason() async throws {
        let transport = MockTransport(onSend: { _ in
            .json(Fixtures.messageJSON(text: "ok", stopReason: "some_future_reason"))
        })
        let client = makeClient(transport: transport)

        let response = try await client.send(MessageRequest(model: "m", maxTokens: 8, messages: []))
        #expect(response.stopReason == StopReason(rawValue: "some_future_reason"))
    }

}
