import Foundation

/// Parsers for the engine's stdout lines.
///
/// Kept as pure static functions so they can be unit-tested against captured
/// engine output without booting Stockfish.
public enum UCIParser {

    /// Parses an `info ...` line. Returns nil for lines without a score and PV
    /// (e.g. `info depth 1 currmove e2e4`, `info string ...`), which carry no
    /// analysis value.
    public static func parseInfo(_ line: String) -> UCIInfo? {
        guard line.hasPrefix("info ") else { return nil }
        // "info string" lines are diagnostics, never analysis.
        guard !line.hasPrefix("info string") else { return nil }

        let tokens = line.split(separator: " ").map(String.init)
        var info = UCIInfo()
        var sawScore = false
        var index = 1

        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "depth":
                info.depth = intAt(tokens, index + 1) ?? info.depth
                index += 2
            case "seldepth":
                info.selDepth = intAt(tokens, index + 1) ?? info.selDepth
                index += 2
            case "multipv":
                info.multipv = intAt(tokens, index + 1) ?? info.multipv
                index += 2
            case "nodes":
                info.nodes = intAt(tokens, index + 1) ?? info.nodes
                index += 2
            case "nps":
                info.nps = intAt(tokens, index + 1) ?? info.nps
                index += 2
            case "time":
                info.timeMs = intAt(tokens, index + 1) ?? info.timeMs
                index += 2
            case "score":
                // "score cp 34" | "score mate -3", optionally followed by
                // "lowerbound"/"upperbound" which we deliberately ignore: a
                // bounded score is still the best information available at that
                // depth, and the final line for the depth supersedes it.
                if let kind = tokens[safe: index + 1], let value = intAt(tokens, index + 2) {
                    info.score = (kind == "mate") ? .mate(value) : .centipawns(value)
                    sawScore = true
                }
                index += 3
            case "pv":
                // PV runs to end of line.
                info.pv = Array(tokens[(index + 1)...])
                index = tokens.count
            default:
                index += 1
            }
        }

        guard sawScore, !info.pv.isEmpty else { return nil }
        return info
    }

    /// Parses `bestmove e2e4 [ponder e7e5]`. Returns nil if the line isn't a bestmove.
    /// A `bestmove (none)` yields `(nil, nil)` — the position is terminal.
    public static func parseBestMove(_ line: String) -> (best: String?, ponder: String?)? {
        guard line.hasPrefix("bestmove") else { return nil }
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return (nil, nil) }
        let best = (tokens[1] == "(none)" || tokens[1] == "0000") ? nil : tokens[1]
        var ponder: String?
        if let idx = tokens.firstIndex(of: "ponder"), let value = tokens[safe: idx + 1], value != "(none)" {
            ponder = value
        }
        return (best, ponder)
    }

    /// Pulls nodes-per-second out of a `bench` summary line
    /// (`Nodes/second    : 1234567`).
    public static func parseBenchNPS(_ line: String) -> Int? {
        guard line.contains("Nodes/second") else { return nil }
        guard let colon = line.lastIndex(of: ":") else { return nil }
        return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func intAt(_ tokens: [String], _ index: Int) -> Int? {
        guard let token = tokens[safe: index] else { return nil }
        return Int(token)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
