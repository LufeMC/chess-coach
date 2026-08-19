import ChessKit
import EngineKit
import Foundation
import Testing

@testable import ChessCoach

/// Measures what the humanizer's rating labels are actually worth.
///
/// `Humanizer.Profile.anchors` labels five profiles 800 through 2200, and the
/// opponent ladder, the Elo updates, and the user's whole sense of progress rest
/// on those numbers. They were chosen by reasoning about depth caps and error
/// rates — plausible reasoning, but never measured. An opponent labelled 1200
/// that actually plays at 1500 makes the ladder lie in the direction that hurts
/// most: it tells a improving player they are stuck.
///
/// This harness plays adjacent anchors against each other and converts the
/// result into an Elo gap. Two profiles 400 points apart should score about
/// 91% / 9%; if they score 60/40, the ladder is compressed and the labels need
/// re-spacing.
///
/// ## Why this is opt-in
///
/// A single measurement is hundreds of real engine games — minutes to hours, not
/// the 4.6 seconds the rest of the suite takes. It is a calibration tool you run
/// when you change an anchor, not a regression test. Run it with:
///
/// ```
/// CHESSCOACH_SELF_PLAY=1 xcodebuild test -scheme ChessCoach \
///   -only-testing:ChessCoachTests/HumanizerSelfPlay -skipMacroValidation \
///   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
/// ```
///
/// Set `CHESSCOACH_SELF_PLAY_GAMES` to change the sample size (default 40 per
/// pairing, which resolves a 400-point gap but not a 50-point one).
@Suite(
    "Humanizer self-play calibration",
    .enabled(if: ProcessInfo.processInfo.environment["CHESSCOACH_SELF_PLAY"] != nil)
)
struct HumanizerSelfPlay {

    /// Networks resolved relative to this file rather than an absolute path, so
    /// the harness runs on any checkout.
    private static var networkDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppTests
            .deletingLastPathComponent()   // repo root
            .appending(path: "App/Resources/Networks")
    }

    private static var gamesPerPairing: Int {
        ProcessInfo.processInfo.environment["CHESSCOACH_SELF_PLAY_GAMES"]
            .flatMap(Int.init) ?? 40
    }

    /// Restricts the run to one adjacent pairing, by index.
    ///
    /// The measurement is dominated by the top of the ladder — depth 16 at
    /// MultiPV 8 costs an order of magnitude more per move than depth 5 — so a
    /// serial run spends most of its wall clock on one pairing and frequently
    /// never reaches it. Selecting a pairing lets the four run as separate
    /// single-threaded processes at once, which is the difference between a
    /// measurement that finishes and one that gets truncated.
    private static var pairingIndex: Int? {
        ProcessInfo.processInfo.environment["CHESSCOACH_SELF_PLAY_PAIRING"]
            .flatMap(Int.init)
    }

    /// Shifts every game's seed, so the same pairing can be split across
    /// several processes and produce *different* games in each.
    ///
    /// Without this, running one pairing four times over is four identical
    /// measurements: the generator is seeded from the game index precisely so a
    /// reported number can be reproduced. The top pairing needs it — two strong
    /// profiles draw most of their games, so the score is built from the few
    /// decisive ones and the only way to a usable interval is more games than
    /// one process can play in reasonable time.
    private static var seedOffset: UInt64 {
        ProcessInfo.processInfo.environment["CHESSCOACH_SELF_PLAY_SEED_OFFSET"]
            .flatMap(UInt64.init) ?? 0
    }

    /// An override for the anchor table, so a candidate ladder can be measured
    /// without editing source and rebuilding.
    ///
    /// Format is one profile per comma-separated group, colon-separated:
    ///
    ///     rating:depth:temperature:blunder:openingPlies:multiPV
    ///     800:4:12:0.14:12:16,1200:6:8:0.09:8:13,...
    ///
    /// Calibrating a ladder is a search, not a single measurement: every
    /// candidate has to be played out, and a build per candidate turns a
    /// half-hour loop into a day. Anything the override does not name falls
    /// back to the shipped anchors, so a run with no override measures exactly
    /// what the app ships — which is what makes the shipped numbers in
    /// `Docs/humanizer-calibration.md` reproducible.
    private static var profileOverride: [Humanizer.Profile]? {
        guard let spec = ProcessInfo.processInfo.environment["CHESSCOACH_SELF_PLAY_PROFILES"],
              !spec.isEmpty
        else { return nil }

        let profiles: [Humanizer.Profile] = spec.split(separator: ",").compactMap { group in
            let f = group.split(separator: ":")
            guard f.count == 6,
                  let rating = Int(f[0]), let depth = Int(f[1]),
                  let temperature = Double(f[2]), let blunder = Double(f[3]),
                  let openingPlies = Int(f[4]), let multiPV = Int(f[5])
            else { return nil }
            return Humanizer.Profile(
                rating: rating,
                depth: depth,
                temperature: temperature,
                blunderProbability: blunder,
                openingRandomPlies: openingPlies,
                multiPV: multiPV
            )
        }

        // A malformed spec must not silently measure the shipped ladder and
        // report the answer as if it were the candidate's.
        guard profiles.count == spec.split(separator: ",").count, profiles.count >= 2 else {
            fatalError("CHESSCOACH_SELF_PLAY_PROFILES could not be parsed: \(spec)")
        }
        return profiles.sorted { $0.rating < $1.rating }
    }

    /// The ladder under measurement.
    static var ladder: [Humanizer.Profile] { profileOverride ?? Humanizer.Profile.anchors }

    /// Where a completed pairing appends its result, so parallel runs can be
    /// collected without parsing four separate test logs.
    private static var resultsPath: String? {
        ProcessInfo.processInfo.environment["CHESSCOACH_SELF_PLAY_OUT"]
    }

    private static func record(_ result: PairingResult) {
        guard let resultsPath else { return }
        let line = "\(result.strongerRating),\(result.weakerRating),\(result.strongerScore),"
            + "\(result.games),\(result.decisive),\(result.measuredGap),\(result.aborted)\n"
        if let handle = FileHandle(forWritingAtPath: resultsPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: resultsPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Result model

    /// One pairing's outcome, in the terms the ladder is expressed in.
    struct PairingResult {
        var strongerRating: Int
        var weakerRating: Int
        var strongerScore: Double
        /// Games that produced a result. Aborts are not in here.
        var games: Int
        var decisive: Int
        /// Games the harness could not finish. Reported so a defect in the game
        /// loop shows up as a number instead of hiding inside the draw rate.
        var aborted: Int = 0

        /// Labelled gap the anchors claim.
        var claimedGap: Int { strongerRating - weakerRating }

        /// Gap the games actually produced.
        ///
        /// Standard Elo inversion. Clamped away from 0 and 1 because a clean
        /// sweep is unbounded in Elo terms and would report infinity.
        var measuredGap: Double {
            let score = min(max(strongerScore, 0.01), 0.99)
            return -400 * log10(1 / score - 1)
        }

        var summary: String {
            String(
                format: "%d vs %d — stronger scored %.1f%% over %d games (%d decisive, %d aborted). Claimed %+d Elo, measured %+.0f Elo.",
                strongerRating, weakerRating, strongerScore * 100, games, decisive, aborted,
                claimedGap, measuredGap
            )
        }
    }

    // MARK: The measurement

    @Test("Adjacent anchors are separated by roughly the Elo they claim")
    func adjacentAnchorsAreSeparated() async throws {
        let engineService = EngineService()
        try await engineService.boot(
            networks: NetworkPaths(
                small: Self.networkDirectory.appending(path: "nn-37f18f62d772.nnue"),
                big: Self.networkDirectory.appending(path: "nn-1c0000000000.nnue")
            )
        )

        let anchors = Self.ladder
        var results: [PairingResult] = []
        if Self.profileOverride != nil {
            print("[self-play] measuring CANDIDATE ladder: \(anchors.map(\.rating))")
        }

        let pairings = Self.pairingIndex.map { [$0] } ?? Array(0..<(anchors.count - 1))

        for index in pairings where index < anchors.count - 1 {
            let weaker = anchors[index]
            let stronger = anchors[index + 1]

            let result = try await play(
                stronger: stronger,
                weaker: weaker,
                games: Self.gamesPerPairing,
                engineService: engineService
            )
            results.append(result)
            Self.record(result)
            print("[self-play] \(result.summary)")
        }

        for result in results {
            // A loop that cannot finish its games is not measuring anything.
            // This is the assertion that would have caught the promotion bug on
            // its first run instead of after three rounds of published numbers.
            #expect(
                result.aborted <= max(1, (result.games + result.aborted) / 20),
                "ABORTED GAMES: \(result.aborted) of \(result.games + result.aborted). The game loop failed; the profiles are not being measured. \(result.summary)"
            )

            // The stronger profile must at minimum be stronger. A pairing that
            // fails this is not "close enough" — it means the ladder is
            // inverted somewhere and the labels are actively misleading.
            #expect(
                result.strongerScore > 0.5,
                "INVERTED LADDER: \(result.summary)"
            )

            // A generous band, because 40 games leaves a wide confidence
            // interval and the point is to catch gross miscalibration, not to
            // certify a number. A 400-point claimed gap that measures under 100
            // means the ladder is badly compressed.
            #expect(
                result.measuredGap > Double(result.claimedGap) * 0.25,
                "COMPRESSED LADDER: \(result.summary)"
            )
        }
    }

    // MARK: Game loop

    private func play(
        stronger: Humanizer.Profile,
        weaker: Humanizer.Profile,
        games: Int,
        engineService: EngineService
    ) async throws -> PairingResult {
        var strongerPoints = 0.0
        var decisive = 0
        var played = 0
        var aborted = 0

        for game in 0..<games {
            // Alternate colours so a first-move advantage cannot masquerade as
            // a strength difference.
            let strongerPlaysWhite = game.isMultiple(of: 2)
            let outcome = try await playOne(
                white: strongerPlaysWhite ? stronger : weaker,
                black: strongerPlaysWhite ? weaker : stronger,
                seed: Self.seedOffset &+ UInt64(game &+ 1),
                engineService: engineService
            )

            switch outcome {
            case .whiteWins:
                strongerPoints += strongerPlaysWhite ? 1 : 0
                decisive += 1
                played += 1
            case .blackWins:
                strongerPoints += strongerPlaysWhite ? 0 : 1
                decisive += 1
                played += 1
            case .draw:
                strongerPoints += 0.5
                played += 1
            case .aborted:
                // Excluded from the score entirely rather than counted as a
                // draw. An abort is a measurement failure, not a result, and
                // the score has to be over the games that actually finished.
                aborted += 1
            }
        }

        return PairingResult(
            strongerRating: stronger.rating,
            weakerRating: weaker.rating,
            strongerScore: played > 0 ? strongerPoints / Double(played) : 0.5,
            games: played,
            decisive: decisive,
            aborted: aborted
        )
    }

    private enum GameOutcome {
        case whiteWins
        case blackWins
        case draw
        /// The loop could not continue — a move that would not parse or would
        /// not apply, or the ply cap.
        ///
        /// Kept separate from `draw` because conflating them is how a bug hides
        /// for a whole measurement. Promotion did exactly that: `Board.move`
        /// leaves the board mid-promotion, the next move then fails to apply,
        /// and every game that reached a promotion was silently scored half a
        /// point each. That biases *against* the stronger profile, which is the
        /// side that usually promotes, so the ladder measured flatter than it
        /// is — and the only visible symptom was a draw rate nobody questioned.
        case aborted
    }

    private func playOne(
        white: Humanizer.Profile,
        black: Humanizer.Profile,
        seed: UInt64,
        engineService: EngineService
    ) async throws -> GameOutcome {
        var board = Board(position: .standard)
        var history: [String] = []
        var rng = SplitMix64(seed: seed)

        // A hard ply cap: two weak profiles can shuffle indefinitely, and an
        // unbounded loop here would hang the whole measurement.
        let maxPlies = 300

        for ply in 0..<maxPlies {
            let profile = board.position.sideToMove == .white ? white : black
            let humanizer = Humanizer(profile: profile)

            await engineService.acquire(
                .play,
                configuration: EngineService.Configuration(
                    multiPV: profile.multiPV,
                    threads: 1,
                    hashMB: 64
                )
            )

            let result = try await engineService.search(
                .startPosition(moves: history),
                limit: .depth(profile.depth)
            )
            await engineService.release(.play)

            guard
                let selection = humanizer.choose(from: result.lines, ply: ply, using: &rng),
                let move = EngineLANParser.parse(
                    move: selection.move,
                    for: board.position.sideToMove,
                    in: board.position
                ),
                board.move(pieceAt: move.start, to: move.end) != nil
            else {
                return .aborted
            }

            // `Board.move` does not promote. A pawn reaching the last rank
            // leaves `state == .promotion` with the pawn still a pawn, and
            // `updateState` returns *before* looking for checkmate or draw — so
            // without this the board silently diverges from the move list the
            // engine is being sent, and the next move fails to apply.
            //
            // The engine names the piece in the fifth character of the UCI
            // string, which `EngineLANParser` has already decoded onto
            // `promotedPiece`. Queen is the fallback for a bare four-character
            // promotion, matching `LineReplay.apply`.
            if case .promotion(let pending) = board.state {
                _ = board.completePromotion(of: pending, to: move.promotedPiece?.kind ?? .queen)
            }

            history.append(selection.move)

            switch board.state {
            case .checkmate(let mated):
                return mated == .white ? .blackWins : .whiteWins
            case .draw:
                return .draw
            default:
                continue
            }
        }

        // Ran out of plies. Not a draw: a game still going at ply 300 is a game
        // this harness failed to resolve, and calling it half a point each
        // quietly rewards whichever profile stalls better.
        return .aborted
    }

    /// Deterministic generator so a reported measurement can be reproduced
    /// exactly from its seed.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
