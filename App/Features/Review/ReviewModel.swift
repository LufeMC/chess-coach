import AnalysisKit
import BoardUI
import ChessKit
import Database
import Foundation
import Observation
import SwiftUI

// MARK: - Coach plumbing

/// A question put to the coach about one position.
///
/// A value rather than a closure argument list so the eventual coach service can
/// grow context (the PV, the cause tag, the user's rung) without touching the
/// Review screen.
struct ReviewCoachRequest: Sendable, Hashable {
    var gameID: UUID
    var focus: ReviewCoachFocus
    /// Position *before* the move under discussion.
    var fen: String
    var playedSAN: String
    var bestSAN: String
    /// Set when the user asked something specific rather than opening a moment.
    var question: String?
}

/// What the coach panel is talking about right now.
enum ReviewCoachFocus: Sendable, Hashable {
    case moment(UUID)
    /// A move the user selected in the table and asked about.
    case question(ply: Int)
}

/// Generates coaching prose.
///
/// Deliberately a protocol the screen does not implement. Coach generation is a
/// network call with an API key, a cost and a failure mode, and none of that
/// belongs in a view model — the Review screen only knows how to *ask*.
protocol ReviewCoachProvider: Sendable {
    func note(for request: ReviewCoachRequest) async throws -> String
}

/// The coach card's state machine. `unavailable` is a normal, non-error state:
/// no API key, generation never ran, or the note simply was not persisted.
enum ReviewCoachState: Equatable {
    case unavailable
    case generating(label: String)
    case ready(String)
    case failed(String)
}

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

    // MARK: Navigation

    /// Position index (0 = starting position). The single source of truth for
    /// the board, the scrubber marker and the move-list highlight.
    private(set) var selectedIndex = 0
    private(set) var orientation: Piece.Color = .white
    /// Moment whose card is stroked in the filmstrip, if the board is standing on
    /// one. Cleared as soon as the user scrubs elsewhere.
    private(set) var activeMomentID: UUID?
    /// Move row the user tapped, which is what "Ask about this move" anchors to.
    var selectedRowPly: Int?

    // MARK: Coach

    /// Set by whoever owns coach generation. Nil is the shipped state today.
    var coachProvider: ReviewCoachProvider?
    private(set) var coachStates: [ReviewCoachFocus: ReviewCoachState] = [:]
    private(set) var coachFocus: ReviewCoachFocus?

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

    private func apply(_ snapshot: ReviewSnapshot) {
        game = snapshot.game
        orientation = snapshot.game.color == .black ? .black : .white

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

        // A persisted note is a finished note. Anything without one renders as no
        // card at all rather than as an error, because "no API key" is a
        // perfectly ordinary way to run this app.
        coachStates = momentCards.reduce(into: [:]) { states, card in
            states[.moment(card.id)] = card.coachText.map(ReviewCoachState.ready) ?? .unavailable
        }

        // Open on the first moment when there is one: the reason to reopen a game
        // is almost never move 1.
        if let first = momentCards.first {
            select(index: first.positionIndex)
            coachFocus = .moment(first.id)
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

    func card(withID id: UUID) -> ReviewMomentCard? {
        momentCards.first { $0.id == id }
    }

    func coachState(for focus: ReviewCoachFocus) -> ReviewCoachState {
        coachStates[focus] ?? .unavailable
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
        coachFocus = .moment(card.id)
        selectedRowPly = nil
    }

    func selectRow(ply: Int) {
        selectedRowPly = ply
        select(index: ply)
    }

    /// Keeps the filmstrip's stroke honest: it marks where the board is standing,
    /// not the last thing tapped.
    private func syncActiveMoment() {
        activeMomentID = momentCards.first { $0.positionIndex == selectedIndex }?.id
        if let activeMomentID { coachFocus = .moment(activeMomentID) }
    }

    func stepForward() { select(index: selectedIndex + 1) }
    func stepBackward() { select(index: selectedIndex - 1) }
    func flipBoard() { orientation = orientation == .white ? .black : .white }

    // MARK: - Coach

    /// Asks for a note about a moment. No-op when one is already present.
    func requestCoachNote(for card: ReviewMomentCard) {
        if case .ready = coachState(for: .moment(card.id)) { return }
        generate(
            focus: .moment(card.id),
            label: "Analyzing move \(card.moveNumber)…",
            fen: card.thumbnail.position.fen,
            playedSAN: card.playedSAN,
            bestSAN: card.bestSAN,
            question: nil
        )
    }

    /// The "Ask about this move" affordance on a move row.
    ///
    /// Pushes a targeted question at the coach panel. With no provider wired the
    /// panel says so; it never invents an answer, because a plausible-sounding
    /// fabricated explanation of a chess position is worse than no explanation.
    func askAboutMove(ply: Int) {
        let focus = ReviewCoachFocus.question(ply: ply)
        selectedRowPly = ply
        // Move the board first: `select(index:)` re-derives the coach focus from
        // whatever moment the board lands on, and an explicit question has to
        // outrank that.
        select(index: ply)
        coachFocus = focus

        let moveNumber = (ply + 1) / 2
        let san = timeline.sanByPly[ply] ?? ""
        generate(
            focus: focus,
            label: "Analyzing move \(moveNumber)…",
            fen: timeline.position(at: ply - 1).fen,
            playedSAN: san,
            bestSAN: "",
            question: "Why is \(san) the wrong idea here, and what should I have looked at first?"
        )
    }

    private func generate(
        focus: ReviewCoachFocus,
        label: String,
        fen: String,
        playedSAN: String,
        bestSAN: String,
        question: String?
    ) {
        guard let coachProvider else {
            // TODO: back this with `CoachCoordinator` (App/Services/Coach). Its
            // `coachStream(_:)` already emits `.partial` fragments, which maps onto
            // `.generating` → `.ready` without changing anything here; what is
            // missing is a `CoachRequestBuilder.Inputs` for a *single* position
            // (it currently builds a whole-game pass) and an owner for the
            // coordinator's lifetime. Until then this is an honest dead end rather
            // than a canned string: `unavailable` renders as "no card".
            coachStates[focus] = .unavailable
            return
        }

        let request = ReviewCoachRequest(
            gameID: gameID,
            focus: focus,
            fen: fen,
            playedSAN: playedSAN,
            bestSAN: bestSAN,
            question: question
        )

        coachStates[focus] = .generating(label: label)
        Task { [weak self] in
            do {
                let text = try await coachProvider.note(for: request)
                self?.coachStates[focus] = .ready(text)
            } catch {
                self?.coachStates[focus] = .failed(String(describing: error))
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

    static func load(gameID: UUID, database: AppDatabase) throws -> ReviewSnapshot? {
        guard let game = try database.games.game(id: gameID) else { return nil }
        return ReviewSnapshot(
            game: game,
            moves: try database.games.moves(forGame: gameID),
            moments: try database.moments.moments(forGame: gameID),
            // Local-only and regenerable; a missing table here must not stop the
            // game from opening, so evals degrade to an empty curve.
            evals: (try? database.games.evals(forGame: gameID)) ?? []
        )
    }
}
