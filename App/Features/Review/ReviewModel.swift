import AnalysisKit
import BoardUI
import ChessKit
import Database
import Foundation
import Observation
import SwiftUI

// MARK: - Model

/// Everything the Review screen shows, loaded once and then navigated locally.
///
/// The whole game is read into memory up front — a 120-ply game is a few hundred
/// kilobytes of positions — because scrubbing must be instant. Re-reading the
/// database on every drag tick would put SQLite in the gesture loop.
@Observable
@MainActor
final class ReviewModel {

    enum LoadState: Equatable {
        case loading
        case ready
        case missing
        case failed(String)
    }

    // MARK: Identity

    let gameID: UUID

    // MARK: Loaded state

    private(set) var loadState: LoadState = .loading
    private(set) var game: Database.Game?
    private(set) var timeline = ReviewTimeline(moveRows: [])
    private(set) var track = ReviewEvalTrack()
    private(set) var moveRows: [ReviewMoveRow] = []
    private(set) var momentCards: [ReviewMomentCard] = []
    private(set) var phaseSegments: [ReviewPhaseSegment] = []
    /// Mean accuracy over the user's other recent games. `nil` on the first one.
    private(set) var accuracyAverage: Double?

    // MARK: Navigation

    /// Position index (0 = starting position). The single source of truth for
    /// the board, the scrubber marker and the move-list highlight.
    private(set) var selectedIndex = 0
    private(set) var orientation: Piece.Color = .white
    /// Moment whose card is stroked in the filmstrip, if the board is standing on
    /// one. Cleared as soon as the user scrubs elsewhere.
    private(set) var activeMomentID: UUID?

    // MARK: Coach

    /// The read on the whole game. Written by the same pass that wrote the
    /// moments, so it is either on screen from the first frame or not at all —
    /// see ``ReviewVerdicts/verdict(game:moves:moments:cards:)`` for the cases
    /// that leave it nil.
    private(set) var verdict: GameSummary?

    private var suggestedQuestions: [UUID: [ReviewSuggestedQuestion]] = [:]

    // MARK: Self-check

    /// The questions asked before the engine's read is uncovered. Empty when
    /// the game has already been reviewed, or when the analysis has not run and
    /// there is therefore nothing to mark against.
    private(set) var selfCheckQuestions: [ReviewSelfCheck.Question] = []
    private(set) var selfCheckIndex = 0
    private(set) var selfCheckAnswers: [String: Int] = [:]
    /// The current answer is on screen and marked; the next tap moves on.
    private(set) var selfCheckRevealed = false
    private(set) var selfCheckFinished = false

    /// Whether the verdict, the filmstrip and the coaching are still covered.
    var isSelfCheckActive: Bool { !selfCheckFinished && !selfCheckQuestions.isEmpty }

    var selfCheckQuestion: ReviewSelfCheck.Question? {
        guard isSelfCheckActive, selfCheckIndex < selfCheckQuestions.count else { return nil }
        return selfCheckQuestions[selfCheckIndex]
    }

    var selfCheckScore: Int {
        ReviewSelfCheck.score(questions: selfCheckQuestions, answers: selfCheckAnswers)
    }

    /// Records an answer and marks it.
    ///
    /// The board jumps to the move the user named, right or wrong: the point of
    /// the exercise is to attach a judgement to a position, and marking it in
    /// the abstract while the board shows the final move teaches nothing.
    func answerSelfCheck(_ option: Int) {
        guard let question = selfCheckQuestion, !selfCheckRevealed,
            question.options.indices.contains(option)
        else { return }

        selfCheckAnswers[question.id] = option
        selfCheckRevealed = true
        if let ply = question.options[option].ply {
            select(index: max(0, ply - 1))
        }
    }

    func advanceSelfCheck() {
        guard selfCheckRevealed else { return }
        selfCheckRevealed = false
        if selfCheckIndex + 1 < selfCheckQuestions.count {
            selfCheckIndex += 1
        } else {
            finishSelfCheck()
        }
    }

    /// Gives up on the questions and uncovers the review.
    ///
    /// Skipping still writes a score — of whatever was answered before the
    /// user stopped. A game whose questions were skipped is reviewed as far as
    /// this screen is concerned; re-asking them on the next open would make the
    /// screen feel like it was arguing.
    func skipSelfCheck() { finishSelfCheck() }

    private func finishSelfCheck() {
        guard !selfCheckFinished else { return }
        selfCheckFinished = true

        guard let database else { return }
        let id = gameID
        let score = selfCheckScore
        Task.detached(priority: .utility) {
            try? database.games.setSelfCheckScore(score, forGame: id)
        }
    }

    /// Moments this screen has not counted as read yet.
    ///
    /// Seeded from the stored status, so a moment worked through last week is
    /// not counted again when the game is reopened.
    private var unreviewedMomentIDs: Set<UUID> = []

    private let database: AppDatabase?

    init(gameID: UUID, database: AppDatabase? = AppDatabase.sharedIfAvailable) {
        self.gameID = gameID
        self.database = database
    }

    // MARK: - Loading

    func load() async {
        guard case .loading = loadState else { return }
        await reload()
    }

    func reload() async {
        guard let database else {
            loadState = .failed("The games database could not be opened.")
            return
        }

        let id = gameID
        let outcome = await Task.detached(priority: .userInitiated) { () -> ReviewLoadOutcome in
            // Repositories are synchronous `Sendable` structs over a serialised
            // GRDB writer, so the only reason this hops off the main actor is to
            // keep a few milliseconds of SQLite out of the first frame. The error
            // is reduced to a string here because `any Error` is not `Sendable`
            // and would not survive the hop back.
            do {
                guard let snapshot = try ReviewSnapshot.load(gameID: id, database: database) else {
                    return .missing
                }
                return .loaded(snapshot)
            } catch {
                return .failed(String(describing: error))
            }
        }.value

        switch outcome {
        case .failed(let message):
            loadState = .failed(message)
        case .missing:
            loadState = .missing
        case .loaded(let snapshot):
            apply(snapshot)
            loadState = .ready
        }
    }

    /// Maps the review's own rows into the shape the check is written against.
    ///
    /// `byUser` is derived from the colour rather than stored, because a move
    /// row knows which side played it and the game knows which side is the
    /// user, and a third copy of that fact is a third chance to disagree.
    private static func selfCheckInput(
        snapshot: ReviewSnapshot,
        moveRows: [ReviewMoveRow]
    ) -> ReviewSelfCheck.Input {
        let userIsWhite = snapshot.game.color != .black
        let thinkTimes = Dictionary(
            snapshot.moves.map { ($0.ply, $0.thinkTimeMs) },
            uniquingKeysWith: { first, _ in first }
        )

        return ReviewSelfCheck.Input(
            moves: moveRows.map { row in
                ReviewSelfCheck.Input.Move(
                    ply: row.ply,
                    label: row.label,
                    byUser: row.isWhite == userIsWhite,
                    thinkTimeMs: thinkTimes[row.ply] ?? 0
                )
            },
            moments: snapshot.moments.map {
                ReviewSelfCheck.Input.Moment(ply: $0.ply, causeTag: $0.causeTag)
            }
        )
    }

    private func apply(_ snapshot: ReviewSnapshot) {
        game = snapshot.game
        orientation = snapshot.game.color == .black ? .black : .white
        accuracyAverage = snapshot.accuracyAverage

        timeline = ReviewTimeline(moveRows: snapshot.moves)
        track = ReviewEvalTrack.build(
            evals: snapshot.evals,
            moveRows: snapshot.moves,
            positionCount: timeline.positionCount
        )
        momentCards = ReviewMomentCards.cards(
            moments: snapshot.moments,
            orientation: orientation,
            moveRows: snapshot.moves
        )
        moveRows = ReviewMoveRows.rows(
            moveRows: snapshot.moves,
            track: track,
            momentPlies: Set(snapshot.moments.map(\.ply))
        )
        phaseSegments = ReviewPhases.segments(timeline: timeline)

        // Only for a game that has been analysed and not yet reviewed. Asking
        // before the analysis has run would mark the answers against moments
        // that do not exist yet, so every question would score "nothing went
        // wrong" on a game the user may well have lost badly.
        if snapshot.game.selfCheckScore == nil, snapshot.game.analysis == .complete {
            selfCheckQuestions = ReviewSelfCheck.questions(
                for: Self.selfCheckInput(snapshot: snapshot, moveRows: moveRows)
            )
        } else {
            selfCheckQuestions = []
        }

        verdict = ReviewVerdicts.verdict(
            game: snapshot.game,
            moves: snapshot.moves,
            moments: snapshot.moments,
            cards: momentCards
        )

        suggestedQuestions = ReviewSuggestedQuestions.byMoment(
            moments: snapshot.moments,
            cards: momentCards,
            rung: snapshot.rung
        )

        unreviewedMomentIDs = Set(
            snapshot.moments.filter { $0.momentStatus == .new }.map(\.id)
        )

        // Open on the first moment when there is one: the reason to reopen a game
        // is almost never move 1.
        if let first = momentCards.first {
            select(momentID: first.id)
        } else {
            select(index: 0)
        }
    }

    // MARK: - Derived

    var analysisState: AnalysisState { game?.analysis ?? .pending }
    var accuracy: Double? { game?.userAccuracy }

    var position: Position { timeline.position(at: selectedIndex) }
    var highlights: [SquareHighlight] { timeline.highlights(at: selectedIndex) }

    /// White-relative win percentage at the current position, for the eval bar.
    var whiteWinPercent: Double? { track.whiteWinPercent[selectedIndex] }
    var whiteMate: Int? { track.whiteMate[selectedIndex] }

    /// Ply of the move that produced the current position, if any.
    var currentPly: Int? { selectedIndex > 0 ? selectedIndex : nil }

    var momentPlies: Set<Int> { Set(momentCards.map(\.ply)) }

    /// Blunders and mistakes among the user's own moves.
    ///
    /// Inaccuracies are left out on purpose: every game has a handful, so
    /// including them turns a number that should sting into background noise.
    var userMistakeCount: Int {
        let userIsWhite = game?.color != .black
        return moveRows.filter { row in
            row.isWhite == userIsWhite && (row.chip == .mistake || row.chip == .blunder)
        }.count
    }

    func card(withID id: UUID) -> ReviewMomentCard? {
        momentCards.first { $0.id == id }
    }

    /// The card the coach panel is talking about: whichever moment the board is
    /// standing on, and nothing when it is standing between them.
    var focusedCard: ReviewMomentCard? {
        activeMomentID.flatMap(card(withID:))
    }

    /// Position of a card in the strip, 1-based, for the `2/3` counter.
    func momentOrdinal(of id: UUID) -> Int? {
        momentCards.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: - Navigation

    func select(index: Int) {
        selectedIndex = timeline.clamp(index)
        syncActiveMoment()
    }

    func select(momentID: UUID) {
        guard let card = card(withID: momentID) else { return }
        selectedIndex = timeline.clamp(card.positionIndex)
        activeMomentID = card.id
        markReviewed(momentID: card.id)
    }

    /// Keeps the filmstrip's stroke honest: it marks where the board is standing,
    /// not the last thing tapped.
    private func syncActiveMoment() {
        activeMomentID = momentCards.first { $0.positionIndex == selectedIndex }?.id
    }

    func stepForward() { select(index: selectedIndex + 1) }
    func stepBackward() { select(index: selectedIndex - 1) }
    func flipBoard() { orientation = orientation == .white ? .black : .white }

    // MARK: - Coach

    /// The questions a moment offers under its note.
    func suggestedQuestions(forMoment id: UUID) -> [ReviewSuggestedQuestion] {
        suggestedQuestions[id] ?? []
    }

    /// Records that the student has now worked through a moment.
    ///
    /// The bump lives here rather than with the analysis pass that writes the
    /// note, because writing a note is not reading one: a pass finishes on a
    /// game the user may never open, and ticking the day's "3 moments" off for
    /// that would make the streak a count of analysis runs.
    ///
    /// `MomentStatus` already names the event — `reviewed` means "shown to the
    /// user and worked through" — so the new → reviewed transition is both the
    /// trigger and the guard against double counting: the id leaves
    /// ``unreviewedMomentIDs`` before the write is dispatched, so re-selecting
    /// the card, reopening the game or syncing the row from another device
    /// counts nothing further.
    private func markReviewed(momentID: UUID) {
        guard unreviewedMomentIDs.remove(momentID) != nil, let database else { return }
        let day = DailyLoop.dayKey(for: Date())

        Task.detached(priority: .utility) {
            try? database.moments.setStatus(.reviewed, forMoment: momentID)
            // A separate write, deliberately: the daily loop is a streak
            // counter, and failing to bump it must never undo the status that
            // says this moment has been seen.
            _ = try? database.dailyLoop.update(day: day) { loop in
                loop.momentsReviewed += 1
            }
        }
    }

}

// MARK: - Snapshot

/// Result of one load hop. Not `Result`, because `any Error` is not `Sendable`
/// and this value crosses an actor boundary.
enum ReviewLoadOutcome: Sendable {
    case loaded(ReviewSnapshot)
    case missing
    case failed(String)
}

/// One read of everything the screen needs, so the load is a single hop.
struct ReviewSnapshot: Sendable {
    var game: Database.Game
    var moves: [GameMove]
    var moments: [Database.Moment]
    var evals: [PlyEval]
    /// The user's curriculum rung, which decides which habit a cause tag maps
    /// to — the same tag is a blunder-check problem at rung 1 and a move-choice
    /// problem above it.
    var rung: Int
    /// Mean accuracy over the user's recent games, for the comparison chip.
    /// `nil` until there is more than this game to compare against.
    var accuracyAverage: Double?

    /// How many finished games the comparison averages over. Small enough that
    /// it still describes how the user is playing *now*.
    static let comparisonWindow = 20

    static func load(gameID: UUID, database: AppDatabase) throws -> ReviewSnapshot? {
        guard let game = try database.games.game(id: gameID) else { return nil }

        // Everything below the game itself degrades rather than throws: a
        // missing evaluation table must not stop a game from opening, and a
        // comparison the app cannot compute is simply not shown.
        let recent = (try? database.games.recent(limit: comparisonWindow)) ?? []
        let others = recent.filter { $0.id != gameID }.compactMap(\.userAccuracy)

        return ReviewSnapshot(
            game: game,
            moves: try database.games.moves(forGame: gameID),
            moments: try database.moments.moments(forGame: gameID),
            evals: (try? database.games.evals(forGame: gameID)) ?? [],
            rung: (try? database.settings.current())?.currentRung ?? 1,
            accuracyAverage: others.isEmpty ? nil : others.reduce(0, +) / Double(others.count)
        )
    }
}
