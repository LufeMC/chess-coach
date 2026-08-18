import BoardUI
import ChessKit
import SwiftUI

/// Board-first play surface.
///
/// Layout follows the design brief: three capsules on top (close, both clocks,
/// eval), an edge-to-edge board, and the opponent/user chips above and below it.
/// Training interruptions arrive as short bottom sheets so the board stays
/// visible — the position is the thing being discussed, hiding it defeats the
/// purpose.
struct PlayScreen: View {
    @Environment(AppModel.self) private var model
    @State private var session: GameSession?

    var body: some View {
        Group {
            if let session {
                activeGame(session)
            } else {
                startPrompt
            }
        }
        .navigationTitle("Play")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(session == nil ? .visible : .hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Start

    private var startPrompt: some View {
        VStack(spacing: 24) {
            Spacer()

            BoardView(position: .standard, interaction: .locked)
                .frame(maxWidth: 280)
                .opacity(0.35)

            VStack(spacing: 6) {
                Text("Sparring")
                    .font(.title2.bold())
                Text("One game, then three moments to study.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                startGame()
            } label: {
                Text("Play \(opponentName)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding(.bottom)
    }

    private var opponentName: String {
        // Opponents get names and traits rather than difficulty numbers — a
        // level integer invites grinding, a personality invites playing.
        OpponentRoster.opponent(forRating: opponentRating).name
    }

    private var opponentRating: Int {
        OpponentLadder.rating(forUserRating: 1100, gameIndex: 0)
    }

    private func startGame() {
        let configuration = GameSession.Configuration.sparring(
            userColor: .white,
            opponentRating: opponentRating
        )
        let newSession = GameSession(configuration: configuration, engineService: model.engineService)
        session = newSession
        Task { await newSession.start() }
    }

    // MARK: - Active game

    @ViewBuilder
    private func activeGame(_ session: GameSession) -> some View {
        VStack(spacing: 12) {
            topBar(session)

            OpponentChip(
                opponent: OpponentRoster.opponent(forRating: session.configuration.opponentRating),
                isThinking: session.phase == .opponentThinking
            )

            BoardView(
                position: session.board.position,
                orientation: session.configuration.userColor,
                interaction: interaction(for: session),
                highlights: highlights(for: session),
                arrows: arrows(for: session)
            )

            Spacer(minLength: 0)

            bottomBar(session)
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: .constant(isShowingSecondTry(session))) {
            if case .secondTry(let state) = session.phase {
                SecondTrySheet(state: state, session: session)
                    .presentationDetents([.height(260)])
                    .presentationBackgroundInteraction(.disabled)
                    .interactiveDismissDisabled()
            }
        }
    }

    private func isShowingSecondTry(_ session: GameSession) -> Bool {
        if case .secondTry = session.phase { return true }
        return false
    }

    private func topBar(_ session: GameSession) -> some View {
        HStack(spacing: 10) {
            Button {
                session.resign()
                self.session = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            ClockCapsule(milliseconds: session.opponentClockMs, isActive: !session.userToMove)
            ClockCapsule(milliseconds: session.userClockMs, isActive: session.userToMove)
        }
        .padding(.top, 4)
    }

    private func bottomBar(_ session: GameSession) -> some View {
        HStack {
            Text(session.configuration.userColor == .white ? "You · White" : "You · Black")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if case .finished(let outcome) = session.phase {
                Text(outcome.termination.capitalized)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.bottom, 8)
    }

    private func interaction(for session: GameSession) -> BoardInteraction {
        guard case .userToMove = session.phase else { return .replay }
        return .userMove { from, to in
            // The board asks; GameSession decides. Returning `.rejected` here is
            // exactly how an illegal move snaps back — and later, how second-try
            // retracts a blunder.
            guard session.board.canMove(pieceAt: from, to: to) else {
                return .rejected
            }
            Task { await session.attemptUserMove(from: from, to: to) }
            return .accepted
        }
    }

    private func highlights(for session: GameSession) -> [SquareHighlight] {
        var result: [SquareHighlight] = []
        if let last = session.lastMove {
            result += SquareHighlight.lastMove(from: last.from, to: last.to)
        }
        if case .secondTry(let state) = session.phase, state.hintLevel >= 1, let square = state.hintSquare {
            result.append(SquareHighlight(square, .hint))
        }
        return result
    }

    private func arrows(for session: GameSession) -> [BoardArrow] {
        guard case .secondTry(let state) = session.phase, state.hintLevel >= 2,
            let arrow = state.refutationArrow
        else { return [] }
        return [BoardArrow(from: arrow.from, to: arrow.to, style: .threat)]
    }
}

/// Monospaced clock so the digits don't jitter — the single most visible tell of
/// an unpolished chess app.
private struct ClockCapsule: View {
    let milliseconds: Int
    let isActive: Bool

    var body: some View {
        Text(formatted)
            .font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.quaternary))
            // Dimming the inactive side reads faster than a border or a color
            // change, and costs no extra chrome.
            .opacity(isActive ? 1.0 : 0.35)
    }

    private var formatted: String {
        let totalSeconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct OpponentChip: View {
    let opponent: OpponentRoster.Opponent
    let isThinking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.quaternary)
                .frame(width: 28, height: 28)
                .overlay {
                    Text(opponent.name.prefix(1))
                        .font(.caption.weight(.semibold))
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(opponent.name)
                    .font(.subheadline.weight(.medium))
                Text(opponent.trait)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isThinking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Second-try sheet.
///
/// Tone is deliberate: "Almost there" and a `Try again` primary, never a red
/// "Incorrect" flood — the point is to send the user back to the position, not
/// to train flinching.
private struct SecondTrySheet: View {
    let state: GameSession.SecondTryState
    let session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Almost there")
                .font(.title2.bold())

            Text(prompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if state.hintLevel < 2 {
                    Button {
                        session.requestHint()
                    } label: {
                        Label("Get help", systemImage: "sparkles")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Try again") {
                    // Dismissing returns the user to the board with the move
                    // already retracted by GameSession.
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var prompt: String {
        switch state.hintLevel {
        case 0: "That move gives something away. Take another look before you commit."
        case 1: "Look at the highlighted square. What does it let them do?"
        default: "That was their idea. Find a move that deals with it."
        }
    }
}

/// Named opponents with traits instead of numbered difficulty levels.
enum OpponentRoster {
    struct Opponent: Sendable, Hashable {
        var name: String
        var trait: String
        var rating: Int
    }

    private static let roster: [Opponent] = [
        Opponent(name: "Mira", trait: "grabs material, forgets her king", rating: 850),
        Opponent(name: "Oscar", trait: "trades early, hates pressure", rating: 1050),
        Opponent(name: "Petra", trait: "solid, punishes loose pieces", rating: 1250),
        Opponent(name: "Dane", trait: "sharp openings, drifts later", rating: 1450),
        Opponent(name: "Ines", trait: "positional, squeezes endgames", rating: 1650),
        Opponent(name: "Kolya", trait: "tactical, rarely misses a shot", rating: 1900),
        Opponent(name: "Vera", trait: "no weaknesses to speak of", rating: 2150),
    ]

    static func opponent(forRating rating: Int) -> Opponent {
        let nearest = roster.min { abs($0.rating - rating) < abs($1.rating - rating) }
        var result = nearest ?? roster[1]
        result.rating = rating
        return result
    }
}
