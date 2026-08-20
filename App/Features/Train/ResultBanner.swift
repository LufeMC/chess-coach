//
//  ResultBanner.swift
//  ChessCoach
//

import SwiftUI

/// The result of one puzzle.
///
/// ## Read this before adding a line to the failure case
///
/// Success and failure render through **the same view, with the same geometry,
/// the same height and the same button in the same place**. Only the tint and
/// the glyph change. This is not laziness and it is not a shortcut — it is the
/// entire design.
///
/// The obvious "improvement" is to give failure an extra sentence: something
/// encouraging, something that softens it. Do not. The moment failure gets a
/// second line, the banner is taller than the success banner, the Continue
/// button sits somewhere else, and the layout itself has told the user that
/// failing is a special event requiring comfort. They will feel that before they
/// read a word of it. `Docs/design-conventions.md` lists consolation copy on
/// failure as a pattern to avoid for exactly this reason: reassurance implies
/// the result warranted distress.
///
/// The copy explains the answer, and on a miss adds what was wrong with the move
/// the user played. It is built by ``PuzzleConcept/verdictMessage(solved:theme:answer:position:played:)``.
///
/// ## Why the miss may carry a second sentence
///
/// The rule above bans a second line of *consolation*, and that ban stands. This
/// is its opposite: naming the mistake is more demanding than staying silent
/// about it, and it is the only feedback in the app that tells a user why the
/// move they actually chose failed. Withholding it to preserve a symmetry the
/// user cannot see would be the tail wagging the dog.
///
/// The symmetry that *is* visible is preserved exactly: both outcomes reserve
/// three lines whether or not they fill them, so the banner is the same height,
/// the button sits in the same place, and the board never moves.
///
/// ``Palette/caution``, not red, for the failure tint: red is the eval bar's
/// "advantage lost" and Review's blunder colour, where it is a factual severity
/// label about a game already played. Here the puzzle just gets rescheduled, and
/// amber is exactly the register that asks for — "note this", not "alarm".
///
/// Success takes the **accent**, not green. Green is spoken for: it means
/// advantage gained on the eval bar, and a token that also means "correct",
/// "confirmed" and "online" ends up meaning none of them. The accent is the
/// screen's one ration and this is where it is spent, because while the banner
/// is up its Continue button *is* the primary action.
struct ResultBanner: View {

    /// The banner's height, and therefore the height every footer that can be
    /// swapped for it must reserve.
    ///
    /// Exported as a constant rather than left implicit because the symmetry
    /// argument above only holds if the *surrounding* layout is stable too: a
    /// board that jumps six points when the banner appears undoes the work.
    static let height: CGFloat = 92

    let verdict: PuzzleSessionModel.Verdict
    let continueTitle: String
    let onContinue: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: verdict.solved ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(tint)
                // A fixed frame so the glyph's differing optical widths cannot
                // shift the sentence beside it by a point or two.
                .frame(width: 28, height: 28)

            Text(verdict.message)
                .typeRole(.body)
                .fixedSize(horizontal: false, vertical: true)
                // Three lines of room, always, on both outcomes. Reserving
                // rather than growing is what keeps a miss that explains itself
                // the same height as a solve that does not need to.
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onContinue) {
                Text(continueTitle)
                    .typeRole(.headline, appliesForeground: false)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(tint))
            }
            .buttonStyle(.pressable)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: Self.height)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// Semantic backgrounds at ~10% alpha, semantic foregrounds at full
    /// strength — the one rule that keeps a tinted card from becoming a poster.
    private var tint: Color {
        (verdict.solved ? Palette.accent : Palette.caution).dynamic
    }
}

#Preview("Solved") {
    ResultBanner(
        verdict: .init(solved: true, message: "Solved — the fork was on the c-file.", ring: nil, answer: nil),
        continueTitle: "Next",
        onContinue: {}
    )
    .padding()
}

#Preview("Missed") {
    ResultBanner(
        verdict: .init(solved: false, message: "Missed — the pin was on the f-file.", ring: nil, answer: "f3f7"),
        continueTitle: "Next",
        onContinue: {}
    )
    .padding()
}
