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
    /// What this game's accuracy is worth comparing against. `nil` when there is
    /// no comparable set — see ``ReviewAccuracyReference``.
    private(set) var accuracyReference: ReviewAccuracyReference?

    // MARK: Navigation

    /// Position index (0 = starting position). The single source of truth for
    /// the board, the scrubber marker and the move-list highlight.
    private(set) var selectedIndex = 0
    private(set) var orientation: Piece.Color = .white
    /// The colour the reader actually played.
    ///
    /// Distinct from ``orientation``, which the flip control moves. Anything
    /// phrased as "you" — the axis label, the eval reading under the board —
    /// has to follow this one, or turning the board around would change who the
    /// screen thinks the reader is.
    private(set) var playedSide: Piece.Color = .white
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
    /// Skipping writes a score only when at least one question was answered. A
    /// score written for nothing is what made this control unforgiving: the
    /// stored score is the flag that stops the questions being built again, so
    /// one stray tap used to discard the exercise for that game permanently.
    /// Having answered and then stopped is a real judgement and is kept —
    /// re-asking those would make the screen feel like it was arguing.
    func skipSelfCheck() { finishSelfCheck() }

    private func finishSelfCheck() {
        guard !selfCheckFinished else { return }
        selfCheckFinished = true
        selfCheckResult = Self.resultLine(
            questions: selfCheckQuestions,
            answers: selfCheckAnswers
        )

        // The reveal has to land on something. The questions moved the board to
        // whichever move the user named, which is almost never a moment, so
        // without this the filmstrip uncovers with no ring, the counter reads
        // "—/3" and the coach card — the most valuable thing on the screen — is
        // simply absent until the user guesses to tap a thumbnail.
        if let first = momentCards.first { select(momentID: first.id) }

        guard let database, !selfCheckAnswers.isEmpty else { return }
        let id = gameID
        let score = selfCheckScore
        Task.detached(priority: .utility) {
            try? database.games.setSelfCheckScore(score, forGame: id)
        }
    }

    /// What the questions came to, shown once they are done.
    ///
    /// The point of asking before the engine speaks is to find out which of your
    /// own judgements to trust; a score that is recorded and never shown cannot
    /// do that. Names the move that was missed when there is one, because "2 of
    /// 3" alone does not tell anyone what to look at.
    private(set) var selfCheckResult: String?

    nonisolated static func resultLine(
        questions: [ReviewSelfCheck.Question],
        answers: [String: Int]
    ) -> String? {
        guard !questions.isEmpty, !answers.isEmpty else { return nil }

        let score = ReviewSelfCheck.score(questions: questions, answers: answers)
        var line = "Before the engine: \(score) of \(questions.count)"

        let missed = questions.first { question in
            guard let answer = answers[question.id] else { return false }
            return answer != question.correct
        }
        if let missed, missed.answer.ply != nil {
            line += " · you missed \(missed.answer.label)"
        }

        let unanswered = questions.filter { answers[$0.id] == nil }.count
        if unanswered > 0 { line += " · \(unanswered) skipped" }
        return line
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

    /// How often the row is re-read while a pass is still outstanding.
    static let analysisPollInterval = Duration.seconds(2)

    /// Re-reads the game once the post-game pass settles.
    ///
    /// Without this the screen loaded exactly once. Opening the review a few
    /// seconds after a game — the most common path there is — landed on a notice
    /// promising the curve would fill in, and it never did: no moments, no
    /// self-check, no verdict, until the user backed out and came in again.
    ///
    /// Only a *settled* pass is worth redrawing for. Reloading on every tick
    /// would rebuild the timeline and the questions under a user who is
    /// scrubbing, which is a worse screen than a stale one.
    func followAnalysis(interval: Duration = analysisPollInterval) async {
        guard let database else { return }
        let id = gameID

        while !Task.isCancelled {
            guard analysisState == .pending || analysisState == .running else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }

            let state = await Task.detached(priority: .utility) { () -> AnalysisState? in
                ((try? database.games.game(id: id)) ?? nil)?.analysis
            }.value

            guard let state, state != analysisState else { continue }
            await reload()
            return
        }
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
            // The GRDB description is the only useful thing anyone debugging
            // this will have, so it goes to the log; the screen gets a sentence
            // a player can act on instead of "SQLite error 13".
            AppLog.persistence.error("Could not read game \(id.uuidString, privacy: .public): \(message, privacy: .public)")
            loadState = .failed(StorageFailureText.reading(message))
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
                    thinkTimeMs: thinkTimes[row.ply] ?? 0,
                    // The row's own chip, which is the classification analysis
                    // wrote for *every* ply. The slate is capped at three, so
                    // this is the only thing that knows about the mistakes that
                    // did not make it — and the check needs it to keep them out
                    // of the decoys rather than mark them wrong.
                    isJudgedMistake: row.chip == .mistake || row.chip == .blunder
                )
            },
            moments: snapshot.moments.map { moment in
                ReviewSelfCheck.Input.Moment(
                    ply: moment.ply,
                    causeTag: moment.causeTag,
                    refutationSAN: ReviewSuggestedQuestions.refutationSAN(for: moment)
                )
            }
        )
    }

    private func apply(_ snapshot: ReviewSnapshot) {
        game = snapshot.game
        playedSide = snapshot.game.color == .black ? .black : .white
        orientation = playedSide
        accuracyReference = snapshot.accuracyReference

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
        // Grades rather than plies, so a row and the filmstrip card above it
        // cannot disagree about what the same move was: both take the badge from
        // ``ReviewMomentCards/classification(for:)``.
        moveRows = ReviewMoveRows.rows(
            moveRows: snapshot.moves,
            track: track,
            momentGrades: snapshot.moments.reduce(into: [:]) { grades, moment in
                grades[moment.ply] = ReviewMomentCards.classification(for: moment)
            }
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
        // is almost never move 1. Seeding the selection is not reviewing it —
        // see ``markReviewed(momentID:)`` for what counts.
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

    /// "Am I winning here?" for the position on screen, in the reader's terms.
    /// `nil` where nothing has been evaluated yet.
    var evalReading: String? {
        ReviewEvalReading.phrase(
            whiteWinPercent: whiteWinPercent,
            whiteMate: whiteMate,
            playedSide: playedSide
        )
    }

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

    /// Answers the reader has uncovered, by suggestion id.
    ///
    /// Held here rather than inside the card because one of these answers is
    /// drawn on the *board*, which the card does not own. Keyed by suggestion id
    /// — which carries the moment's id — so scrubbing away and back finds the
    /// same chip open, and a different moment's chips closed.
    private(set) var revealedSuggestionIDs: Set<String> = []

    func toggleSuggestion(id: String) {
        if revealedSuggestionIDs.remove(id) == nil { revealedSuggestionIDs.insert(id) }
    }

    /// The engine's move, drawn on the board while its answer is uncovered.
    ///
    /// Only for the moment the board is actually standing on: an arrow pointing
    /// at a move that was available eleven plies ago is worse than no arrow. The
    /// answer names the move in SAN and the board shows it on the squares, which
    /// is the difference between being told "Re8" and seeing what Re8 does.
    var boardArrows: [BoardArrow] {
        guard let card = focusedCard else { return [] }
        return suggestedQuestions(forMoment: card.id).compactMap { suggestion in
            guard
                revealedSuggestionIDs.contains(suggestion.id),
                let uci = suggestion.arrowUCI,
                uci.count >= 4
            else { return nil }
            let characters = Array(uci)
            return BoardArrow(
                from: Square(String(characters[0...1])),
                to: Square(String(characters[2...3])),
                style: .best
            )
        }
    }

    /// Records that the student has now worked through a moment.
    ///
    /// The bump lives here rather than with the analysis pass that writes the
    /// note, because writing a note is not reading one: a pass finishes on a
    /// game the user may never open, and ticking the day's "3 moments" off for
    /// that would make the streak a count of analysis runs.
    ///
    /// For the same reason it is not called by ``select(momentID:)``. Selecting
    /// is what opening the screen does on its own, and what a thumbnail tap
    /// does; counting either turned "Review 3 moments" into two taps on a
    /// filmstrip that was not even on screen yet. The caller is the coach card,
    /// on the tap that uncovers the answer — the one act on this screen that
    /// requires the reader to have looked at the position first.
    ///
    /// `MomentStatus` already names the event — `reviewed` means "shown to the
    /// user and worked through" — so the new → reviewed transition is both the
    /// trigger and the guard against double counting: the id leaves
    /// ``unreviewedMomentIDs`` before the write is dispatched, so re-selecting
    /// the card, reopening the game or syncing the row from another device
    /// counts nothing further.
    func markReviewed(momentID: UUID) {
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

/// What this game's accuracy is compared against, and how big that set is.
///
/// The count travels with the average because a chip that says only "your avg
/// 66%" is a number with no sample size, and a caret drawn off three games is
/// noise wearing a trend's clothes. The screen names both.
struct ReviewAccuracyReference: Sendable, Equatable {
    var average: Double
    var count: Int
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
    /// The comparison the chip is entitled to draw, or `nil` when there is not
    /// enough comparable history to draw one.
    var accuracyReference: ReviewAccuracyReference?

    /// How many finished games the comparison looks back over. Small enough that
    /// it still describes how the user is playing *now*.
    static let comparisonWindow = 20

    /// How far apart two opponents' ratings can be and still be the same test.
    ///
    /// Accuracy against a 900 and accuracy against a 1500 are not the same
    /// measurement: the weaker opponent leaves far more positions with one
    /// obvious move in them, and tracking the engine there is easier. Averaging
    /// across the whole history made the chip partly a record of who the app had
    /// been pairing the user with, which is not a thing they can practise.
    static let comparableRatingBand = 150

    /// Below this the average is one bad evening rather than a baseline, and the
    /// honest chip is no chip.
    static let minimumComparableGames = 5

    static func load(gameID: UUID, database: AppDatabase) throws -> ReviewSnapshot? {
        guard let game = try database.games.game(id: gameID) else { return nil }

        // Everything below the game itself degrades rather than throws: a
        // missing evaluation table must not stop a game from opening, and a
        // comparison the app cannot compute is simply not shown.
        let recent = (try? database.games.recent(limit: comparisonWindow)) ?? []
        let comparable = recent
            .filter {
                $0.id != gameID
                    && abs($0.opponentRating - game.opponentRating) <= comparableRatingBand
            }
            .compactMap(\.userAccuracy)

        return ReviewSnapshot(
            game: game,
            moves: try database.games.moves(forGame: gameID),
            moments: try database.moments.moments(forGame: gameID),
            evals: (try? database.games.evals(forGame: gameID)) ?? [],
            rung: (try? database.settings.current())?.currentRung ?? 1,
            accuracyReference: comparable.count >= minimumComparableGames
                ? ReviewAccuracyReference(
                    average: comparable.reduce(0, +) / Double(comparable.count),
                    count: comparable.count
                )
                : nil
        )
    }
}
