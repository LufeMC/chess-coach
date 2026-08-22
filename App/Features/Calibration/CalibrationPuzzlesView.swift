//
//  CalibrationPuzzlesView.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import Database
import Observation
import SwiftUI
import TrainingCore

/// Serves the twenty calibration puzzles.
///
/// Reuses `PuzzleSolveMachine` rather than re-implementing the Lichess move
/// convention: the setup move belongs to the opponent, the line is played out in
/// full, and getting either wrong here would corrupt the measurement in a way
/// that is invisible until a user's whole curriculum is one rung off.
@MainActor
@Observable
final class CalibrationPuzzleRunner {

    private(set) var machine: PuzzleSolveMachine?
    /// Rating of the puzzle on screen, which is what the Glicko update is
    /// scored against.
    private(set) var currentRating: Int = 0
    private(set) var ring: BoardRing?
    /// The move that solves the puzzle, drawn after a miss.
    private(set) var answerArrow: (from: Square, to: Square)?
    /// Shown instead of the machine's position while feedback is on screen.
    private(set) var feedbackPosition: Position?
    /// One line under the board saying what happened, because a ring is a
    /// colour and a colour is not a channel every reader has.
    private(set) var feedbackText: String?
    private(set) var isLoading = false
    /// Set when the corpus has nothing left in band.
    private(set) var exhausted = false

    /// The expected move of the puzzle just missed, in UCI.
    private var missedAnswer: String?

    private var seen: Set<Puzzle.ID> = []
    private let corpus: any PuzzleCorpus
    private let onResult: @MainActor (Int, Bool) -> Void

    /// Half-width of the band a puzzle is drawn from. Wide enough that the
    /// corpus always has candidates, narrow enough that the rating the result is
    /// scored against is close to the one that was asked for.
    private let bandWidth = 150

    init(corpus: any PuzzleCorpus, onResult: @escaping @MainActor (Int, Bool) -> Void) {
        self.corpus = corpus
        self.onResult = onResult
    }

    var position: Position? { machine?.board.position }

    var orientation: Piece.Color { machine?.board.position.sideToMove ?? .white }

    /// The opponent's setup move, for the same pre-roll animation the training
    /// session uses.
    var setupPreview: (position: Position, from: Square, to: Square)? {
        guard
            let fen = pendingFEN,
            let line = pendingLine.first,
            let before = Position(fen: fen),
            let from = PuzzleConcept.origin(ofUCI: line),
            let to = PuzzleConcept.destination(ofUCI: line)
        else { return nil }
        return (before, from, to)
    }

    private var pendingFEN: String?
    private var pendingLine: [String] = []

    // MARK: Loading

    func loadPuzzle(rating: Int) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let low = max(0, rating - bandWidth)
        let high = rating + bandWidth
        let excluded = seen
        let source = corpus

        // Off the main actor: this is a SQLite query, and the board is on screen.
        let found = await Task.detached {
            (try? source.puzzles(
                ratingRange: low...high,
                themes: .empty,
                limit: 1,
                excluding: excluded
            )) ?? []
        }.value

        guard let puzzle = found.first else {
            exhausted = true
            machine = nil
            return
        }

        seen.insert(puzzle.id)
        currentRating = puzzle.rating
        pendingFEN = puzzle.fen
        pendingLine = puzzle.moveList
        ring = nil
        answerArrow = nil
        feedbackPosition = nil
        feedbackText = nil
        missedAnswer = nil

        var built = PuzzleSolveMachine(fen: puzzle.fen, line: puzzle.moveList)
        built?.start()
        machine = built

        // A line that will not replay is a corrupt row. Score nothing and try
        // the next one rather than charging the user for our data.
        if built == nil || built?.phase == .ready {
            await loadPuzzle(rating: rating)
        }
    }

    // MARK: Input

    func attemptMove(from: Square, to: Square, promotion: Piece.Kind? = nil) -> MoveAcceptance {
        guard let current = machine, !current.phase.isFinished else { return .rejected }

        if promotion == nil, isPromotion(from: from, to: to, in: current.board.position) {
            return .needsPromotion(complete: { [weak self] kind in
                self?.attemptMove(from: from, to: to, promotion: kind) ?? .rejected
            })
        }

        let uci = from.notation + to.notation + (promotion.map { $0.rawValue.lowercased() } ?? "")
        var probe = current
        let outcome = probe.play(uci: uci)

        switch outcome {
        case .illegal:
            return .rejected
        case .retry:
            apply(outcome: outcome, probe: probe, played: uci)
            return .rejected(reason: nil)
        // A wrong answer is *accepted* by the board and left standing. Rejecting
        // it plays the illegal-move snap-back — the piece flies home and the
        // origin square flashes — which is the board saying "not allowed" over a
        // move that was allowed and merely wrong. Two contradictory signals,
        // twenty times in a row.
        case .failed, .advanced, .solved:
            apply(outcome: outcome, probe: probe, played: uci)
            return .accepted
        }
    }

    private func apply(outcome: PuzzleSolveMachine.MoveResult, probe: PuzzleSolveMachine, played: String) {
        switch outcome {
        case .advanced:
            machine = probe
            ring = PuzzleConcept.destination(ofUCI: played).map { BoardRing(square: $0, tone: .correct) }
        case .solved:
            machine = probe
            ring = PuzzleConcept.destination(ofUCI: played).map { BoardRing(square: $0, tone: .correct) }
            feedbackText = "Solved."
            AccessibilityNotification.Announcement("Correct.").post()
            onResult(currentRating, true)
        case .failed(let expected):
            // The board keeps showing the move the user made, since the machine
            // itself did not take it: the position it holds is still the puzzle.
            if let current = machine {
                var attempted = current.board
                if PuzzleSolveMachine.apply(uci: played, to: &attempted) {
                    feedbackPosition = attempted.position
                }
            }
            // The failed machine is what closes the board for the beat the
            // answer is on screen. Without it a second drag lands on a puzzle
            // that has already been scored and scores it again.
            machine = probe
            ring = PuzzleConcept.destination(ofUCI: played).map { BoardRing(square: $0, tone: .wrong) }
            feedbackText = "Missed."
            missedAnswer = expected
            onResult(currentRating, false)
        case .retry:
            ring = PuzzleConcept.destination(ofUCI: played).map { BoardRing(square: $0, tone: .wrong) }
        case .illegal:
            break
        }
    }

    /// Holds the last answer on screen before the next puzzle replaces it.
    ///
    /// A solve needs a beat, or the ring and the next position arrive on the
    /// same frame and the feedback is never seen. A miss needs the answer: the
    /// result is recorded before this runs, so showing the move cannot
    /// contaminate the measurement, and twenty puzzles that never say what the
    /// move was is twenty items of teaching thrown away.
    func holdFeedback() async {
        guard let expected = missedAnswer, let current = machine else {
            try? await Task.sleep(for: .milliseconds(550))
            return
        }

        // Long enough to read the wrong move as wrong, before the board goes
        // back to the position and answers it.
        try? await Task.sleep(for: .milliseconds(900))

        let described = PuzzleReason.description(ofMove: expected, in: current.board.position)
        feedbackPosition = nil
        answerArrow = MovePair(uci: expected).map { ($0.from, $0.to) }
        ring = PuzzleConcept.destination(ofUCI: expected).map { BoardRing(square: $0, tone: .correct) }
        feedbackText = described.map { "Missed — the answer was \($0)." } ?? "Missed."
        AccessibilityNotification.Announcement(feedbackText ?? "Missed.").post()

        try? await Task.sleep(for: .milliseconds(1_600))
    }

    private func isPromotion(from: Square, to: Square, in position: Position) -> Bool {
        guard let piece = position.piece(at: from), piece.kind == .pawn else { return false }
        return to.rank.value == 8 || to.rank.value == 1
    }
}

/// The puzzle half of calibration.
///
/// No hints and no second try. The same argument as the games: anything that
/// helps the user solve a puzzle they would otherwise have missed is a
/// contaminant in a measurement.
///
/// The answer *after* the fact is a different matter. It arrives once the result
/// is already recorded, so it cannot contaminate anything, and without it twenty
/// puzzles at the user's exact level teach nothing at all — which is an hour of
/// the one thing this app is for, spent on measurement alone.
struct CalibrationPuzzlesView: View {

    let flow: CalibrationModel
    @State private var runner: CalibrationPuzzleRunner
    @State private var isPlayingSetupMove = false

    init(flow: CalibrationModel, corpus: any PuzzleCorpus) {
        self.flow = flow
        let model = flow
        _runner = State(
            initialValue: CalibrationPuzzleRunner(corpus: corpus) { rating, solved in
                model.record(puzzleRating: rating, solved: solved)
            }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            CalibrationHeader(progress: flow.progress)
                .padding(.horizontal)

            if runner.exhausted {
                exhausted
            } else {
                // Coming straight off five games, nothing on this screen says
                // what is being asked. The board animates one move and waits,
                // and "find the best move" is a guess the user should not have
                // to make twenty times.
                Text("\(runner.orientation == .white ? "White" : "Black") to move — find the best move")
                    .typeRole(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                if let position = runner.position {
                    CapturedTrayRow(perspective: runner.orientation, position: position)
                        .padding(.horizontal)
                }
                boardSlot
                feedbackLine
                    .padding(.horizontal)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        // Keyed on the puzzle count so each recorded result loads the next item.
        .task(id: flow.puzzles.count) { await advance() }
    }

    // MARK: Board

    @ViewBuilder
    private var boardSlot: some View {
        Group {
            if let position = runner.position {
                BoardView(
                    position: displayedPosition(fallback: position),
                    orientation: runner.orientation,
                    interaction: interaction,
                    style: BoardAppearance.shared.style
                )
                .overlay {
                    BoardAnnotationOverlay(
                        orientation: runner.orientation,
                        ring: runner.ring,
                        hint: runner.answerArrow
                    )
                }
            } else {
                EmptyBoardSlot()
            }
        }
        .skeleton(if: runner.position == nil) { BoardSkeleton() }
    }

    /// What just happened, in words.
    ///
    /// The rings are green and orange, which is one channel and the wrong one to
    /// rely on: the same two shapes in the same two positions read identically
    /// to a red/green colourblind reader. A space rather than nothing when there
    /// is no feedback, so the board never moves when a line appears.
    private var feedbackLine: some View {
        Text(runner.feedbackText ?? " ")
            .typeRole(.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(Motion.crossfade, value: runner.feedbackText)
    }

    // MARK: Running out

    /// The corpus has nothing left in band.
    ///
    /// This used to be a dead end, and on a screen that gates the entire app
    /// that is the worst bug available: a first-run user with a thin corpus at
    /// their difficulty could not reach Today at all. The games alone still
    /// produce an estimate — with an honestly wider sigma — so the way forward
    /// exists and only needed a button.
    ///
    /// Stated as a fact with a value, not as an illustrated failure. The
    /// measurement is not ruined; it is shorter than planned.
    private var exhausted: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("That's as far as the puzzles go")
                .typeRole(.headline)

            Text(
                "There are no more puzzles at your level on this device. Your \(flow.games.count) games and the puzzles you did answer carry the measurement between them — the rating just comes with a slightly wider margin."
            )
            .typeRole(.body, appliesForeground: false)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Show my rating") { flow.finish() }
                .buttonStyle(.primaryAction)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func advance() async {
        if flow.puzzles.count > 0 {
            await runner.holdFeedback()
        }
        guard !flow.progress.isComplete else { return }
        await runner.loadPuzzle(rating: flow.puzzleRating)
        await playSetupMove()
    }

    private func displayedPosition(fallback: Position) -> Position {
        if isPlayingSetupMove, let preview = runner.setupPreview { return preview.position }
        if let feedback = runner.feedbackPosition { return feedback }
        return fallback
    }

    private func playSetupMove() async {
        guard runner.setupPreview != nil else { return }
        isPlayingSetupMove = true
        try? await Task.sleep(for: .milliseconds(380))
        isPlayingSetupMove = false
    }

    private var interaction: BoardInteraction {
        guard !isPlayingSetupMove else { return .replay }
        return .userMove { from, to in
            runner.attemptMove(from: from, to: to)
        }
    }
}
