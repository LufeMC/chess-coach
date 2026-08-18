//
//  MockTransport.swift
//  ClaudeKitTests
//

import Foundation
@testable import ClaudeKit

/// A transport driven by closures. Nothing in this test target touches the
/// network.
struct MockTransport: HTTPTransport {

    var onSend: @Sendable (URLRequest) async throws -> HTTPResult = { _ in
        HTTPResult(statusCode: 200, body: Data())
    }

    var onStream: @Sendable (URLRequest) async throws -> HTTPStreamResult = { _ in
        HTTPStreamResult(statusCode: 200, body: AsyncThrowingStream { $0.finish() })
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        try await onSend(request)
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResult {
        try await onStream(request)
    }

}

/// Thread-safe capture of what the client actually sent, and how often.
actor RequestRecorder {

    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    var count: Int { requests.count }

    var bodies: [Data] {
        requests.compactMap(\.httpBody)
    }

    func decodedBody(at index: Int) throws -> JSONValue {
        guard requests.indices.contains(index), let body = requests[index].httpBody else {
            throw MockError.noBody
        }
        return try JSONDecoder().decode(JSONValue.self, from: body)
    }

    enum MockError: Error {
        case noBody
    }

}

/// Records sleeps instead of performing them, so backoff is testable without
/// spending wall-clock time on it.
actor SleepRecorder {

    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }

    var count: Int { delays.count }

    nonisolated var hook: @Sendable (TimeInterval) async throws -> Void {
        { [self] delay in await record(delay) }
    }

}

extension HTTPStreamResult {

    /// Builds a streaming response from literal chunks, which is how the
    /// mid-frame split cases are expressed.
    static func chunks(
        _ chunks: [String],
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPStreamResult {
        HTTPStreamResult(
            statusCode: statusCode,
            headers: headers,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(Data(chunk.utf8))
                }
                continuation.finish()
            }
        )
    }

}

extension HTTPResult {

    static func json(_ string: String, statusCode: Int = 200, headers: [String: String] = [:]) -> HTTPResult {
        HTTPResult(statusCode: statusCode, headers: headers, body: Data(string.utf8))
    }

}

/// A client wired to a mock transport, with sleeping stubbed out.
func makeClient(
    transport: MockTransport,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    retry: ClaudeClient.RetryPolicy = ClaudeClient.RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.05),
    apiKey: String = "sk-ant-test-key"
) -> ClaudeClient {
    ClaudeClient(
        keyProvider: StaticAPIKey(apiKey),
        transport: transport,
        configuration: ClaudeClient.Configuration(retry: retry, sleep: sleep)
    )
}
