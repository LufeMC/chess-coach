//
//  ConceptLessonView.swift
//  ChessCoach
//

import BoardUI
import SwiftUI
import TrainingCore

/// The lesson, shown once, before the concept is ever exercised.
///
/// ## Why this screen exists at all
///
/// A tactic can be handed to someone cold: the position contains everything
/// needed to solve it, and failing teaches them to look harder. An opening, an
/// endgame technique and a positional idea are not like that — they are
/// knowledge. Showing somebody the Lucena position and marking them wrong
/// teaches nothing, because there was nothing in the position to work it out
/// from. They had either been told or they had not.
///
/// So this arrives before the exercise, exactly once per concept. Everything
/// after is practice.
///
/// ## Three parts, not a paragraph
///
/// *What it is*, *why it matters*, *what to look for* answer three different
/// questions, and a reader skimming for the third should not have to read the
/// first two to find it. The cue is stressed because it is the only part that
/// survives to the next game — and its first sentence is repeated in the banner
/// after the exercise, so the two halves of the idea are said the same way both
/// times.
///
/// It sits directly under the board rather than at the end. Adding the position
/// pushed the card past a screen, and the cue — the one line meant to be
/// remembered — went below the fold behind the button, while "why it matters",
/// which is the argument for caring, kept the space above it. The picture and
/// the instruction now arrive together.
struct ConceptLessonView: View {

    let concept: TrainingConcept
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    section("The idea", concept.teaching.idea)
                    boardPreview
                    cue
                    moveList
                    section("Why it matters", concept.teaching.why)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            VStack(spacing: 8) {
                Text(nextStep)
                    .typeRole(.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(startTitle) { onStart() }
                    .buttonStyle(.primaryAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
    }

    /// What the button leads to, named rather than implied.
    ///
    /// "Try it" was a promise the endgame concepts do not keep: their exercise
    /// is a drill that runs on its own screen *after* the set's puzzles, so the
    /// tap opened a tactics puzzle instead. A button that says what will happen
    /// is cheaper than a button that has to be forgiven.
    private var startTitle: String {
        switch concept.exercise {
        case .drill: "Got it"
        case .line: "Play the line"
        case .corpusFeature: "Try it"
        }
    }

    /// The step after the tap, with its cost.
    ///
    /// A drill is up to six positions of up to sixty moves each, arriving on
    /// top of a set whose length the user chose. Nothing said so until the
    /// board appeared.
    private var nextStep: String {
        switch concept.exercise {
        case let .drill(kind):
            let positions = EndgameDrill.drills(kind: kind).count
            let budget = EndgameDrillTuning.default.moveBudget(
                for: kind,
                curriculum: DomainTuning.default.curriculum
            )
            let count = positions == 1 ? "one position" : "\(positions) positions"
            return "Your puzzles come first. Then you play this against the engine — "
                + "\(count), up to \(budget) moves each."
        case let .line(_, moves, opponentMovesFirst):
            let yours = opponentMovesFirst ? moves.count / 2 : (moves.count + 1) / 2
            return "You play \(yours) moves of this line; the replies answer themselves."
        case .corpusFeature:
            return "One position, one move to find."
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(concept.family.label.uppercased())
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text(concept.title)
                .typeRole(.title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The idea as a position, directly under the sentence describing it.
    ///
    /// Placed after "the idea" and before "why it matters" on purpose: it is
    /// the illustration of the first, and the reader who skims should hit the
    /// picture before the argument.
    @ViewBuilder
    private var boardPreview: some View {
        if let preview = concept.preview {
            VStack(spacing: 8) {
                BoardView(
                    position: preview.position,
                    orientation: preview.orientation,
                    interaction: .locked,
                    style: BoardAppearance.shared.style
                )
                .frame(maxWidth: 280)
                .accessibilityHidden(true)

                if let caption = concept.previewCaption {
                    Text(caption)
                        .typeRole(.caption)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The line itself, written out, for a concept whose exercise is a line.
    ///
    /// The screen's whole argument — at the top of this file — is that an
    /// opening is knowledge, and that testing knowledge nobody was given
    /// teaches nothing. The lesson then described the London's idea in three
    /// moves and the exercise asked for eight in order. Nothing named moves
    /// four to eight, so a reader who understood every word still had to guess
    /// that move seven was the c-pawn rather than the knight — and Nc3 looks
    /// like the more natural move of the two. That is not a test of whether
    /// they were listening.
    ///
    /// Their own moves are the ones set in full strength: the replies are here
    /// so the sequence reads as a game rather than a list, but they are not
    /// what is being learned, and the exercise plays them automatically.
    @ViewBuilder
    private var moveList: some View {
        let moves = PuzzleConcept.lineMoves(for: concept)
        if !moves.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("The moves")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: 10, alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(moves) { move in
                        HStack(spacing: 4) {
                            Text("\(move.number).")
                                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                                .foregroundStyle(.tertiary)
                            Text(move.user)
                                .typeRole(.body, appliesForeground: false)
                                .fontWeight(.semibold)
                            if let reply = move.reply {
                                Text(reply)
                                    .typeRole(.body, appliesForeground: false)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            move.reply.map { "Move \(move.number). You play \(move.user). They reply \($0)." }
                                ?? "Move \(move.number). You play \(move.user)."
                        )
                    }
                }

                Text("You play the moves in bold. Their replies are played for you.")
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
            Text(body)
                .typeRole(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cue gets the card, because it is the part meant to be remembered.
    private var cue: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to look for")
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(Palette.accent.dynamic)
            Text(concept.teaching.lookFor)
                .typeRole(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Palette.accentWash.dynamic)
        )
    }
}
