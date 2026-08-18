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
    private(set) var isLoading = false
    /// Set when the corpus has nothing left in band.
    private(set) var exhausted = false

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
        case .retry, .failed:
            apply(outcome: outcome, probe: probe, played: uci)
            return .rejected(reason: nil)
        case .advanced, .solved:
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
            onResult(currentRating, true)
        case .failed, .retry:
            ring = PuzzleConcept.destination(ofUCI: played).map { BoardRing(square: $0, tone: .wrong) }
            if case .failed = outcome { onResult(currentRating, false) }
        case .illegal:
            break
        }
    }

    private func isPromotion(from: Square, to: Square, in position: Position) -> Bool {
        guard let piece = position.piece(at: from), piece.kind == .pawn else { return false }
        return to.rank.value == 8 || to.rank.value == 1
    }
}

/// The puzzle half of calibration.
///
/// No hints, no second try, no result banner. The same argument as the games:
/// anything that helps the user solve a puzzle they would otherwise have missed
/// is a contaminant in a measurement, and a banner between every item would turn
/// twenty quick puzzles into twenty interruptions.
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
                ContentUnavailableView {
                    Label("Not enough puzzles", systemImage: "square.grid.3x3")
                } description: {
                    Text("The corpus ran out at this difficulty.")
                }
            } else if let position = runner.position {
                BoardView(
                    position: displayedPosition(fallback: position),
                    orientation: runner.orientation,
                    interaction: interaction
                )
                .overlay {
                    BoardAnnotationOverlay(orientation: runner.orientation, ring: runner.ring)
                }
                .padding(.horizontal, 12)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        // Keyed on the puzzle count so each recorded result loads the next item.
        .task(id: flow.puzzles.count) { await advance() }
    }

    private func advance() async {
        // A short beat so the ring on the last move is visible before the board
        // is replaced. Without it a correct answer and the next position arrive
        // on the same frame and the feedback is never seen.
        if flow.puzzles.count > 0 {
            try? await Task.sleep(for: .milliseconds(550))
        }
        guard !flow.progress.isComplete else { return }
        await runner.loadPuzzle(rating: flow.puzzleRating)
        await playSetupMove()
    }

    private func displayedPosition(fallback: Position) -> Position {
        if isPlayingSetupMove, let preview = runner.setupPreview { return preview.position }
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
