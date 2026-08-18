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
// edge, so the sheet top always lands below the board rather than over it.

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
        case .secondTry: 268
        case .options: 250
        case .leave: 236
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
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: "Almost there",
                // Every coaching sheet gets a way out that is not an answer.
                skip: SheetHeader.Skip(title: "Not now") { session.resumeAfterSecondTry() }
            )

            Text(prompt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3, reservesSpace: true)

            if state.hintLevel < 2 {
                Button {
                    session.requestHint()
                } label: {
                    Label("Show me why", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                session.resumeAfterSecondTry()
            } label: {
                Text("Take it back")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                Task { await session.keepOriginalMove() }
            } label: {
                Text("Play it anyway")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
        .padding(20)
    }

    private var prompt: String {
        switch state.hintLevel {
        case 0: "That move gives something away. The board is still live — take another look before you commit."
        case 1: "Look at the highlighted square. What does it let them do?"
        default: "That was their idea. Find a move that deals with it."
        }
    }
}

// MARK: - Options

/// Everything that is not "make a move".
///
/// The top row never grows past its four elements, so resign, flip and start
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
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: isFinished ? "Game over" : "This game")

            VStack(spacing: 0) {
                SheetRow(title: "Flip the board", systemImage: "arrow.up.arrow.down") {
                    onFlip()
                    dismiss()
                }

                Divider().padding(.leading, 42)

                if isFinished {
                    SheetRow(title: "New game", systemImage: "plus.circle") {
                        onNewGame()
                        dismiss()
                    }
                } else {
                    SheetRow(title: "Resign", systemImage: "flag", tint: .orange) {
                        onResign()
                        dismiss()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

// MARK: - Leaving

/// The exit confirmation.
///
/// Leaving mid-game is a resignation, and a resignation should never be one tap
/// from the board. The safe path — keep playing — is the filled button; leaving
/// is a tinted row underneath it.
struct LeaveGameSheet: View {

    let onKeepPlaying: () -> Void
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Leave this game?")

            Text("Leaving counts as a resignation. The game is still saved, and still analysed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onKeepPlaying) {
                Text("Keep playing")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: onLeave) {
                Text("Resign and leave")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .padding(.bottom, 4)
        }
        .padding(20)
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
                .font(.title3.bold())

            Spacer(minLength: 12)

            if let skip {
                Button(action: skip.action) {
                    Text(skip.title)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                    .font(.body)
                    .frame(width: 22)
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
    }
}
