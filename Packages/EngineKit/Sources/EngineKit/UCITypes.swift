import Foundation

/// An engine evaluation, always from the perspective of the side to move.
public enum UCIScore: Sendable, Equatable {
    case centipawns(Int)
    /// Moves (not plies) until mate. Negative means the side to move is getting mated.
    case mate(Int)

    /// Centipawns clamped into a finite range, with mates mapped to the extremes.
    /// Analysis math wants a single number; `mateEquivalent` keeps mate scores
    /// from dominating averages.
    public func centipawnValue(mateEquivalent: Int = 10_000) -> Int {
        switch self {
        case .centipawns(let cp): return cp
        case .mate(let moves): return moves >= 0 ? mateEquivalent : -mateEquivalent
        }
    }

    /// Flips perspective (used when converting between side-to-move and white-relative).
    public var negated: UCIScore {
        switch self {
        case .centipawns(let cp): return .centipawns(-cp)
        case .mate(let m): return .mate(-m)
        }
    }
}

/// One `info` line from the engine, keyed by its MultiPV rank.
public struct UCIInfo: Sendable, Equatable {
    public var multipv: Int
    public var depth: Int
    public var selDepth: Int
    public var score: UCIScore
    public var nodes: Int
    public var nps: Int
    public var timeMs: Int
    /// Principal variation in UCI long algebraic notation ("e2e4").
    public var pv: [String]

    public init(
        multipv: Int = 1,
        depth: Int = 0,
        selDepth: Int = 0,
        score: UCIScore = .centipawns(0),
        nodes: Int = 0,
        nps: Int = 0,
        timeMs: Int = 0,
        pv: [String] = []
    ) {
        self.multipv = multipv
        self.depth = depth
        self.selDepth = selDepth
        self.score = score
        self.nodes = nodes
        self.nps = nps
        self.timeMs = timeMs
        self.pv = pv
    }

    public var bestMove: String? { pv.first }
}

/// The outcome of one `go` command.
public struct SearchResult: Sendable, Equatable {
    /// Best move in UCI notation, or nil if the engine reported `bestmove (none)`
    /// (checkmate or stalemate on the board).
    public var bestMove: String?
    public var ponderMove: String?
    /// Deepest info line per MultiPV rank, ordered rank 1 first.
    public var lines: [UCIInfo]

    public init(bestMove: String?, ponderMove: String? = nil, lines: [UCIInfo] = []) {
        self.bestMove = bestMove
        self.ponderMove = ponderMove
        self.lines = lines
    }

    /// The engine's preferred line (MultiPV rank 1).
    public var principal: UCIInfo? { lines.first { $0.multipv == 1 } ?? lines.first }

    /// The line ranked `rank` (1-based), if the search produced one.
    public func line(rank: Int) -> UCIInfo? { lines.first { $0.multipv == rank } }
}

/// How long the engine should search.
public enum SearchLimit: Sendable, Equatable {
    case nodes(Int)
    case depth(Int)
    case movetime(Int)
    /// Real clock control, used for sparring so the engine paces itself.
    case clock(whiteMs: Int, blackMs: Int, whiteIncMs: Int, blackIncMs: Int)
    case infinite

    var command: String {
        switch self {
        case .nodes(let n): return "go nodes \(n)"
        case .depth(let d): return "go depth \(d)"
        case .movetime(let ms): return "go movetime \(ms)"
        case .clock(let wtime, let btime, let winc, let binc):
            return "go wtime \(wtime) btime \(btime) winc \(winc) binc \(binc)"
        case .infinite: return "go infinite"
        }
    }
}

/// The position to search from.
public enum EnginePosition: Sendable, Equatable {
    case startPosition(moves: [String])
    case fen(String, moves: [String])

    var command: String {
        switch self {
        case .startPosition(let moves):
            return moves.isEmpty ? "position startpos" : "position startpos moves \(moves.joined(separator: " "))"
        case .fen(let fen, let moves):
            return moves.isEmpty ? "position fen \(fen)" : "position fen \(fen) moves \(moves.joined(separator: " "))"
        }
    }
}

/// Engine options this app actually sets. Raw values are the UCI option names.
public enum UCIOption: String, Sendable {
    case threads = "Threads"
    case hash = "Hash"
    case multiPV = "MultiPV"
    case evalFile = "EvalFile"
    case evalFileSmall = "EvalFileSmall"
    case uciShowWDL = "UCI_ShowWDL"
    case ponder = "Ponder"
}

public enum EngineError: Error, Sendable {
    case notStarted
    case searchAlreadyRunning
    case handshakeTimeout
    case missingNetwork(String)
}
