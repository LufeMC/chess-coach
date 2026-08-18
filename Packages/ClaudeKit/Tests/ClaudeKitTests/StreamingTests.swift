//
//  StreamingTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

@Suite("SSE parsing")
struct SSEParsingTests {

    @Test("Complete frames decode in order")
    func completeFrames() throws {
        var parser = SSEParser()
        let frames = parser.consume(Data("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[],"usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":900}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}


            """.utf8))

        #expect(frames.count == 2)

        let decoder = JSONDecoder()
        let events = try frames.map { try StreamEvent.decode(frame: $0, decoder: decoder) }

        guard case let .messageStart(message) = events[0] else {
            Issue.record("expected message_start, got \(events[0])")
            return
        }
        #expect(message.id == "msg_1")
        #expect(message.usage.cacheReadInputTokens == 900)

        #expect(events[1] == .contentBlockDelta(index: 0, delta: .text("Hello")))
    }

    @Test("A frame split mid-JSON across chunks is buffered until complete")
    func splitFrames() throws {
        var parser = SSEParser()

        // Split inside the JSON payload, mid-token.
        #expect(parser.consume(Data("event: content_block_delta\ndata: {\"type\":\"content_bl".utf8)).isEmpty)
        #expect(parser.consume(Data("ock_delta\",\"index\":0,\"delta\":{\"type\":\"text_".utf8)).isEmpty)
        #expect(parser.consume(Data("delta\",\"text\":\"partial\"}}\n".utf8)).isEmpty)

        // Only the blank line completes the frame.
        let frames = parser.consume(Data("\n".utf8))
        #expect(frames.count == 1)

        let event = try StreamEvent.decode(frame: frames[0], decoder: JSONDecoder())
        #expect(event == .contentBlockDelta(index: 0, delta: .text("partial")))
    }

    @Test("A chunk carrying the tail of one frame and the head of another")
    func chunkStraddlingTwoFrames() throws {
        var parser = SSEParser()

        var frames = parser.consume(Data("event: ping\ndata: {\"type\":\"pin".utf8))
        #expect(frames.isEmpty)

        frames = parser.consume(Data("g\"}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        #expect(frames.count == 2)

        let decoder = JSONDecoder()
        #expect(try StreamEvent.decode(frame: frames[0], decoder: decoder) == .ping)
        #expect(try StreamEvent.decode(frame: frames[1], decoder: decoder) == .messageStop)
    }

    @Test("CRLF line endings and comment lines are tolerated")
    func crlfAndComments() throws {
        var parser = SSEParser()
        let frames = parser.consume(Data(": keep-alive\r\nevent: ping\r\ndata: {\"type\":\"ping\"}\r\n\r\n".utf8))

        #expect(frames.count == 1)
        #expect(try StreamEvent.decode(frame: frames[0], decoder: JSONDecoder()) == .ping)
    }

    @Test("Multi-line data fields are joined with newlines")
    func multiLineData() {
        var parser = SSEParser()
        let frames = parser.consume(Data("event: x\ndata: {\"a\":\ndata: 1}\n\n".utf8))

        #expect(frames == [SSEFrame(event: "x", data: "{\"a\":\n1}")])
    }

    @Test("A frame truncated mid-line is discarded, not guessed at")
    func truncatedFrameDiscarded() {
        var parser = SSEParser()
        _ = parser.consume(Data("event: message_stop\ndata: {\"type\":\"mess".utf8))

        #expect(parser.hasBufferedBytes)
        #expect(parser.finish().isEmpty)
    }

    @Test("message_delta carries stop reason, stop details and output usage")
    func messageDelta() throws {
        var parser = SSEParser()
        let frames = parser.consume(Data("""
            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_details":{"type":"max_tokens"}},"usage":{"output_tokens":412}}


            """.utf8))

        let event = try StreamEvent.decode(frame: frames[0], decoder: JSONDecoder())
        guard case let .messageDelta(stopReason, stopDetails, usage) = event else {
            Issue.record("expected message_delta, got \(event)")
            return
        }

        #expect(stopReason == .maxTokens)
        #expect(stopDetails?.type == "max_tokens")
        #expect(usage.outputTokens == 412)
    }

}

@Suite("Client streaming")
struct ClientStreamingTests {

    private static let messageStart = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[],"usage":{"input_tokens":10,"output_tokens":1}}}


        """

    @Test("A well-formed stream yields every event including pings")
    func fullStream() async throws {
        let transport = MockTransport(onStream: { _ in
            .chunks([
                Self.messageStart,
                "event: ping\ndata: {\"type\":\"ping\"}\n\n",
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"He\"}}\n\n",
                // Split mid-frame, with a ping interleaved after it.
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,",
                "\"delta\":{\"type\":\"text_delta\",\"text\":\"llo\"}}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\n",
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n",
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            ])
        })

        let client = makeClient(transport: transport)
        var events: [StreamEvent] = []
        for try await event in client.stream(request()) {
            events.append(event)
        }

        #expect(events.count == 9)
        #expect(events.filter { $0 == .ping }.count == 2)

        let text = events.compactMap { event -> String? in
            guard case let .contentBlockDelta(_, delta) = event else { return nil }
            return delta.text
        }.joined()
        #expect(text == "Hello")
        #expect(events.last == .messageStop)
    }

    @Test("An error event ends the stream with a typed error")
    func errorEvent() async throws {
        let transport = MockTransport(onStream: { _ in
            .chunks([
                Self.messageStart,
                "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"
            ])
        })

        let client = makeClient(transport: transport)

        await #expect(throws: ClaudeError.streamError(.init(error: .init(type: "overloaded_error", message: "Overloaded")))) {
            for try await _ in client.stream(request()) {}
        }
    }

    @Test("A stream that ends before message_stop is reported as truncated")
    func truncatedStream() async throws {
        let transport = MockTransport(onStream: { _ in
            .chunks([
                Self.messageStart,
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"half a sen"
            ])
        })

        let client = makeClient(transport: transport)

        await #expect(throws: ClaudeError.streamTruncated) {
            for try await _ in client.stream(request()) {}
        }
    }

    @Test("A non-2xx status on a stream maps to the same typed errors")
    func streamHTTPError() async throws {
        let transport = MockTransport(onStream: { _ in
            HTTPStreamResult(
                statusCode: 429,
                headers: ["retry-after": "7"],
                body: AsyncThrowingStream { continuation in
                    continuation.yield(Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8))
                    continuation.finish()
                }
            )
        })

        let client = makeClient(transport: transport)

        do {
            for try await _ in client.stream(request()) {}
            Issue.record("expected a rate limit error")
        } catch let error as ClaudeError {
            #expect(error.retryAfter == 7)
        }
    }

    @Test("Streaming requests set stream: true and ask for event-stream")
    func streamFlag() async throws {
        let recorder = RequestRecorder()
        let transport = MockTransport(onStream: { request in
            await recorder.record(request)
            return .chunks([Self.messageStart, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"])
        })

        let client = makeClient(transport: transport)
        for try await _ in client.stream(request()) {}

        let body = try await recorder.decodedBody(at: 0)
        #expect(body["stream"]?.boolValue == true)
        #expect(await recorder.requests[0].value(forHTTPHeaderField: "accept") == "text/event-stream")
    }

    private func request() -> MessageRequest {
        MessageRequest(
            model: "claude-opus-5",
            maxTokens: 256,
            messages: [.init(role: .user, text: "hi")]
        )
    }

}
