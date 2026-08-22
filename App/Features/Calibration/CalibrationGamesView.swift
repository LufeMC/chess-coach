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
/// The user's colour alternates, which reduces the first-move advantage in the
/// estimate rather than cancelling it: an odd number of games cannot split
/// evenly, so three Whites and two Blacks leave a fifth of that advantage in.
/// A fifth of it is a handful of Elo against a game-side standard error of 180,
/// which is why the odd game count stands — five games as White would have
/// folded the whole of it in, and that is the version worth avoiding.
///
/// ## Why a card between games
///
/// The five games used to run into each other: the outcome was recorded, the
/// session dropped, and the next starting position arrived on the same frame.
/// Checkmate, a flag and a fifty-move draw all looked identical from the chair —
/// a fresh board — and the only trace of what had happened was the opponent's
/// rating moving a hundred points. The reveal then said "you won every
/// calibration game" to someone who had never been told the result of any of
/// them. So each game ends on a stated result, the ladder's next step is named,
/// and the user asks for the next board.
struct CalibrationGamesView: View {

    let flow: CalibrationModel
    let engineService: EngineService

    @State private var session: GameSession?
    @State private var isConfirmingResign = false
    /// The card standing between two games. While it is up no board is built,
    /// and the game it describes has not been recorded yet.
    @State private var interlude: CalibrationInterlude?

    var body: some View {
        VStack(spacing: 12) {
            CalibrationHeader(progress: flow.progress)
                .padding(.horizontal)

            if let interlude {
                CalibrationInterludeCard(interlude: interlude) { leave(interlude) }
                    .padding(.horizontal)
                Spacer(minLength: 0)
            } else {
                board
            }
        }
        .padding(.top, 8)
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .task(id: ticket) { await startGame() }
        .onChange(of: finishedOutcome) { _, outcome in
            guard let outcome, let finished = session else { return }
            // The final position goes with the result: a fifty-move draw means
            // something different from a bare king than it does from an equal
            // endgame, and only the position can tell them apart.
            let measured = CalibrationScoring.measuredOutcome(
                for: outcome,
                finalPosition: finished.board.position,
                userColor: finished.configuration.userColor
            )
            // Set before the session is dropped: the card is what holds the
            // next board back, and a frame in which neither exists starts game
            // n+1 underneath the result of game n.
            interlude = CalibrationInterlude.result(
                gameNumber: flow.games.count + 1,
                outcome: outcome,
                measured: measured,
                opponentRating: flow.opponentRating,
                totalGames: flow.progress.currentRequired
            )
            session = nil
        }
        .onChange(of: session?.phase) { _, phase in announce(phase) }
    }

    // MARK: The game

    @ViewBuilder
    private var board: some View {
        statusRow
            .padding(.horizontal)

        clockRow
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

    // MARK: Game lifecycle

    /// What the view should be doing: which game, and whether a card is holding
    /// it back. Keying the task on both means dismissing the card is what starts
    /// the next board, without a second task that outlives the screen.
    private struct Ticket: Equatable {
        var index: Int
        var isHeld: Bool
    }

    private var ticket: Ticket {
        Ticket(index: flow.games.count, isHeld: interlude != nil)
    }

    private func startGame() async {
        guard interlude == nil, session == nil else { return }

        // A calibration picked up from a draft opens on a card rather than on a
        // board. The draft holds finished games only, so the game that was
        // interrupted starts again from move one, and nobody but this sentence
        // is going to say so.
        if flow.didResume {
            interlude = .resumed(
                gameNumber: flow.games.count + 1,
                totalGames: flow.progress.currentRequired,
                opponentRating: flow.opponentRating
            )
            flow.acknowledgeResume()
            return
        }

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
        // the second. The cancellation check is what keeps a screen the user has
        // left from spinning on a sleep that returns immediately.
        while !Task.isCancelled, let live = session, !live.checkClock() {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Dismisses the card, recording the game it described.
    ///
    /// A game the engine abandoned is dropped rather than recorded: its card
    /// carries no outcome, so there is nothing to hand the combiner.
    private func leave(_ interlude: CalibrationInterlude) {
        self.interlude = nil
        guard let outcome = interlude.measuredOutcome else { return }
        flow.record(gameOutcome: outcome)
    }

    private var finishedOutcome: GameSession.Outcome? {
        guard case let .finished(outcome) = session?.phase else { return nil }
        return outcome
    }

    // MARK: Status

    /// Which side you are, how strong the opponent is, and which side is moving.
    ///
    /// The opponent's rating is on screen because the ladder is the honest part
    /// of this phase: a user who loses game one and then sees the next opponent
    /// drop a hundred points can read the measurement working, rather than
    /// suspecting the app of being hard for its own sake.
    ///
    /// It gets its own label because that argument used to be made by a comment
    /// and contradicted by the screen. The rating lived in `turnLabel`'s default
    /// case, so it was visible only in the moment between the board appearing
    /// and the first move — for the whole game, the eighty moves during which
    /// the claim matters, it was gone. Worse, in that gap between games it read
    /// `flow.opponentRating`, which `record` has already advanced, so the one
    /// number the user did see was the *next* opponent's rather than the one
    /// they had just played.
    ///
    /// "~1200" rather than "1200" because that is the resolution behind it. The
    /// humanizer's profiles were measured 400 points apart and every step
    /// between them is interpolated, so the hundred-point rungs of this ladder
    /// are finer than anything that was validated. The tilde is the difference
    /// between naming a strength and naming a rung.
    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(sideLabel)
                .typeRole(.caption)
            Spacer(minLength: 8)
            Text(opponentLabel)
                .typeRole(.caption, monospacedDigits: true)
            Spacer(minLength: 8)
            Text(turnLabel)
                .typeRole(.label, monospacedDigits: true)
                .contentTransition(.opacity)
        }
        .animation(Motion.crossfade, value: turnLabel)
        // The turn is the one thing on this screen that changes without the
        // user touching anything, eighty times a game.
        .accessibilityElement(children: .combine)
        // Overriding the combined children, because "~" is a symbol VoiceOver
        // has no good reading for and the row is one sentence anyway.
        .accessibilityLabel(Text(spokenStatus))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var sideLabel: String {
        guard let session else { return "Setting up" }
        return session.configuration.userColor == .white ? "You play White" : "You play Black"
    }

    /// The opponent *this* game is against.
    ///
    /// Taken from the session rather than from the flow wherever there is one:
    /// `CalibrationModel.record` moves the ladder the instant a game is banked,
    /// so the flow's number describes the next board, not this one.
    private var opponentLabel: String {
        "Opponent ~\(currentOpponentRating)"
    }

    private var currentOpponentRating: Int {
        session?.configuration.opponentRating ?? flow.opponentRating
    }

    /// A word, never a spinner.
    ///
    /// A spinner while the opponent thinks is the second most reliable tell of a
    /// chess app that has not been edited: it animates for the entire time the
    /// user is meant to be looking at the position, and it says nothing the
    /// board does not already say.
    private var turnLabel: String {
        guard let session else { return "Starting" }
        switch session.phase {
        case .opponentThinking: return "Thinking"
        case .userToMove: return "Your move"
        case .finished: return "Game over"
        default: return "Starting"
        }
    }

    private var spokenStatus: String {
        "\(sideLabel), against an opponent playing around \(currentOpponentRating). \(turnLabel)."
    }

    /// Says the opponent's reply and hands the turn over.
    ///
    /// Without this a VoiceOver user gets silence for five whole games: the
    /// board redraws, the label crossfades, and nothing is spoken.
    private func announce(_ phase: GameSession.Phase?) {
        guard case .userToMove = phase, let session else { return }
        let reply = session.moves.last.flatMap { $0.byUser ? nil : $0.san }
        AccessibilityNotification.Announcement(
            reply.map { "\($0). Your move." } ?? "Your move."
        ).post()
    }

    // MARK: Clocks

    /// Both clocks, because these games are timed.
    ///
    /// `Configuration.calibration` is 15+10 and the view flags a player who
    /// stops moving, so a screen with no clock on it can record a loss on time
    /// into the rating seed without the user ever learning the game was timed.
    /// Not `PlayStatusPill`: that pill leads with the live evaluation, and an
    /// eval readout is exactly the coaching these five games must not have.
    private var clockRow: some View {
        HStack(spacing: 8) {
            CalibrationClock(
                name: "Your clock",
                label: "You",
                chargedMs: session?.userClockMs ?? startingClockMs,
                startedAt: session?.moveStartedAt ?? .now,
                isActive: isUserToMove
            )
            Spacer(minLength: 12)
            CalibrationClock(
                name: "Their clock",
                label: "Opponent",
                chargedMs: session?.opponentClockMs ?? startingClockMs,
                startedAt: session?.moveStartedAt ?? .now,
                isActive: isOpponentThinking
            )
        }
    }

    private var isUserToMove: Bool {
        if case .userToMove = session?.phase { return true }
        return false
    }

    private var isOpponentThinking: Bool {
        if case .opponentThinking = session?.phase { return true }
        return false
    }

    private var startingClockMs: Int {
        GameSession.Configuration.calibration(userColor: .white, opponentRating: flow.opponentRating)
            .baseSeconds * 1000
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
                Text(resignCost)
            }
    }

    /// What resigning actually costs, asked of the ladder rather than assumed.
    ///
    /// "The next opponent drops a hundred points" was true everywhere except the
    /// one place a user is most likely to be reading it. `CalibrationSeed` floors
    /// the walk at the weakest profile the engine has, so at the bottom of the
    /// ladder there is nothing further down and the sentence was promising a
    /// drop the next board would not deliver.
    private var resignCost: String {
        let next = CalibrationSeed.nextOpponentRating(current: currentOpponentRating, outcome: .loss)
        guard next < currentOpponentRating else {
            return "It counts as a loss. The next opponent stays at about \(next) — that is the gentlest one the app has."
        }
        return "It counts as a loss, and the next opponent drops to about \(next)."
    }
}

// MARK: - One clock

/// One side's remaining time.
///
/// The active side is signalled by weight and contrast only: over five games the
/// turn changes hundreds of times, and anything that moves on that boundary is
/// hundreds of pieces of motion nobody asked for. Amber under ten seconds, never
/// red — red is spoken for elsewhere in the app.
private struct CalibrationClock: View {

    /// What VoiceOver calls it.
    let name: String
    /// What the screen calls it.
    let label: String
    var chargedMs: Int
    var startedAt: Date
    var isActive: Bool

    var body: some View {
        // Scoped to this view so a ticking clock redraws a label rather than a
        // board.
        TimelineView(.periodic(from: startedAt, by: tickInterval)) { context in
            content(reading: PlayClock.reading(milliseconds: remaining(at: context.date)))
        }
    }

    private func content(reading: ClockReading) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .typeRole(.caption)
            Text(reading.text)
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .fontWeight(weight(for: reading.pressure))
                .foregroundStyle(foreground(for: reading.pressure))
        }
        .animation(Motion.colorShift, value: isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(name): \(reading.accessibilityText)"))
    }

    private func remaining(at date: Date) -> Int {
        PlayClock.remainingMs(
            chargedMs: chargedMs,
            startedAt: startedAt,
            now: date,
            isRunning: isActive
        )
    }

    private var tickInterval: TimeInterval {
        guard isActive else { return 3600 }
        return chargedMs <= 40_000 ? 0.1 : 0.5
    }

    private func weight(for pressure: ClockPressure) -> Font.Weight {
        switch pressure {
        case .none: .medium
        case .low: .semibold
        case .critical: .heavy
        }
    }

    private func foreground(for pressure: ClockPressure) -> Color {
        if pressure == .critical { return Palette.caution.dynamic }
        return isActive ? .primary : .secondary
    }
}

// MARK: - Between games

/// The card between two calibration games.
///
/// Three things, in the order they are asked for: what just happened, what
/// happens next, and one control that says which game it starts.
struct CalibrationInterlude: Equatable {

    var title: String
    var detail: String
    var actionTitle: String
    /// The result this card is holding, recorded when the user moves on. Nil for
    /// a game that must not count — an abandoned game, or the notice a resumed
    /// calibration opens on.
    var measuredOutcome: GameOutcome?

    /// A finished game.
    ///
    /// - Parameters:
    ///   - gameNumber: 1-based number of the game that just ended.
    ///   - outcome: what the session reported.
    ///   - measured: what the combiner will be told, which is not always the
    ///     same thing — see ``CalibrationScoring``.
    ///   - opponentRating: the rating that game was played against.
    ///   - totalGames: how many games the phase asks for.
    static func result(
        gameNumber: Int,
        outcome: GameSession.Outcome,
        measured: GameOutcome,
        opponentRating: Int,
        totalGames: Int
    ) -> CalibrationInterlude {
        // The engine gave up rather than the game ending: `GameSession` reports
        // an unknown-termination draw after its retry budget, and a draw the
        // user never played would be baked into the rating seed as evidence
        // about them.
        guard outcome.termination != GameTermination.unknown.rawValue else {
            return CalibrationInterlude(
                title: "Game \(gameNumber) stopped",
                detail: "The engine stopped answering, so this game is not counted. Nothing you did ended it, and nothing about it goes into your rating.",
                actionTitle: "Play game \(gameNumber) again",
                measuredOutcome: nil
            )
        }

        let next = CalibrationSeed.nextOpponentRating(current: opponentRating, outcome: measured)
        let isLast = gameNumber >= totalGames
        return CalibrationInterlude(
            title: "Game \(gameNumber) — \(headline(outcome: outcome, measured: measured))",
            detail: isLast
                ? "That is the last game. Twenty puzzles left, about ten seconds each."
                : "\(ladderSentence(from: opponentRating, to: next, outcome: measured)) You play \(gameNumber.isMultiple(of: 2) ? "White" : "Black") in game \(gameNumber + 1).",
            actionTitle: isLast ? "Start the puzzles" : "Play game \(gameNumber + 1)",
            measuredOutcome: measured
        )
    }

    /// The notice a resumed calibration opens on.
    static func resumed(gameNumber: Int, totalGames: Int, opponentRating: Int) -> CalibrationInterlude {
        CalibrationInterlude(
            title: "Back to game \(gameNumber) of \(totalGames)",
            detail: "Finished games were kept. A game that was still going was not, so game \(gameNumber) starts again from move one, against an opponent playing around \(opponentRating).",
            actionTitle: "Play game \(gameNumber)",
            measuredOutcome: nil
        )
    }

    /// How the game ended, stated rather than celebrated.
    ///
    /// The measured outcome is what the sentence ends on where the two differ: a
    /// fifty-move draw from a lost position is scored as a loss, and a card that
    /// said "drawn" over a result recorded as a loss would be the app keeping
    /// two sets of books.
    private static func headline(outcome: GameSession.Outcome, measured: GameOutcome) -> String {
        let termination = GameTermination(rawValue: outcome.termination)
        switch termination {
        case .checkmate:
            return measured == .win ? "you won by checkmate" : "you were checkmated"
        case .resignation:
            return measured == .win ? "your opponent resigned" : "you resigned"
        case .timeout:
            return measured == .win ? "your opponent ran out of time" : "you ran out of time"
        case .stalemate:
            return "stalemate, drawn"
        case .repetition:
            return "drawn by repetition"
        case .insufficientMaterial:
            return "drawn — neither side can mate"
        case .fiftyMoves:
            // The one termination `CalibrationScoring` overrules.
            return measured == .loss
                ? "fifty moves with no progress, scored as a loss from a lost position"
                : "drawn by the fifty-move rule"
        case .agreement:
            return "drawn by agreement"
        case .unknown, .none:
            switch measured {
            case .win: return "you won"
            case .loss: return "you lost"
            case .draw: return "drawn"
            }
        }
    }

    /// Why the next opponent is where it is.
    ///
    /// The outcome is a parameter rather than inferred from the direction,
    /// because two different results now leave the ladder standing still and
    /// they mean opposite things. A draw holds it because the two sides are
    /// already close. A *loss* holds it only at the bottom, where
    /// `CalibrationSeed` floors the walk at the weakest profile the engine has —
    /// and telling a user who just lost that "a draw says you are already close"
    /// would be the card explaining a result that did not happen.
    private static func ladderSentence(from current: Int, to next: Int, outcome: GameOutcome) -> String {
        if next > current {
            return "The next opponent goes up to about \(next)."
        }
        if next < current {
            return "The next opponent drops to about \(next)."
        }
        if outcome == .draw {
            return "The next opponent stays at about \(next) — a draw says you are already close."
        }
        return "The next opponent stays at about \(next) — that is the gentlest one the app has."
    }
}

private struct CalibrationInterludeCard: View {

    let interlude: CalibrationInterlude
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(interlude.title)
                .typeRole(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(interlude.detail)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(interlude.actionTitle, action: action)
                .buttonStyle(.primaryAction)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .padding(.top, 8)
    }
}
