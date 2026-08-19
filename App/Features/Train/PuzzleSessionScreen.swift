//
//  PuzzleSessionScreen.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import SwiftUI

/// The solve surface: ten puzzles, one board, a banner between them.
struct PuzzleSessionScreen: View {

    @State private var model: PuzzleSessionModel
    @Environment(\.dismiss) private var dismiss

    /// True while the opponent's setup move is playing.
    ///
    /// The Lichess convention is that move 1 of the stored line belongs to the
    /// *opponent*: it is the move that creates the tactic. Dropping the user
    /// straight into the position after it is the classic puzzle-app mistake —
    /// they have to reconstruct what just happened before they can start. So the
    /// board opens on the stored FEN and the setup move animates in, which is
    /// also how a real game would have shown it to them.
    @State private var isPlayingSetupMove = false

    init(model: PuzzleSessionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.stage {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(message):
                unavailable(message)
            case .summary:
                SessionSummaryView(
                    progress: model.progress,
                    missed: model.missed,
                    onContinue: { dismiss() }
                )
            case .solving, .verdict:
                solving
            }
        }
        .task { await model.start() }
    }

    // MARK: Solving

    private var solving: some View {
        VStack(spacing: 12) {
            // A plain statement of the task, above the board rather than under
            // it: it is the first thing to read and the last thing to re-read,
            // and a board that starts at the top edge leaves the user hunting
            // for whose move it is.
            Text(model.taskLine)
                .typeRole(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            board
                .padding(.horizontal, 12)

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                SessionProgressBar(progress: model.progress)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: model.planOnScreen?.id) { await playSetupMove() }
    }

    private var board: some View {
        BoardView(
            position: displayedPosition,
            orientation: model.orientation,
            interaction: interaction,
            highlights: highlights,
            style: BoardAppearance.shared.style
        )
        .overlay {
            BoardAnnotationOverlay(
                orientation: model.orientation,
                ring: ring,
                hint: hintArrow,
                style: BoardAppearance.shared.style
            )
        }
    }

    /// The pre-setup position for the length of the animation, then the real one.
    private var displayedPosition: Position {
        if isPlayingSetupMove, let setup = model.setupMove { return setup.position }
        return model.position ?? .standard
    }

    private func playSetupMove() async {
        guard model.setupMove != nil else {
            isPlayingSetupMove = false
            return
        }
        isPlayingSetupMove = true
        // Long enough to read as a move rather than a jump cut, short enough
        // that ten of them do not add a minute to the session.
        try? await Task.sleep(for: .milliseconds(380))
        isPlayingSetupMove = false
    }

    private var interaction: BoardInteraction {
        guard case .solving = model.stage, !isPlayingSetupMove else { return .replay }
        return .userMove { from, to in
            model.attemptMove(from: from, to: to)
        }
    }

    /// The last move's wash, plus — after a miss — the answer's destination in
    /// `BoardUI`'s dashed green target.
    ///
    /// The dashed border is a state of its own rather than a louder version of
    /// the hint ring: "this was the answer" is what the user needs after they
    /// have already committed, and drawing it with the same solid ring the hint
    /// uses would make the two indistinguishable in memory a puzzle later. The
    /// user's own wrong square keeps its orange ring from
    /// ``BoardAnnotationOverlay`` — amber, never red, for the reason stated
    /// there — so the two marks never collide in shape or in colour.
    private var highlights: [SquareHighlight] {
        guard !isPlayingSetupMove else { return [] }

        var marks = model.lastOpponentMove.map { SquareHighlight.lastMove(from: $0.from, to: $0.to) } ?? []
        if case let .verdict(verdict) = model.stage,
            let answer = PuzzleConcept.destination(ofUCI: verdict.answer) {
            marks.append(SquareHighlight(answer, .correctAnswer))
        }
        return marks
    }

    private var ring: BoardRing? {
        if case let .verdict(verdict) = model.stage { return verdict.ring }
        return model.liveRing
    }

    /// The hint arrow while solving, and the answer arrow after a miss — the
    /// same thin grey arrow either way, because they are the same information.
    private var hintArrow: (from: Square, to: Square)? {
        let uci: String?
        if case let .verdict(verdict) = model.stage {
            uci = verdict.answer
        } else {
            uci = model.hintMove
        }
        guard let pair = MovePair(uci: uci) else { return nil }
        return (pair.from, pair.to)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if case let .verdict(verdict) = model.stage {
            ResultBanner(
                verdict: verdict,
                continueTitle: isLastItem ? "Finish" : "Next",
                onContinue: { model.continueAfterVerdict() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            solveActions
        }
    }

    private var isLastItem: Bool {
        model.progress.completed >= model.progress.displayTotal
    }

    private var solveActions: some View {
        HStack {
            Button {
                model.revealHint()
            } label: {
                Label("Reveal", systemImage: "lightbulb")
                    .typeRole(.body, appliesForeground: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.hintMove != nil)

            Spacer()

            Button {
                Task { await model.skip() }
            } label: {
                Text("Skip")
                    .typeRole(.body, appliesForeground: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        // The same height the banner occupies, so swapping one for the other
        // does not move the board.
        .frame(height: ResultBanner.height)
        .padding(.horizontal, 4)
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No puzzles today", systemImage: "square.grid.3x3")
        } description: {
            Text(message)
        }
    }
}
