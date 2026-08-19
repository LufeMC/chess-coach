import SwiftUI
import TrainingCore

// The interruption vocabulary for the play surface.
//
// Every sheet here is short, and every sheet here leaves the board on screen.
// That is not a detail: the question being asked is *about the position*, so
// hiding the position to ask it defeats the interaction. It is the first item on
// the "what makes an app feel cheap" list for exactly that reason.
//
// Most of them go further and enable background interaction, which removes the
// system dimming layer entirely — the board stays fully legible *and* stays
// playable underneath. The guided pause is the one exception, and it says why in
// ``PlaySheetKind/allowsBoardInteraction``.
//
// The sheets are also sized by the caller, from the board's measured bottom
// edge, so the sheet's top always lands below the board rather than over it.
// That is why the content here is short: the space below the board is the
// budget, and the budget is not negotiable.

/// Which sheet the play surface is showing.
enum PlaySheetKind: Identifiable, Equatable {
    /// Driven by `GameSession.phase`, not by a tap.
    case secondTry
    /// The guided-mode Socratic pause. Also phase-driven.
    case guidedPrompt
    case options
    case leave

    var id: Int {
        switch self {
        case .secondTry: 0
        case .guidedPrompt: 1
        case .options: 2
        case .leave: 3
        }
    }

    /// The height this sheet wants, before it is clamped to the space below the
    /// board.
    var preferredHeight: CGFloat {
        switch self {
        case .secondTry: 236
        // The shortest of the four, deliberately. This is the only sheet whose
        // whole subject is the position behind it, so the space it does not
        // take is doing as much work as the space it does.
        case .guidedPrompt: 220
        case .options: 208
        case .leave: 224
        }
    }

    /// Whether the board underneath stays live while this sheet is up.
    ///
    /// Every sheet but one says yes, which is what removes the system dimming
    /// layer. The guided pause says no, and it is worth being precise about the
    /// reason: in that phase the user's answer *is* the move they play next, so
    /// a stray tap that lands a piece while the question is still on screen
    /// would answer it by accident. `GameSession` already refuses moves during
    /// the pause; this is what makes the surface say so rather than swallowing
    /// taps silently. The dimming layer is the price, and this is the one moment
    /// worth paying it.
    var allowsBoardInteraction: Bool {
        self != .guidedPrompt
    }
}

// MARK: - Guided pause

/// One way out of a Socratic pause.
///
/// Modelled as a list rather than as two hard-coded buttons because the layout
/// rule is a function of how many there are — two read as a pair and sit side by
/// side, three or more read as a list and stack. Holding that rule in one place
/// means a prompt that later carries its own answer set cannot ship the wrong
/// shape by accident.
struct GuidedAnswer: Identifiable, Equatable {

    enum Role: Equatable {
        /// "I've thought about it" — the path back to the board.
        case commit
        /// The way out that is not an answer.
        case escape
    }

    var title: String
    var role: Role

    var id: String { title }
}

/// How a set of answers is arranged.
enum GuidedAnswerLayout: Equatable {
    /// One row: the escape bordered on the left, the commit filled on the right.
    case sideBySide
    /// Full-width rows, the escape last and quieter.
    case stacked

    /// Three is where a row of buttons stops being readable at a glance and
    /// becomes a puzzle of its own, which is the opposite of what a coaching
    /// pause is for.
    static func forAnswerCount(_ count: Int) -> GuidedAnswerLayout {
        count <= 2 ? .sideBySide : .stacked
    }
}

/// The guided-mode Socratic pause.
///
/// Guided mode stops the game to ask a question rather than to give an answer,
/// and the sheet has to carry that distinction on its face: the question is the
/// largest thing on it, there is no text field, and the way forward is phrased
/// as readiness rather than as correctness.
///
/// Two rules are load-bearing. It is the shortest sheet on the surface, sized
/// from the space below the board like the rest, so the position the question is
/// about is still on screen while the question is read — a pause that covers the
/// board is asking about something the user can no longer see. And there is
/// always an escape: a user who cannot answer has to be able to say so and be
/// shown the method, because the alternative is a pause that reads as a test
/// they are failing while their own clock runs down.
///
/// The question takes the sheet-title role rather than a size of its own. The
/// bank's questions run to a hundred characters and the screen-title role is
/// 28pt — one long question set at that size is five lines, which is the whole
/// height budget and the board's ground with it.
struct GuidedPromptSheet: View {

    let state: GameSession.GuidedPromptState
    /// Called exactly once, with whether the user asked to be shown the method.
    /// The session decides what that means for the prompt's grade; this sheet
    /// only reports it.
    let onFinish: (Bool) -> Void

    /// The method replaces the question in place rather than opening a second
    /// card. The board is the reason this sheet is short, and a card on top of
    /// this one would spend exactly what this one was sized to protect.
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(revealed ? Self.method(for: habit) : state.question)
                .typeRole(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(clarifier)
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            actions
        }
        .animation(Motion.contentSwap, value: revealed)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var habit: Habit? {
        Habit(rawValue: state.habitID)
    }

    /// One line, and it exists to answer the question the user actually has at
    /// this moment, which is "what am I supposed to do with this" — not to
    /// restate the question in smaller type.
    private var clarifier: String {
        revealed
            ? "Play it on the board when you're ready."
            : "Nothing to type. Your next move is the answer."
    }

    @ViewBuilder
    private var actions: some View {
        let answers = Self.answers(revealed: revealed)

        switch GuidedAnswerLayout.forAnswerCount(answers.count) {
        case .sideBySide:
            HStack(spacing: 12) {
                // Escape on the left, so the filled button is the one under the
                // thumb and the way out is the one you have to reach for.
                ForEach(answers.filter { $0.role == .escape }) { answer in
                    Button(answer.title) { choose(answer) }
                        .buttonStyle(.secondaryAction)
                }
                ForEach(answers.filter { $0.role == .commit }) { answer in
                    Button(answer.title) { choose(answer) }
                        .buttonStyle(.primaryAction)
                }
            }

        case .stacked:
            VStack(spacing: 8) {
                ForEach(answers.filter { $0.role == .commit }) { answer in
                    Button(answer.title) { choose(answer) }
                        .buttonStyle(.secondaryAction)
                }
                // A different tier, not a different accent: the way out has to
                // be findable without competing with the answers above it.
                ForEach(answers.filter { $0.role == .escape }) { answer in
                    Button(answer.title) { choose(answer) }
                        .buttonStyle(.tertiaryAction)
                }
            }
        }
    }

    private func choose(_ answer: GuidedAnswer) {
        switch answer.role {
        case .commit:
            onFinish(revealed)
        case .escape:
            revealed = true
        }
    }

    /// The ways out, in reading order.
    ///
    /// Static so the one rule that matters can be asserted without rendering
    /// anything: while the question is up there is always an escape, and after
    /// the method has been shown there is always a way back to the board. A
    /// state with neither is a pause the user cannot leave while the clock runs.
    static func answers(revealed: Bool) -> [GuidedAnswer] {
        if revealed {
            return [GuidedAnswer(title: "Got it", role: .commit)]
        }
        return [
            GuidedAnswer(title: "I'm ready", role: .commit),
            GuidedAnswer(title: "I'm not sure, show me", role: .escape)
        ]
    }

    /// The method behind the question: what to *do*, never what to play.
    ///
    /// Same constraint as the question bank, for the same reason. Someone who
    /// taps "show me" has admitted they do not know how to start, and handing
    /// them a move at that moment teaches them to ask rather than to look —
    /// which is the habit the pause exists to replace.
    static func method(for habit: Habit?) -> String {
        switch habit {
        case .whatChanged:
            "Look only at their last move. Name the square it left, and the squares it now hits."
        case .scanThreats:
            "List their checks, then their captures, then anything of yours they attack twice."
        case .candidatesFirst:
            "Name two moves you would be happy to play before you calculate either of them."
        case .calcToQuiet:
            "Follow the forcing moves until nothing is hanging, and judge that position instead."
        case .blunderCheck:
            "Take the move you want to play, and find their sharpest reply to it."
        case .kingSafety:
            "Count the defenders of the squares around your king, then count the attackers."
        case .endgameTechnique:
            "Decide where your king belongs, then find the move that starts it walking there."
        case .convertCleanly:
            "Find their most active piece. Trade it, or take the square it wants."
        case .clockDiscipline:
            "Spend real time here. Say what the position needs before you touch a piece."
        case nil:
            "Name what they threaten, then name what you want. The move usually follows."
        }
    }
}

// MARK: - Second try

/// The blunder interruption.
///
/// Tone is deliberate: "Almost there" and a take-back, never a red "Incorrect"
/// flood — the point is to send the user back to the position, not to train
/// flinching.
///
/// The filled button is the *safe* action. Making `Play it anyway` the prominent
/// one would be the layout telling the user that giving up is the expected
/// choice, and they would feel that before reading a word. The give-up path
/// stays available, one tap away, as a plain row.
struct SecondTrySheet: View {

    let state: GameSession.SecondTryState
    let session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(
                title: "Almost there",
                // Every coaching sheet gets a way out that is not an answer.
                skip: SheetHeader.Skip(title: "Not now") { session.resumeAfterSecondTry() }
            )

            Text(prompt)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2, reservesSpace: true)

            Spacer(minLength: 0)

            Button("Take it back") {
                session.resumeAfterSecondTry()
            }
            .buttonStyle(.primaryAction)

            // Both quiet actions share one row: the sheet's whole height budget
            // is the space below the board, and a third stacked button would
            // spend it on the two things the user is least likely to want.
            HStack(spacing: 16) {
                if state.hintLevel < 2 {
                    Button {
                        session.requestHint()
                    } label: {
                        Label("Show me why", systemImage: "sparkles")
                            .typeRole(.caption, appliesForeground: false)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.pressable)
                }

                Spacer(minLength: 0)

                Button("Play it anyway") {
                    Task { await session.keepOriginalMove() }
                }
                .buttonStyle(.pressable)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var prompt: String {
        switch state.hintLevel {
        case 0: "That move gives something away. Look again — the board is still live."
        case 1: "Look at the highlighted square. What does it let them do?"
        default: "That was their idea. Find a move that deals with it."
        }
    }
}

// MARK: - Options

/// Everything that is not "make a move".
///
/// The status row never grows past its three segments, so resign, flip and start
/// again live behind one `•••`. Resigning is two taps from the board and is a
/// tinted row rather than a filled button — a destructive action that is the
/// most prominent thing in the sheet is a trap.
struct GameOptionsSheet: View {

    let isFinished: Bool
    let onFlip: () -> Void
    let onResign: () -> Void
    let onNewGame: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: isFinished ? "Game over" : "This game")

            VStack(spacing: 0) {
                SheetRow(title: "Flip the board", systemImage: "arrow.up.arrow.down") {
                    onFlip()
                    dismiss()
                }

                Divider().padding(.leading, 34)

                if isFinished {
                    SheetRow(title: "New game", systemImage: "plus.circle") {
                        onNewGame()
                        dismiss()
                    }
                } else {
                    // Amber rather than red: red means "advantage lost" in this
                    // app, and a red row here would teach it a second meaning.
                    SheetRow(title: "Resign", systemImage: "flag", tint: Palette.caution.dynamic) {
                        onResign()
                        dismiss()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }
}

// MARK: - Leaving

/// The exit confirmation.
///
/// Leaving mid-game is a resignation, and a resignation should never be one tap
/// from the board. The safe path — keep playing — is the filled button; leaving
/// is a quiet row underneath it.
struct LeaveGameSheet: View {

    let onKeepPlaying: () -> Void
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Leave this game?")

            Text("Leaving counts as a resignation. The game is still saved, and still analysed.")
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Keep playing", action: onKeepPlaying)
                .buttonStyle(.primaryAction)

            Button("Resign and leave", action: onLeave)
                .buttonStyle(.tertiaryAction)
                .foregroundStyle(Palette.caution.dynamic)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }
}

// MARK: - Shared parts

/// Title on the left, an optional skip pill on the right.
struct SheetHeader: View {

    struct Skip {
        var title: String
        var action: () -> Void

        init(title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
    }

    let title: String
    var skip: Skip?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .typeRole(.headline)

            Spacer(minLength: 12)

            if let skip {
                Button(action: skip.action) {
                    Text(skip.title)
                        .typeRole(.caption, appliesForeground: false)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.surfaceSunken.dynamic))
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

/// One tappable row inside a sheet.
struct SheetRow: View {

    let title: String
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    init(title: String, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                Spacer(minLength: 0)
            }
            .typeRole(.body, appliesForeground: false)
            .foregroundStyle(tint ?? .primary)
            .contentShape(Rectangle())
            .padding(.vertical, 11)
        }
        .buttonStyle(.pressable)
    }
}
