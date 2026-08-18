//
//  SSEParser.swift
//  ClaudeKit
//

import Foundation

/// One raw server-sent event: the `event:` name (if any) and the joined
/// `data:` payload.
struct SSEFrame: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Incremental server-sent-events parser.
///
/// The transport hands us whatever bytes arrived, which is not the same shape
/// as what the server sent: a single `content_block_delta` can be split across
/// three TCP reads, and two events can arrive in one. So the parser buffers
/// until a line is complete, accumulates fields, and only emits a frame at the
/// blank line that terminates it (the `\n\n` delimiter). Anything short of that
/// stays in the buffer.
struct SSEParser: Sendable {

    private var buffer = Data()
    private var pendingEvent: String?
    private var pendingData: [String] = []
    private var hasPendingFields = false

    init() {}

    /// Feeds a chunk and returns every complete frame it produced.
    mutating func consume(_ chunk: Data) -> [SSEFrame] {
        buffer.append(chunk)

        var frames: [SSEFrame] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)

            // A multi-byte UTF-8 scalar never contains 0x0A, so a complete line
            // is always complete UTF-8 — decoding here cannot split a scalar.
            var line = String(decoding: lineBytes, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }

            if line.isEmpty {
                if let frame = takePendingFrame() {
                    frames.append(frame)
                }
            } else {
                accumulate(line: line)
            }
        }

        return frames
    }

    /// Flushes at end of stream.
    ///
    /// Only emits a frame whose last line was newline-terminated: a dangling
    /// partial line means the connection died mid-frame and the payload cannot
    /// be trusted, so it is discarded and the caller reports truncation.
    mutating func finish() -> [SSEFrame] {
        guard buffer.isEmpty, let frame = takePendingFrame() else { return [] }
        return [frame]
    }

    /// True when bytes are still buffered — i.e. the stream ended mid-line.
    var hasBufferedBytes: Bool { !buffer.isEmpty }

    // MARK: Private

    private mutating func accumulate(line: String) {
        // Lines starting with ':' are comments/heartbeats in the SSE spec.
        guard !line.hasPrefix(":") else { return }

        let field: String
        var value: String

        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            // A single leading space after the colon is part of the framing.
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            pendingEvent = value
            hasPendingFields = true
        case "data":
            pendingData.append(value)
            hasPendingFields = true
        default:
            // `id:` and `retry:` are irrelevant here; ignore unknown fields
            // rather than failing the stream over them.
            break
        }
    }

    private mutating func takePendingFrame() -> SSEFrame? {
        guard hasPendingFields else { return nil }

        let frame = SSEFrame(event: pendingEvent, data: pendingData.joined(separator: "\n"))
        pendingEvent = nil
        pendingData = []
        hasPendingFields = false
        return frame
    }

}
