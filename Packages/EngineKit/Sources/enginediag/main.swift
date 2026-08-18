import EngineKit
import Foundation

// Minimal isolation harness for the UCI bridge. Run with SFBRIDGE_TRACE=1.
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let small = root.appending(path: "App/Resources/Networks/nn-37f18f62d772.nnue")
let big = root.appending(path: "App/Resources/Networks/nn-1c0000000000.nnue")

FileHandle.standardError.write("diag: root=\(root.path)\n".data(using: .utf8)!)
FileHandle.standardError.write("diag: small exists=\(FileManager.default.fileExists(atPath: small.path))\n".data(using: .utf8)!)

let engine = StockfishEngine.shared
try await engine.start(bigNet: big, smallNet: small)
FileHandle.standardError.write("diag: handshake OK\n".data(using: .utf8)!)

let result = try await engine.search(.startPosition(moves: []), limit: .nodes(100_000))
FileHandle.standardError.write("diag: bestmove=\(result.bestMove ?? "nil") lines=\(result.lines.count)\n".data(using: .utf8)!)

let nps = await engine.bench(depth: 8, threads: 1, hashMB: 16)
FileHandle.standardError.write("diag: BENCH_NPS=\(nps)\n".data(using: .utf8)!)
exit(0)
