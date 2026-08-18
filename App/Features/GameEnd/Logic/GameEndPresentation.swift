import Database
import Foundation

/// The game → review handoff, as three beats of pure state.
///
/// 1. **Hold.** The final move lands and nothing changes for 600ms. No banner,
///    no dimming, no chrome. The player needs to see the position that ended the
///    game before anything is allowed to talk to them about it.
/// 2. **Banner.** A tinted bar rises from the bottom edge. The board does not
///    move, does not fade, does not go away; only the clocks drop to 40% because
///    they have stopped meaning anything. A back-arrow collapses the banner so
///    the final position can be looked at for as long as the player wants.
/// 3. **Summary.** Pushed, never presented — review is a destination you walk
///    back from, and a sheet would say "this is a detour".
enum GameEndStage: Equatable, Sendable {
    /// Game in progress.
    case none
    /// Beat 1: the quiet 600ms.
    case holding
    /// Beat 2: the banner is up.
    case banner
    /// The player collapsed the banner to look at the board.
    case collapsed

    /// How long the board is left alone before the banner rises.
    static let holdDuration = Duration.milliseconds(600)

    /// The stage a given elapsed time maps to. Extracted so the boundary is
    /// testable without sleeping through it.
    static func stage(elapsed: Duration, hold: Duration = holdDuration) -> GameEndStage {
        elapsed < hold ? .holding : .banner
    }
}

/// Drives the three beats. Owned by the play surface, one per game.
@Observable
@MainActor
final class GameEndSequencer {

    private(set) var stage: GameEndStage = .none

    private let hold: Duration

    init(hold: Duration = GameEndStage.holdDuration) {
        self.hold = hold
    }

    /// Beat 1 → beat 2. Idempotent: a second call while the banner is already up
    /// does nothing, so a re-render cannot restart the hold.
    func gameFinished() async {
        guard stage == .none else { return }
        stage = .holding
        try? await Task.sleep(for: hold)
        // A collapse or a reset during the hold wins; the player is ahead of us.
        guard stage == .holding else { return }
        stage = .banner
    }

    func collapse() {
        guard stage == .banner else { return }
        stage = .collapsed
    }

    func expand() {
        guard stage == .collapsed else { return }
        stage = .banner
    }

    func reset() {
        stage = .none
    }
}

// MARK: - Banner

/// What the result banner says.
struct GameEndBanner: Equatable, Sendable {

    enum Kind: Sendable {
        case win, loss, draw
    }

    var kind: Kind
    var symbolName: String
    /// One line. Not two, and never a second consoling one — see `ResultBanner`
    /// in the Train feature for the long version of that argument.
    var headline: String
    var ctaTitle: String

    /// Derives the banner from the session's own outcome vocabulary.
    ///
    /// The loss case is deliberately not red and deliberately not apologetic.
    /// Red means "advantage lost" in the eval segment; a red banner would make
    /// it mean "you lost" as well, and a colour with two meanings has none.
    /// `Docs/craft-standards.md` also lists a red X after a loss among the
    /// things that make an app feel cheap. So a loss states the fact in the same
    /// geometry as a win, tinted neutral.
    static func make(outcome: GameSession.Outcome, opponentName: String) -> GameEndBanner {
        let kind: Kind =
            switch outcome.userWon {
            case .some(true): .win
            case .some(false): .loss
            case nil: .draw
            }

        return GameEndBanner(
            kind: kind,
            symbolName: symbolName(for: kind),
            headline: headline(outcome: outcome, opponentName: opponentName, kind: kind),
            ctaTitle: "See the summary"
        )
    }

    private static func symbolName(for kind: Kind) -> String {
        switch kind {
        case .win: "checkmark.circle.fill"
        // A finish line, not a failure glyph.
        case .loss: "flag.checkered"
        case .draw: "equal.circle.fill"
        }
    }

    private static func headline(outcome: GameSession.Outcome, opponentName: String, kind: Kind) -> String {
        switch GameTermination(rawValue: outcome.termination) {
        case .checkmate:
            return kind == .win ? "Checkmate — you win." : "Checkmate. \(opponentName) wins."
        case .resignation:
            return kind == .win ? "\(opponentName) resigned." : "You resigned."
        case .timeout:
            return kind == .win ? "\(opponentName) ran out of time." : "You ran out of time."
        case .stalemate:
            return "Stalemate — draw."
        case .agreement:
            return "Draw agreed."
        case .fiftyMoves:
            return "Fifty moves without a capture — draw."
        case .insufficientMaterial:
            return "Not enough material to mate — draw."
        case .repetition:
            return "Threefold repetition — draw."
        case .unknown, .none:
            switch kind {
            case .win: return "You win."
            case .loss: return "\(opponentName) wins."
            case .draw: return "Draw."
            }
        }
    }
}

// MARK: - Summary

/// The summary screen's numbers and its one call to action.
///
/// Tone model is a single hero number with room around it, not a wall of tiles:
/// three stats, at most, and each one is either a value or a skeleton. Analysis
/// runs after the game, so accuracy and the moment count genuinely are not known
/// when this screen first appears — they arrive as `nil` and fill in, which is
/// the "render what's local, skeleton what's arriving" rule from the craft
/// standards rather than a spinner over the whole screen.
struct GameSummaryPresentation: Equatable, Sendable {

    struct Stat: Equatable, Sendable, Identifiable {
        var label: String
        /// `nil` draws a skeleton at the value's exact geometry.
        var value: String?
        var id: String { label }
    }

    enum Action: Equatable, Sendable {
        /// The CTA names the next step and its size, never `Continue`.
        case review(title: String)
        /// Nothing to review — the game never made it to disk.
        case unavailable(note: String)
    }

    var headline: String
    var detail: String
    var stats: [Stat]
    var action: Action

    struct Input: Sendable {
        var outcome: GameSession.Outcome
        var opponentName: String
        var opponentRating: Int
        /// Half-moves played.
        var plyCount: Int
        var accuracy: Double?
        var momentCount: Int?
        var analysisState: AnalysisState?
        /// Set when `GameSession` could not save the game.
        var persistenceFailure: String?

        init(
            outcome: GameSession.Outcome,
            opponentName: String,
            opponentRating: Int,
            plyCount: Int,
            accuracy: Double? = nil,
            momentCount: Int? = nil,
            analysisState: AnalysisState? = nil,
            persistenceFailure: String? = nil
        ) {
            self.outcome = outcome
            self.opponentName = opponentName
            self.opponentRating = opponentRating
            self.plyCount = plyCount
            self.accuracy = accuracy
            self.momentCount = momentCount
            self.analysisState = analysisState
            self.persistenceFailure = persistenceFailure
        }
    }

    static func make(_ input: Input) -> GameSummaryPresentation {
        let banner = GameEndBanner.make(outcome: input.outcome, opponentName: input.opponentName)
        let analysisFailed = input.analysisState == .failed

        let moveCount = (input.plyCount + 1) / 2
        // A skeleton means "still coming". Once the pass has landed — completed
        // or failed — a missing number is missing for good, and leaving a
        // placeholder pulsing at a number that will never arrive is worse than
        // saying so.
        let analysisSettled = analysisFailed || input.analysisState == .complete
        let accuracy: String? =
            if let value = input.accuracy {
                "\(Int(value.rounded()))%"
            } else if analysisSettled {
                "—"
            } else {
                nil
            }
        let moments: String? =
            if let count = input.momentCount {
                "\(count)"
            } else if analysisSettled {
                "—"
            } else {
                nil
            }

        return GameSummaryPresentation(
            headline: banner.headline,
            detail: "\(input.opponentName) · \(input.opponentRating)",
            stats: [
                Stat(label: "Moves", value: "\(moveCount)"),
                Stat(label: "Accuracy", value: accuracy),
                Stat(label: "Moments", value: moments),
            ],
            action: action(input: input, analysisFailed: analysisFailed)
        )
    }

    private static func action(input: Input, analysisFailed: Bool) -> Action {
        if input.persistenceFailure != nil {
            return .unavailable(note: "This game could not be saved, so there is nothing to review.")
        }
        guard let count = input.momentCount, !analysisFailed else {
            // Analysis is still running: name the destination honestly rather
            // than promising a number that might turn out to be two.
            return .review(title: "Open the review")
        }
        guard count > 0 else {
            return .review(title: "Open the review")
        }
        // Word for word the Today checklist's CTA — verb, object, price —
        // because this is the same step, and the loop only visibly closes if
        // the two screens call it the same thing. The estimate comes from the
        // same place too, so they cannot drift.
        let minutes = TodayPlanner.estimatedMinutes(for: .moments, remaining: count)
        return .review(title: "Review \(count) moment\(count == 1 ? "" : "s") · ~\(minutes) min")
    }
}
