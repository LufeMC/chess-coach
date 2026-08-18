import SwiftUI

// The interruption vocabulary for the play surface.
//
// Every sheet here is short, and every sheet here is presented with background
// interaction enabled — which is what removes the system dimming layer. That is
// not a detail: the board must stay fully visible and fully legible while a
// coaching sheet is up. The question being asked is *about the position*, so
// hiding the position to ask it defeats the interaction. It is the first item on
// the "what makes an app feel cheap" list for exactly that reason.
//
// The sheets are also sized by the caller, from the board's measured bottom
// edge, so the sheet's top always lands below the board rather than over it.
// That is why the content here is short: the space below the board is the
// budget, and the budget is not negotiable.

/// Which sheet the play surface is showing.
enum PlaySheetKind: Identifiable, Equatable {
    /// Driven by `GameSession.phase`, not by a tap.
    case secondTry
    case options
    case leave

    var id: Int {
        switch self {
        case .secondTry: 0
        case .options: 1
        case .leave: 2
        }
    }

    /// The height this sheet wants, before it is clamped to the space below the
    /// board.
    var preferredHeight: CGFloat {
        switch self {
        case .secondTry: 236
        case .options: 208
        case .leave: 224
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
