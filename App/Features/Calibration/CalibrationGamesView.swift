//
//  CalibrationGamesView.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import SwiftUI
import TrainingCore

/// The five calibration games.
///
/// ## Why these games are stripped down
///
/// `GameSession.Configuration.calibration` turns guided mode and second-try
/// off, and that is not a simplification — it is a correctness requirement. Both
/// features work by *interrupting the user at the moment they are about to go
/// wrong*, which is precisely the signal the five games exist to measure. A
/// calibration game with second-try enabled measures how well the user plays
/// with a coach at their shoulder, and then hands that number to the combiner as
/// though it were their unaided strength.
///
/// The user's colour alternates. Five games as White would fold a first-move
/// advantage straight into the estimate.
struct CalibrationGamesView: View {

    let flow: CalibrationModel
    let engineService: EngineService

    @State private var session: GameSession?
    @State private var isConfirmingResign = false

    var body: some View {
        VStack(spacing: 12) {
            CalibrationHeader(progress: flow.progress)
                .padding(.horizontal)

            statusRow
                .padding(.horizontal)

            if let session {
                CapturedTrayRow(
                    perspective: session.configuration.userColor,
                    position: session.board.position
                )
                .padding(.horizontal)
            }

            boardSlot

            Spacer(minLength: 0)

            resignButton
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .task(id: flow.games.count) { await startGame() }
        .onChange(of: finishedOutcome) { _, outcome in
            guard let outcome, let finished = session else { return }
            // The final position goes with the result: a fifty-move draw means
            // something different from a bare king than it does from an equal
            // endgame, and only the position can tell them apart.
            flow.record(
                gameOutcome: CalibrationScoring.measuredOutcome(
                    for: outcome,
                    finalPosition: finished.board.position,
                    userColor: finished.configuration.userColor
                )
            )
            session = nil
        }
    }

    // MARK: Game lifecycle

    private func startGame() async {
        guard session == nil else { return }
        let configuration = GameSession.Configuration.calibration(
            userColor: flow.games.count.isMultiple(of: 2) ? .white : .black,
            opponentRating: flow.opponentRating
        )
        let created = GameSession(configuration: configuration, engineService: engineService)
        session = created
        await created.start()

        // The clock is not self-driving: `GameSession` charges elapsed time when
        // it is asked to, so a player who simply stops moving never flags unless
        // something ticks. One second is plenty — the clocks are displayed to
        // the second.
        while let live = session, !live.checkClock() {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var finishedOutcome: GameSession.Outcome? {
        guard case let .finished(outcome) = session?.phase else { return nil }
        return outcome
    }


    // MARK: Status

    /// Which side you are, which side is moving, and how strong the opponent is.
    ///
    /// The opponent's rating is on screen because the ladder is the honest part
    /// of this phase: a user who loses game one and then sees the next opponent
    /// drop a hundred points can read the measurement working, rather than
    /// suspecting the app of being hard for its own sake.
    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(sideLabel)
                .typeRole(.caption)
            Spacer(minLength: 12)
            Text(turnLabel)
                .typeRole(.label, monospacedDigits: true)
                .contentTransition(.opacity)
        }
        .animation(Motion.crossfade, value: turnLabel)
    }

    private var sideLabel: String {
        guard let session else { return "Setting up" }
        return session.configuration.userColor == .white ? "You play White" : "You play Black"
    }

    /// A word, never a spinner.
    ///
    /// A spinner while the opponent thinks is the second most reliable tell of a
    /// chess app that has not been edited: it animates for the entire time the
    /// user is meant to be looking at the position, and it says nothing the
    /// board does not already say.
    private var turnLabel: String {
        guard let session else { return "Opponent \(flow.opponentRating)" }
        switch session.phase {
        case .opponentThinking: return "Thinking"
        case .userToMove: return "Your move"
        default: return "Opponent \(session.configuration.opponentRating)"
        }
    }

    // MARK: Board

    @ViewBuilder
    private var boardSlot: some View {
        Group {
            if let session {
                BoardView(
                    position: session.board.position,
                    orientation: session.configuration.userColor,
                    interaction: interaction(for: session),
                    highlights: highlights(for: session),
                    style: BoardAppearance.shared.style
                )
            } else {
                EmptyBoardSlot()
            }
        }
        .skeleton(if: session == nil) { BoardSkeleton() }
    }

    private func interaction(for session: GameSession) -> BoardInteraction {
        guard case .userToMove = session.phase else { return .replay }
        return .userMove { from, to in
            guard session.board.canMove(pieceAt: from, to: to) else { return .rejected }
            // Calibration games are real games, so they promote like real
            // games. Skipping the picker here would corrupt the one measurement
            // the entire curriculum is seeded from.
            if session.isPromotion(from: from, to: to) {
                return .needsPromotion(complete: { kind in
                    Task { await session.attemptUserMove(from: from, to: to, promoting: kind) }
                    return .accepted
                })
            }
            Task { await session.attemptUserMove(from: from, to: to) }
            return .accepted
        }
    }

    private func highlights(for session: GameSession) -> [SquareHighlight] {
        guard let last = session.lastMove else { return [] }
        return SquareHighlight.lastMove(from: last.from, to: last.to)
    }

    // MARK: Resign

    /// Quiet, and asked about first.
    ///
    /// Resigning is a legitimate escape from a game that has stopped teaching
    /// anything, and it is also a loss the combiner will believe. One stray tap
    /// costing a hundred points off a first-run measurement is worth a
    /// confirmation, and the confirmation is where the cost gets said out loud.
    private var resignButton: some View {
        Button("Resign this game") { isConfirmingResign = true }
            .buttonStyle(.tertiaryAction)
            .disabled(session == nil)
            .confirmationDialog(
                "Resign game \(flow.games.count + 1)?",
                isPresented: $isConfirmingResign,
                titleVisibility: .visible
            ) {
                Button("Resign", role: .destructive) { session?.resign() }
                Button("Keep playing", role: .cancel) {}
            } message: {
                Text("It counts as a loss, and the next opponent drops a hundred points.")
            }
    }
}
