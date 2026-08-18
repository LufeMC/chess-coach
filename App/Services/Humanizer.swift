import EngineKit
import Foundation

/// Turns full-strength engine output into a plausible human opponent.
///
/// Stockfish's own `UCI_LimitStrength`/`UCI_Elo` is deliberately not used:
/// its floor is 1320 (too strong for this user's band), and measurements show
/// weakened Stockfish matches human move choices only ~35-40% of the time
/// versus ~46-53% for human-trained models — it plays engine chess with noise
/// stirred in, which reads as alien rather than beatable.
///
/// Instead this samples among MultiPV candidates from a **depth-capped** search.
/// The depth cap is what makes the errors structural: a human rated 900 doesn't
/// miss a three-move tactic at random, they miss it because they didn't look
/// three moves ahead. Capping the horizon reproduces that, and the sampling
/// layer only decides how often the opponent takes the best of what it *did* see.
struct Humanizer: Sendable {

    /// Engine settings and error rates for one rating band.
    struct Profile: Sendable, Equatable {
        var rating: Int
        /// Search depth cap — models the opponent's calculation horizon.
        var depth: Int
        /// Softmax temperature in win-percentage points. Higher = looser play.
        var temperature: Double
        /// Chance per move of a discrete blunder event.
        var blunderProbability: Double
        /// Plies of extra opening randomness.
        var openingRandomPlies: Int
        /// MultiPV width to request.
        var multiPV: Int

        /// Calibration anchors. Values between anchors are interpolated, so the
        /// ladder is continuous rather than stepping at band boundaries.
        static let anchors: [Profile] = [
            Profile(rating: 800, depth: 5, temperature: 11.0, blunderProbability: 0.13, openingRandomPlies: 12, multiPV: 12),
            Profile(rating: 1200, depth: 8, temperature: 6.0, blunderProbability: 0.08, openingRandomPlies: 8, multiPV: 10),
            Profile(rating: 1600, depth: 11, temperature: 4.0, blunderProbability: 0.04, openingRandomPlies: 6, multiPV: 10),
            Profile(rating: 2000, depth: 13, temperature: 2.0, blunderProbability: 0.02, openingRandomPlies: 4, multiPV: 8),
            Profile(rating: 2200, depth: 16, temperature: 1.0, blunderProbability: 0.015, openingRandomPlies: 2, multiPV: 8),
        ]

        /// Piecewise-linear interpolation between anchors, clamped at the ends.
        static func interpolated(rating: Int) -> Profile {
            let clamped = min(max(rating, anchors.first!.rating), anchors.last!.rating)

            if let exact = anchors.first(where: { $0.rating == clamped }) { return exact }

            guard
                let upperIndex = anchors.firstIndex(where: { $0.rating > clamped }),
                upperIndex > 0
            else { return anchors.last! }

            let lower = anchors[upperIndex - 1]
            let upper = anchors[upperIndex]
            let t = Double(clamped - lower.rating) / Double(upper.rating - lower.rating)

            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }

            return Profile(
                rating: clamped,
                depth: Int(lerp(Double(lower.depth), Double(upper.depth)).rounded()),
                temperature: lerp(lower.temperature, upper.temperature),
                blunderProbability: lerp(lower.blunderProbability, upper.blunderProbability),
                openingRandomPlies: Int(lerp(Double(lower.openingRandomPlies), Double(upper.openingRandomPlies)).rounded()),
                multiPV: Int(lerp(Double(lower.multiPV), Double(upper.multiPV)).rounded())
            )
        }
    }

    /// What the opponent decided, and why — recorded on the game so a later
    /// review can explain the opponent's level honestly.
    struct Selection: Sendable {
        var move: String
        var wasBlunderEvent: Bool
        var rankChosen: Int
        var candidateCount: Int
    }

    var profile: Profile

    /// Chooses a move from the engine's candidate lines.
    ///
    /// - Parameters:
    ///   - lines: MultiPV results, best first.
    ///   - ply: Current ply, used for opening randomness.
    ///   - rng: Injected so tests are deterministic.
    func choose(
        from lines: [UCIInfo],
        ply: Int,
        using rng: inout some RandomNumberGenerator
    ) -> Selection? {
        let candidates = lines.filter { $0.bestMove != nil }
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else {
            return Selection(move: candidates[0].bestMove!, wasBlunderEvent: false, rankChosen: 1, candidateCount: 1)
        }

        // Win% from the opponent's own perspective; engine scores are already
        // side-to-move relative, so no sign flip is needed here.
        let winPercents = candidates.map { winPercent(for: $0.score) }
        let best = winPercents.max() ?? 0

        // Two-mode error model. Consistent small inaccuracies alone read as a
        // uniformly weak engine; humans also produce occasional discrete
        // blunders that don't fit the surrounding quality. Modeling those
        // separately is what makes the opponent feel human rather than merely
        // weak.
        let blunderRoll = Double.random(in: 0..<1, using: &rng)
        let isBlunderEvent = blunderRoll < profile.blunderProbability

        // Early-game randomness keeps openings varied without needing a book.
        let openingBoost = ply < profile.openingRandomPlies ? 4.0 : 0.0
        let temperature = (isBlunderEvent ? profile.temperature * 4.0 : profile.temperature) + openingBoost

        // Softmax over how much each candidate gives up against the best line.
        let weights = winPercents.map { exp(-(best - $0) / max(temperature, 0.25)) }
        let total = weights.reduce(0, +)
        guard total > 0, total.isFinite else {
            return Selection(move: candidates[0].bestMove!, wasBlunderEvent: false, rankChosen: 1, candidateCount: candidates.count)
        }

        var target = Double.random(in: 0..<total, using: &rng)
        for (index, weight) in weights.enumerated() {
            target -= weight
            if target <= 0 {
                return Selection(
                    move: candidates[index].bestMove!,
                    wasBlunderEvent: isBlunderEvent,
                    rankChosen: candidates[index].multipv,
                    candidateCount: candidates.count
                )
            }
        }

        let last = candidates.count - 1
        return Selection(
            move: candidates[last].bestMove!,
            wasBlunderEvent: isBlunderEvent,
            rankChosen: candidates[last].multipv,
            candidateCount: candidates.count
        )
    }

    /// Lichess's centipawn-to-win-percentage curve, duplicated here rather than
    /// taken from AnalysisKit so the play path carries no analysis dependency.
    private func winPercent(for score: UCIScore) -> Double {
        switch score {
        case .mate(let moves):
            return moves > 0 ? 100 : 0
        case .centipawns(let cp):
            let clamped = Double(min(max(cp, -1000), 1000))
            return 50 + 50 * (2 / (1 + exp(-0.00368208 * clamped)) - 1)
        }
    }

    /// A plausible think time, so the opponent doesn't reply instantly on every
    /// move. Complex positions (more candidates that are close together) get
    /// more time.
    func thinkTime(candidates: [UCIInfo], using rng: inout some RandomNumberGenerator) -> Duration {
        let base = Double.random(in: 0.4...1.6, using: &rng)
        let closeCandidates = candidates.prefix(4).map { winPercent(for: $0.score) }
        let spread = (closeCandidates.max() ?? 0) - (closeCandidates.min() ?? 0)
        // A tight spread means a genuinely hard choice — take longer.
        let deliberation = spread < 5 ? Double.random(in: 0.5...2.0, using: &rng) : 0
        return .milliseconds(Int((base + deliberation) * 1000))
    }
}

/// Maps the user's rating to the opponent's rating for the next game.
///
/// The opponent sits slightly above the user most of the time: a training
/// partner that is always beatable stops producing mistakes worth studying.
/// The cycle mixes in one stretch game and one confidence game per four so the
/// user isn't permanently under pressure.
enum OpponentLadder {

    static func rating(forUserRating userRating: Double, gameIndex: Int) -> Int {
        let offsets = [50, 50, 150, 0]
        let offset = offsets[gameIndex % offsets.count]
        let raw = Int(userRating.rounded()) + offset
        // Round to 25 so the displayed opponent rating looks deliberate.
        let rounded = (raw / 25) * 25
        return min(max(rounded, 800), 2200)
    }
}
