//
//  HTTPTransport.swift
//  ClaudeKit
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The seam that keeps every test in this package hermetic.
///
/// `URLProtocol` stubbing would also work but leaks global state across
/// concurrent tests; a protocol the client holds by value does not.
public protocol HTTPTransport: Sendable {

    /// One-shot request/response.
    func send(_ request: URLRequest) async throws -> HTTPResult

    /// Streaming request. The response head is available before the body, so
    /// status-code errors can be surfaced without draining the stream first.
    func stream(_ request: URLRequest) async throws -> HTTPStreamResult

}

/// A completed HTTP response.
public struct HTTPResult: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// A streaming HTTP response: head first, body as it arrives.
public struct HTTPStreamResult: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, any Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

// MARK: - URLSession

/// The production transport.
public struct URLSessionTransport: HTTPTransport {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.transportFailure(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.transportFailure("Response was not HTTP")
        }

        return HTTPResult(statusCode: http.statusCode, headers: http.stringHeaders, body: data)
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResult {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ClaudeError.transportFailure(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.transportFailure("Response was not HTTP")
        }

        // Bytes are regrouped into lines before they leave the transport: one
        // `AsyncThrowingStream` element per byte would mean an awaited
        // continuation resume per byte, and the SSE parser re-buffers anyway.
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                var chunk = Data()
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ClaudeError.transportFailure(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return HTTPStreamResult(statusCode: http.statusCode, headers: http.stringHeaders, body: body)
    }

}

private extension HTTPURLResponse {

    var stringHeaders: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields {
            guard let key = key as? String else { continue }
            result[key] = String(describing: value)
        }
        return result
    }

}
