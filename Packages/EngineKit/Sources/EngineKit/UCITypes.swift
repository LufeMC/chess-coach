import Foundation

/// An engine evaluation, always from the perspective of the side to move.
///
/// `mate(0)` is the one value whose sign does not follow the rule the others
/// do: an engine reports `score mate 0` for a position that is *already*
/// checkmate with the scored side to move, so it means "I am mated", not "I
/// mate in zero". Everything here treats it as a loss for that reason —
/// `AnalysisKit.EvalMath.winPercent(score:)` already scores it 0%, and this type
/// used to disagree with it.
public enum UCIScore: Sendable, Equatable {
    case centipawns(Int)
    /// Moves (not plies) until mate. Negative means the side to move is getting
    /// mated; zero means the side to move is mated already.
    case mate(Int)

    /// Centipawns clamped into a finite range, with mates mapped to the extremes.
    /// Analysis math wants a single number; `mateEquivalent` keeps mate scores
    /// from dominating averages.
    public func centipawnValue(mateEquivalent: Int = 10_000) -> Int {
        switch self {
        case .centipawns(let cp): return cp
        // `> 0`, not `>= 0`: mate in *zero* is a position already checkmated
        // with this side to move, which is the worst score there is rather than
        // the best. The strictly-greater test used to be `>=`, which handed the
        // one terminal mate value a winning number.
        case .mate(let moves): return moves > 0 ? mateEquivalent : -mateEquivalent
        }
    }

    /// Flips perspective (used when converting between side-to-move and white-relative).
    ///
    /// `mate(0)` survives the flip unchanged and therefore reads as a loss from
    /// both sides, which is wrong for exactly one of them. It is left that way
    /// deliberately: turning it into `mate(1)` would invent a distance to mate
    /// the engine never reported. Producers avoid the value instead —
    /// `AnalysisPipeline.terminalScore(for:)` emits `.mate(-1)` for a mated
    /// position so that the negation carries a real number.
    public var negated: UCIScore {
        switch self {
        case .centipawns(let cp): return .centipawns(-cp)
        case .mate(let m): return .mate(-m)
        }
    }
}

/// Whether a score is the engine's final word at that depth.
///
/// Stockfish prints `lowerbound`/`upperbound` when a root move failed outside
/// its aspiration window and the iteration has not re-searched it yet: the
/// number is a bound clamped to the window, not an evaluation. A search that is
/// stopped — by a `stop`, by its node limit, by its movetime — prints whatever
/// it had, so the last line of a cut-off search is routinely a bound, and it
/// can sit next to a *different* rank still carrying the previous iteration's
/// exact score. Any consumer that subtracts one rank from another (the guided
/// criticality gate, best-vs-played) is comparing two different measurements
/// unless it checks this first.
public enum ScoreBound: String, Sendable, Equatable {
    /// A real evaluation, searched inside the window.
    case exact
    /// The true score is at least this; the line failed high.
    case lower
    /// The true score is at most this; the line failed low.
    case upper
}

/// One `info` line from the engine, keyed by its MultiPV rank.
public struct UCIInfo: Sendable, Equatable {
    public var multipv: Int
    public var depth: Int
    public var selDepth: Int
    public var score: UCIScore
    /// Whether `score` is an evaluation or a window bound. See ``ScoreBound``.
    public var bound: ScoreBound
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
        bound: ScoreBound = .exact,
        nodes: Int = 0,
        nps: Int = 0,
        timeMs: Int = 0,
        pv: [String] = []
    ) {
        self.multipv = multipv
        self.depth = depth
        self.selDepth = selDepth
        self.score = score
        self.bound = bound
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
    ///
    /// It only ever means "somebody stopped this", though, so it is half the
    /// answer — see ``completedDepth`` for the other half.
    public var wasTruncated: Bool

    /// The deepest iteration rank 1 actually finished: the greatest depth at
    /// which the engine printed an exact rank-1 score.
    ///
    /// The reason this exists is that ``wasTruncated`` cannot see the search cut
    /// itself short. A `.depthWithin` search — the sparring opponent's, whose
    /// depth *is* its playing strength — is stopped by Stockfish itself when the
    /// movetime backstop arrives, and that result comes back with
    /// `wasTruncated == false` and lines from whatever iteration it had reached.
    /// A "depth 13" opponent that only ever got to depth 9 then wins a rated
    /// game at full weight, with nothing anywhere recording that it was not the
    /// opponent it claimed to be. Comparing this against the depth that was
    /// asked for is how a caller tells the two apart.
    ///
    /// Zero when the engine printed no exact rank-1 line at all (a terminal
    /// position, or a search stopped inside its first iteration).
    public var completedDepth: Int

    public init(
        bestMove: String?,
        ponderMove: String? = nil,
        lines: [UCIInfo] = [],
        wasTruncated: Bool = false,
        completedDepth: Int = 0
    ) {
        self.bestMove = bestMove
        self.ponderMove = ponderMove
        self.lines = lines
        self.wasTruncated = wasTruncated
        self.completedDepth = completedDepth
    }

    /// Whether the search reached the depth it was asked for.
    ///
    /// Answers `true` for limits that never named a depth: "did it get there" is
    /// not a question a node- or time-limited search can fail.
    public func reachedRequestedDepth(of limit: SearchLimit) -> Bool {
        switch limit {
        case .depth(let depth), .depthWithin(let depth, _):
            return completedDepth >= depth
        case .nodes, .movetime, .clock, .infinite:
            return true
        }
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
