import Database
import Foundation
import Observation
import SwiftUI

/// Everything the summary needs that only the finished session knows.
///
/// Carried across the push rather than re-read, so the headline is correct the
/// instant the screen appears — the game is still being written to disk at that
/// point, and a summary that says "loading" about a game the user just played is
/// absurd.
struct GameSummaryTarget: Identifiable, Hashable {
    var gameID: UUID
    var outcome: GameSession.Outcome
    var opponentName: String
    var opponentRating: Int
    var plyCount: Int
    var persistenceFailure: String?

    var id: UUID { gameID }

    static func == (lhs: GameSummaryTarget, rhs: GameSummaryTarget) -> Bool {
        lhs.gameID == rhs.gameID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(gameID)
    }
}

/// Beat 3 of the handoff: what the game amounted to, and the one step that
/// follows it.
///
/// Pushed, not presented. Review is a destination you walk back from, and a
/// sheet would frame the whole post-game loop as a detour from playing.
///
/// The tone model is one number with room around it. No confetti — especially
/// not after a loss, and having it only after a win is worse, because then the
/// screen's *shape* tells you how to feel about your own game. Three numbers,
/// two of which arrive late and skeleton in place until they do.
struct GameSummaryScreen: View {

    let target: GameSummaryTarget

    @State private var model: GameSummaryModel
    /// Optional so the preview — and any host that does not build the services —
    /// still renders; without the engine the screen simply falls back to polling
    /// the row instead of following the pass ply by ply.
    @Environment(AppModel.self) private var appModel: AppModel?

    init(target: GameSummaryTarget) {
        self.target = target
        _model = State(initialValue: GameSummaryModel(gameID: target.gameID))
    }

    private var presentation: GameSummaryPresentation {
        GameSummaryPresentation.make(
            GameSummaryPresentation.Input(
                outcome: target.outcome,
                opponentName: target.opponentName,
                opponentRating: target.opponentRating,
                plyCount: target.plyCount,
                accuracy: model.accuracy,
                momentCount: model.momentCount,
                analysisState: model.analysisState,
                persistenceFailure: target.persistenceFailure
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.headline)
                        .typeRole(.title)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(presentation.detail)
                        .typeRole(.caption)
                }

                Spacer(minLength: 0)

                // The person you just played, same face as the Play screen —
                // the summary is the end of a conversation with them.
                OpponentAvatar(name: target.opponentName, size: 64)
            }

            // A deliberate, fixed distance rather than a spacer: the numbers
            // belong to the sentence above them, and floating them in the middle
            // of the screen makes the page read as two unrelated halves.
            HStack(alignment: .top, spacing: 0) {
                ForEach(presentation.stats) { stat in
                    StatColumn(stat: stat)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 40)

            if isAnalysing {
                analysisStatus
                    .padding(.top, 18)
            }

            if let failure = target.persistenceFailure {
                SummaryNotice(text: "Not saved — \(StorageFailureText.sentence(failure))")
                    .padding(.top, 18)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            action
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A game that never reached disk has no row for the pass to run
            // against, so polling for one would run until the screen closes.
            guard target.persistenceFailure == nil else { return }
            await model.track(engineService: appModel?.engineService)
        }
    }

    // MARK: - Analysis status

    /// Whether the pass is still owed the two late numbers.
    ///
    /// A game that failed to save is excluded outright: saying "analysing" over
    /// a notice that says the game does not exist is two sentences that cannot
    /// both be true.
    private var isAnalysing: Bool {
        guard target.persistenceFailure == nil else { return false }
        return model.analysisState == nil
            || model.analysisState == .pending
            || model.analysisState == .running
    }

    /// The one genuinely slow step in the daily loop, priced.
    ///
    /// The pass already publishes ply counts precisely because "move 17 of 36"
    /// is a chess player's unit; before this screen read them the user was given
    /// a sentence with no way to tell ten seconds from two minutes. The bar is
    /// determinate whenever the ply total is known and absent when it is not —
    /// an indeterminate bar is a spinner with extra pixels.
    private var analysisStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(analysisCaption)
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if let fraction = model.progress?.fraction {
                ProgressView(value: fraction)
                    .tint(Palette.accent.dynamic)
                    .animation(Motion.standard, value: fraction)
            }

            // The natural reaction to an unpriced wait is to switch apps, and
            // that is the one action that guarantees the wait never ends: the
            // engine is suspended on backgrounding and the queue does not drain
            // again until the next game or the next launch.
            Text("Keep Rookly open — analysis pauses when the app goes to the background.")
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the wait is doing, and how long it should take.
    ///
    /// The fallback is not "Analysing" any more. A pass preempted by a
    /// higher-priority engine claim — opening Train does it, so does locking the
    /// phone — goes back to `pending`, and nothing was running at all while this
    /// screen said it was. Claiming work that is not happening is the failure
    /// this caption existed to prevent, so with no live pass it reports the
    /// queue and prices it instead.
    private var analysisCaption: String {
        guard let progress = model.progress, progress.gameID == target.gameID else {
            let estimate = GameSummaryPresentation.analysisEstimateText(plyCount: target.plyCount)
            switch model.analysisState {
            case .some(.running):
                return "Analysing the game — accuracy and moments fill in here. Takes \(estimate)."
            case .none, .some(.pending):
                return "Waiting for the engine — analysis starts as soon as it is free, "
                    + "and takes \(estimate)."
            default:
                return "Analysing the game — accuracy and moments fill in here."
            }
        }
        switch progress.stage {
        case .queued:
            return "Queued — the engine finishes what it is doing first."
        case .evaluating:
            let total = max(1, progress.total / 2)
            return "Analysing · move \(min(max(1, (progress.ply + 1) / 2), total)) of \(total)"
        case .enriching:
            return "Looking closer at the \(progress.total) positions that mattered."
        case .selecting, .writing:
            return "Writing the notes…"
        case .paused:
            return "Paused — the engine was needed for something else. It resumes where it stopped."
        case .finished, .failed:
            return "Analysing the game — accuracy and moments fill in here."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch presentation.action {
        case .review(let title):
            // Routed rather than pushed. A `NavigationLink` here puts the review
            // two deep inside the Play tab, where the tab bar is hidden and
            // getting back to the daily loop is Back, Back, then a glyph
            // labelled "Done with this game". Going through the model puts it in
            // the Today stack instead, so the review always has a tab bar under
            // it and Back always means Today.
            //
            // The link survives as the fallback for hosts that build no model —
            // previews and the Mac library — where a push is the only way there.
            if let appModel {
                Button(title) {
                    appModel.navigate(to: .review(gameID: target.gameID))
                }
                .buttonStyle(.primaryAction)
            } else {
                NavigationLink {
                    ReviewScreen(gameID: target.gameID)
                } label: {
                    Text(title)
                }
                .buttonStyle(.primaryAction)
            }

        case .unavailable(let note):
            Text(note)
                .typeRole(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One number, with its label a tier below it in the type scale.
private struct StatColumn: View {

    let stat: GameSummaryPresentation.Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value = stat.value {
                Text(value)
                    .typeRole(.title, monospacedDigits: true)
                    .contentTransition(.numericText())
            } else {
                // Skeleton at the value's own geometry, so nothing jumps when
                // the real number lands.
                SkeletonView(width: 46, height: 30)
                    .padding(.vertical, 2)
            }

            Text(stat.label)
                .typeRole(.label)
        }
        .animation(Motion.colorShift, value: stat.value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(stat.label): \(stat.value ?? "still being worked out")"))
    }
}

// MARK: - Storage failures

/// One sentence for a write that failed, in the app's voice.
///
/// The raw value is a GRDB description — "SQLite error 13: database or disk is
/// full" — which is honest and unusable: it names a library rather than
/// anything the person holding the phone can do about it. The raw text belongs
/// in the log, where it is worth having. Matched on substrings because a string
/// is all that survives the hop back from the database task; an unrecognised
/// one falls through to a sentence that at least says what was lost.
enum StorageFailureText {

    static func sentence(_ failure: String) -> String {
        let text = failure.lowercased()
        if text.contains("disk is full") || text.contains("sqlite error 13") {
            return "the phone is out of storage."
        }
        if text.contains("readonly") || text.contains("sqlite error 8") {
            return "the games file cannot be written to."
        }
        if text.contains("locked") || text.contains("busy") {
            return "the games file was busy. Playing another game usually clears it."
        }
        return "the games file could not be written."
    }

    /// The same failures on the way in rather than on the way out. A whole
    /// sentence here because a read failure is shown on its own, under a
    /// heading, rather than appended to one.
    static func reading(_ failure: String) -> String {
        let text = failure.lowercased()
        if text.contains("locked") || text.contains("busy") {
            return "The games file was busy. Try again in a moment."
        }
        if text.contains("malformed") || text.contains("corrupt") || text.contains("sqlite error 11") {
            return "The games file is damaged, so this game cannot be read back."
        }
        return "The games file could not be read."
    }
}

private struct SummaryNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(text)
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}

// MARK: - Model

/// Watches the game's analysis land.
///
/// The pass is queued by `GameSession` as the game finishes and runs at the
/// engine's lowest priority, so the numbers genuinely are not available when
/// this screen first appears. Polling rather than a stream because the analysis
/// service's progress feed is per-pass and process-wide, while this screen only
/// cares about one game's row — a 2-second read of two indexed tables is
/// cheaper than the plumbing to observe it properly, and it stops the moment
/// the pass reaches a terminal state.
@Observable
@MainActor
final class GameSummaryModel {

    private(set) var accuracy: Double?
    private(set) var momentCount: Int?
    private(set) var analysisState: AnalysisState?
    /// The live pass, when the engine is available to be asked. `nil` leaves the
    /// caption on its unpriced fallback rather than inventing a ply count.
    private(set) var progress: AnalysisProgress?

    private let gameID: UUID
    private let database: AppDatabase?

    init(gameID: UUID, database: AppDatabase? = AppDatabase.sharedIfAvailable) {
        self.gameID = gameID
        self.database = database
    }

    /// Polls the row, and follows the pass itself when there is an engine to ask.
    ///
    /// Both, not one: the stream carries the ply counts the caption needs but
    /// only for a pass running in *this* launch, while the row is the only thing
    /// that knows a game analysed an hour ago is already done.
    func track(engineService: EngineService? = nil) async {
        let follower = engineService.map { service in
            Task { await self.follow(engineService: service) }
        }
        defer { follower?.cancel() }
        await poll(engineService: engineService)
    }

    /// How many two-second ticks a game may sit `pending` before the queue is
    /// nudged again.
    ///
    /// The nudge is cheap — `analyzePending` returns immediately when a drain is
    /// already in flight — but it does try to take an engine lease, and doing
    /// that every two seconds would have the summary screen fighting whatever
    /// preempted it. Twenty seconds is long enough to stay out of the way and
    /// short enough that nobody watches a stalled queue for a minute.
    private static let pendingTicksBeforeRetry = 10

    private func poll(engineService: EngineService?) async {
        var pendingTicks = 0
        while !Task.isCancelled {
            await refresh()
            if analysisState == .complete || analysisState == .failed { return }

            // `pending` here means the row is in the queue and nothing is
            // working on it — the state a preempted pass is left in. The first
            // tick nudges immediately because the common cause is a probe lease
            // taken at the very moment the game ended.
            if analysisState == .pending {
                if pendingTicks % Self.pendingTicksBeforeRetry == 0 {
                    resumeAnalysis(engineService: engineService)
                }
                pendingTicks += 1
            } else {
                pendingTicks = 0
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Asks the queue to run, if this game is still waiting in it.
    ///
    /// Covers the one gap `AppModel.handleForegrounding` cannot: a pass preempted
    /// by a higher-priority engine claim while the user never leaves the app sits
    /// `pending` with nobody to pump it, and this screen is where they are
    /// waiting. Foregrounding and thermal recovery are handled at the app level
    /// and must not be duplicated here — that hook guards on `bootState`, and
    /// draining before the engine has started marks every queued game failed.
    ///
    /// Addressed at the queue rather than at this game, deliberately: the games
    /// ahead of it are waiting for the same engine, and analysing out of order
    /// would leave the older ones behind forever. A game already running, failed
    /// or complete is left alone — `analyzePending` only ever picks up rows still
    /// marked pending, and a second caller while a drain is in flight is a
    /// no-op inside the service.
    ///
    /// The drain is deliberately not awaited. It runs for as long as the pass
    /// takes, and this screen has to keep polling while it does; it also has to
    /// outlive the screen, because the analysis should finish whether or not the
    /// user is still looking at the summary.
    func resumeAnalysis(engineService: EngineService?) {
        guard let engineService, analysisState == nil || analysisState == .pending else { return }
        Task {
            guard let service = AnalysisService.shared(engineService: engineService) else { return }
            await service.analyzePending()
        }
    }

    private func follow(engineService: EngineService) async {
        guard let service = AnalysisService.shared(engineService: engineService) else { return }
        for await update in service.progress() {
            guard update.gameID == gameID else { continue }
            progress = update
            // The row is written before the terminal update is emitted, so a
            // read here lands on the finished numbers rather than racing the
            // next two-second tick for them.
            if update.isTerminal { await refresh() }
        }
    }

    private func refresh() async {
        guard let database else { return }
        let id = gameID

        let snapshot = await Task.detached(priority: .utility) { () -> Snapshot? in
            guard let game = try? database.games.game(id: id) else { return nil }
            // Capped at what the review can show. The filmstrip is three cards
            // chosen by score, so a fourth stored moment is a number the next
            // screen cannot honour — and the CTA under this one prices the same
            // slice, as does Today's review step. One predicate, three screens.
            let moments = (try? database.moments.moments(forGame: id))
                .map { min($0.count, ReviewMomentCards.limit) }
            return Snapshot(
                accuracy: game.userAccuracy,
                analysisState: game.analysis,
                momentCount: game.analysis == .complete ? (moments ?? 0) : nil
            )
        }.value

        guard let snapshot else { return }
        accuracy = snapshot.accuracy
        analysisState = snapshot.analysisState
        momentCount = snapshot.momentCount
    }

    private struct Snapshot: Sendable {
        var accuracy: Double?
        var analysisState: AnalysisState?
        var momentCount: Int?
    }
}

#Preview("Summary") {
    NavigationStack {
        GameSummaryScreen(
            target: GameSummaryTarget(
                gameID: UUID(),
                outcome: .init(result: "1-0", termination: "checkmate", userWon: true),
                opponentName: "Oscar",
                opponentRating: 1050,
                plyCount: 61
            )
        )
    }
}
