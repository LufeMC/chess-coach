//
//  MomentSelector.swift
//  AnalysisKit
//

import ChessKit

/// Picks the handful of positions worth showing a player after a game.
///
/// The hard part is not ranking, it is *variety*. A single bad plan produces five
/// moments with the same cause tag, and showing all five teaches nothing that the
/// first one did not. So selection is greedy by score but constrained three ways:
/// one moment per cause tag, a minimum ply gap so consecutive moves in the same
/// skirmish do not both appear, and a cap of three.
///
/// The positive moment is handled last and separately: praise is only earned when
/// the game did not already fill the slate with things to fix.
public enum MomentSelector {

    /// - parameter candidates: Every scored moment from the game, mistakes and at
    ///   most one reinforcement.
    /// - returns: At most `policy.limit` moments, ordered by score.
    public static func select(candidates: [Moment], policy: MomentPolicy = .none) -> [Moment] {
        let mistakes = candidates
            .filter { $0.kind == .mistake }
            .sorted { $0.total > $1.total }
        let reinforcements = candidates
            .filter { $0.kind == .reinforcement }
            .sorted { $0.total > $1.total }

        var selected: [Moment] = []
        var usedTags: Set<CauseTag> = []

        for (index, candidate) in mistakes.enumerated() {
            guard selected.count < policy.limit else { break }
            guard respectsSpacing(candidate, selected: selected, policy: policy) else { continue }

            if usedTags.contains(candidate.causeTag) {
                // A repeat of an already-covered cause only earns its slot when it
                // dwarfs the best thing we would otherwise show — the same lesson
                // twice is worth it if the second instance is far more dramatic.
                let bestAlternative = mistakes[(index + 1)...]
                    .filter { !usedTags.contains($0.causeTag) }
                    .map(\.total)
                    .max()
                if let bestAlternative, candidate.total < policy.duplicateTagDominance * bestAlternative {
                    continue
                }
            }

            selected.append(candidate)
            usedTags.insert(candidate.causeTag)
        }

        // "Only if fewer than three mistakes qualify": the reinforcement fills a
        // leftover slot, it never competes for one.
        if selected.count < policy.limit, let positive = reinforcements.first(
            where: { respectsSpacing($0, selected: selected, policy: policy) }
        ) {
            selected.append(positive)
        }

        return selected.sorted { $0.total > $1.total }
    }

    static func respectsSpacing(_ candidate: Moment, selected: [Moment], policy: MomentPolicy) -> Bool {
        selected.allSatisfy { abs($0.ply - candidate.ply) >= policy.minimumPlySpacing }
    }
}
