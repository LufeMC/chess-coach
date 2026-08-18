import Foundation

enum PrepError: Error, CustomStringConvertible {
    case zstdNotFound
    case zstdFailed(Int32)
    case missingColumn(String)
    case emptyInput
    case sqlite(String)
    case inputMissing(String)

    var description: String {
        switch self {
        case .zstdNotFound:
            return "Could not find a `zstd` executable. Install it (brew install zstd) or put it on PATH."
        case .zstdFailed(let code):
            return "zstd exited with status \(code) — the dump may be truncated or corrupt."
        case .missingColumn(let name):
            return "Input CSV has no `\(name)` column in its header row."
        case .emptyInput:
            return "Input CSV was empty (no header row)."
        case .sqlite(let msg):
            return "SQLite error: \(msg)"
        case .inputMissing(let path):
            return "Input dump not found at \(path)"
        }
    }
}

// MARK: - Streaming zstd decompression

/// Streams a `.zst` file line by line by piping it through `zstd -dc`.
///
/// WHY SHELL OUT INSTEAD OF LINKING A DECODER: the Lichess dump is a
/// *multi-frame* pzstd archive. Naive single-frame decoders stop after the
/// first frame and silently yield a truncated file — you get a plausible
/// looking few hundred thousand puzzles and no error. The `zstd` CLI handles
/// frame concatenation correctly, so it is the reference implementation here.
///
/// WHY STREAM AT ALL: the dump is ~1.1 GB uncompressed. Reading it into memory
/// (or staging it in a temp file) is pure waste when every row is touched
/// exactly once per pass.
struct ZstdLineStream {
    let executable: URL
    let input: URL

    /// Locates a usable `zstd`, preferring PATH but falling back to the usual
    /// Homebrew/miniforge locations so the tool works in a bare `swift run`
    /// environment where PATH may be minimal.
    static func locateZstd() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/zstd" }
        }
        candidates += [
            "/opt/homebrew/bin/zstd",
            "/opt/homebrew/Caskroom/miniforge/base/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    /// Feeds each line (newline stripped) to `body` as a raw byte buffer.
    ///
    /// The buffer is only valid for the duration of the call — callers copy out
    /// what they need. Handing out a pointer rather than a `String` is what
    /// keeps the hot loop allocation-free for the ~64% of rows that fail the
    /// quality filter and are never materialised.
    func forEachLine(_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-dc", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr is inherited so a corrupt-archive complaint from zstd reaches
        // the operator instead of vanishing.
        try process.run()

        let handle = pipe.fileHandleForReading
        // Partial line carried across chunk boundaries.
        var carry: [UInt8] = []
        carry.reserveCapacity(1024)

        // WHY THE AUTORELEASE POOL: `FileHandle.read(upToCount:)` hands back an
        // autoreleased NSData-backed `Data`. With no pool inside this loop the
        // chunks are not freed when `chunk` goes out of scope — they pile up
        // until the enclosing function returns, so a "streaming" read still
        // ends up holding all 1.1 GB resident (measured: 2.4 GB peak across the
        // two passes before this was added, ~120 MB after). Draining the pool
        // once per chunk is what makes the streaming real rather than nominal.
        var reachedEOF = false
        while !reachedEOF {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    reachedEOF = true
                    return
                }
                try chunk.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    var lineStart = 0
                    var i = 0
                    let n = bytes.count
                    while i < n {
                        if bytes[i] == 0x0A { // '\n'
                            var end = i
                            if end > lineStart && bytes[end - 1] == 0x0D { end -= 1 } // CRLF
                            if carry.isEmpty {
                                try body(UnsafeBufferPointer(rebasing: bytes[lineStart..<end]))
                            } else {
                                carry.append(contentsOf: bytes[lineStart..<end])
                                try carry.withUnsafeBufferPointer(body)
                                carry.removeAll(keepingCapacity: true)
                            }
                            lineStart = i + 1
                        }
                        i += 1
                    }
                    if lineStart < n {
                        carry.append(contentsOf: bytes[lineStart..<n])
                    }
                }
            }
        }
        // Final line if the file does not end with a newline.
        if !carry.isEmpty {
            var end = carry.count
            if end > 0 && carry[end - 1] == 0x0D { end -= 1 }
            try carry[0..<end].withUnsafeBufferPointer(body)
        }

        process.waitUntilExit()
        try handle.close()
        if process.terminationStatus != 0 {
            throw PrepError.zstdFailed(process.terminationStatus)
        }
    }
}

// MARK: - CSV field splitting

/// Reusable scratch space for one parsed line. Held across the whole pass so
/// the parser allocates nothing per row.
struct CSVFields {
    private(set) var starts: [Int]
    private(set) var ends: [Int]
    private(set) var quoted: [Bool]
    private(set) var count: Int = 0

    static let maxFields = 32

    init() {
        starts = [Int](repeating: 0, count: Self.maxFields)
        ends = [Int](repeating: 0, count: Self.maxFields)
        quoted = [Bool](repeating: false, count: Self.maxFields)
    }

    mutating func reset() { count = 0 }

    mutating func append(start: Int, end: Int, quoted isQuoted: Bool) {
        guard count < Self.maxFields else { return }
        starts[count] = start
        ends[count] = end
        quoted[count] = isQuoted
        count += 1
    }
}

/// Splits one CSV line into field ranges.
///
/// The Lichess dump is in practice never quoted (verified: all 6.1M rows split
/// on bare commas into exactly 11 fields), but RFC 4180 quoting is handled
/// anyway — an `OpeningTags` value containing a comma in some future dump would
/// otherwise shift every column silently.
func splitCSVLine(_ b: UnsafeBufferPointer<UInt8>, into f: inout CSVFields) {
    f.reset()
    let n = b.count
    var i = 0
    while true {
        var start = i
        var end: Int
        var isQuoted = false
        if i < n && b[i] == 0x22 { // opening '"'
            isQuoted = true
            i += 1
            start = i
            while i < n {
                if b[i] == 0x22 {
                    if i + 1 < n && b[i + 1] == 0x22 { i += 2; continue } // escaped ""
                    break
                }
                i += 1
            }
            end = i
            if i < n && b[i] == 0x22 { i += 1 } // closing quote
            while i < n && b[i] != 0x2C { i += 1 } // tolerate junk before the comma
        } else {
            while i < n && b[i] != 0x2C { i += 1 }
            end = i
        }
        f.append(start: start, end: end, quoted: isQuoted)
        if i < n && b[i] == 0x2C {
            i += 1
            continue
        }
        break
    }
}

@inline(__always)
func parseInt(_ b: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> Int? {
    guard s < e else { return nil }
    var i = s
    var negative = false
    if b[i] == 0x2D { negative = true; i += 1 }
    guard i < e else { return nil }
    var v = 0
    while i < e {
        let c = b[i]
        guard c >= 0x30, c <= 0x39 else { return nil }
        v = v * 10 + Int(c - 0x30)
        i += 1
    }
    return negative ? -v : v
}

@inline(__always)
func makeString(_ b: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, quoted: Bool) -> String {
    guard s < e else { return "" }
    if !quoted {
        return String(decoding: UnsafeBufferPointer(rebasing: b[s..<e]), as: UTF8.self)
    }
    var out = [UInt8]()
    out.reserveCapacity(e - s)
    var i = s
    while i < e {
        if b[i] == 0x22, i + 1 < e, b[i + 1] == 0x22 {
            out.append(0x22)
            i += 2
        } else {
            out.append(b[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Calls `body` with the byte range of each space-separated token.
@inline(__always)
func forEachToken(
    _ b: UnsafeBufferPointer<UInt8>,
    _ s: Int,
    _ e: Int,
    _ body: (Int, Int) -> Void
) {
    var i = s
    while i < e {
        while i < e && b[i] == 0x20 { i += 1 }
        guard i < e else { break }
        let start = i
        while i < e && b[i] != 0x20 { i += 1 }
        body(start, i)
    }
}
