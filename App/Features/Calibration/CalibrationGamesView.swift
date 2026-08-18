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

    var body: some View {
        VStack(spacing: 12) {
            CalibrationHeader(progress: flow.progress)
                .padding(.horizontal)

            if let session {
                activeGame(session)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 8)
        .task(id: flow.games.count) { await startGame() }
        .onChange(of: finishedOutcome) { _, outcome in
            guard let outcome else { return }
            flow.record(gameOutcome: Self.outcome(from: outcome))
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

    static func outcome(from outcome: GameSession.Outcome) -> GameOutcome {
        switch outcome.userWon {
        case .some(true): .win
        case .some(false): .loss
        case nil: .draw
        }
    }

    // MARK: Board

    @ViewBuilder
    private func activeGame(_ session: GameSession) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(session.configuration.userColor == .white ? "You play White" : "You play Black")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.phase == .opponentThinking {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal)

            BoardView(
                position: session.board.position,
                orientation: session.configuration.userColor,
                interaction: interaction(for: session),
                highlights: highlights(for: session)
            )
            .padding(.horizontal, 12)

            Spacer(minLength: 0)

            Button("Resign") {
                session.resign()
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 12)
        }
    }

    private func interaction(for session: GameSession) -> BoardInteraction {
        guard case .userToMove = session.phase else { return .replay }
        return .userMove { from, to in
            guard session.board.canMove(pieceAt: from, to: to) else { return .rejected }
            Task { await session.attemptUserMove(from: from, to: to) }
            return .accepted
        }
    }

    private func highlights(for session: GameSession) -> [SquareHighlight] {
        guard let last = session.lastMove else { return [] }
        return SquareHighlight.lastMove(from: last.from, to: last.to)
    }
}
