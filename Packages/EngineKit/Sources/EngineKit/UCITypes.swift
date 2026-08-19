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
    /// Whether the search was cut short — a `stop` from a preempting client, or
    /// a cancelled task — so the scores reflect less depth than was asked for.
    ///
    /// The distinction is not cosmetic. A truncated evaluation looks exactly
    /// like a completed one, and the post-game pass checkpoints its evaluations
    /// as a resume prefix it never revisits: stored once, a shallow score fixes
    /// the wrong judgment of that one move in place for good.
    public var wasTruncated: Bool

    public init(
        bestMove: String?,
        ponderMove: String? = nil,
        lines: [UCIInfo] = [],
        wasTruncated: Bool = false
    ) {
        self.bestMove = bestMove
        self.ponderMove = ponderMove
        self.lines = lines
        self.wasTruncated = wasTruncated
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
    /// Search to `depth`, but give up after `milliseconds` whatever happens.
    ///
    /// For the sparring opponent, where the depth is the *point* — it is the
    /// model of how far ahead that rating calculates — but an unbounded depth
    /// search is still a game that can visibly hang. UCI honours both and stops
    /// at whichever arrives first, so the time is a backstop rather than a
    /// second budget: set it high enough that ordinary positions finish on
    /// depth, and the profile plays at exactly the strength it was measured at.
    case depthWithin(depth: Int, milliseconds: Int)
    /// Real clock control, used for sparring so the engine paces itself.
    case clock(whiteMs: Int, blackMs: Int, whiteIncMs: Int, blackIncMs: Int)
    case infinite

    var command: String {
        switch self {
        case .nodes(let n): return "go nodes \(n)"
        case .depth(let d): return "go depth \(d)"
        case .movetime(let ms): return "go movetime \(ms)"
        case .depthWithin(let depth, let ms): return "go depth \(depth) movetime \(ms)"
        case .clock(let wtime, let btime, let winc, let binc):
            return "go wtime \(wtime) btime \(btime) winc \(winc) binc \(binc)"
        case .infinite: return "go infinite"
        }
    }

    /// How long the engine may stay silent before the wait is treated as a dead
    /// engine rather than a slow one.
    ///
    /// Derived from the limit because the limit is the only honest bound
    /// available: a clock search cannot legitimately outlast the clock it was
    /// handed, and an infinite search is stopped by whoever started it, so
    /// putting a deadline on one would kill a search that is behaving exactly as
    /// asked.
    var silenceBudget: Duration? {
        // Slack on top of the engine's own budget: it still has to unwind the
        // search tree and print a `bestmove` after the clock says stop.
        let slack = Duration.seconds(15)
        switch self {
        case .infinite: return nil
        case .nodes, .depth: return .seconds(120)
        case .movetime(let ms): return .milliseconds(ms) + slack
        case .depthWithin(_, let ms): return .milliseconds(ms) + slack
        case .clock(let whiteMs, let blackMs, _, _): return .milliseconds(max(whiteMs, blackMs)) + slack
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
    /// Switches on Stockfish's own strength limiter.
    ///
    /// The app never sets this — `Humanizer` exists precisely because a
    /// weakened Stockfish plays engine chess with noise stirred in. It is here
    /// for `HumanizerAnchoring`, which uses the limiter as an *external ruler*
    /// rather than as an opponent: the humanizer's ladder can only be measured
    /// against itself, and something outside it has to say where zero is.
    case uciLimitStrength = "UCI_LimitStrength"
    /// Target rating for the limiter. Stockfish 17 accepts 1320–3190.
    case uciElo = "UCI_Elo"
}

public enum EngineError: Error, Sendable {
    case notStarted
    case searchAlreadyRunning
    case handshakeTimeout
    /// The engine went silent past the deadline for a search.
    case searchTimeout
    /// The engine answered a command with a diagnostic instead of the reply the
    /// caller was waiting for — a malformed position, an option it would not
    /// take, a command it did not recognise. Carries the line verbatim.
    case engineRejected(String)
    case missingNetwork(String)
}
