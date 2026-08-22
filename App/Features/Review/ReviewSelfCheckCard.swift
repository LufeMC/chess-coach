//
//  ReviewSelfCheckCard.swift
//  ChessCoach
//

import SwiftUI

/// The questions a review opens with, one at a time.
///
/// ## Why this sits where the verdict sits
///
/// It replaces the verdict, the filmstrip and the coaching rather than sitting
/// above them, because a question you can scroll past the answer to is not a
/// question. The board, the scrubber and the move list stay live underneath:
/// the user is meant to *look* at the game to answer, and taking the game away
/// while asking about it would make this a memory test.
///
/// ## Marked immediately, and explained either way
///
/// The answer is marked the moment it is tapped, and the explanation is shown
/// whether it was right or wrong — being right for the wrong reason is the
/// most expensive habit this screen can leave in place.
struct ReviewSelfCheckCard: View {

    let question: ReviewSelfCheck.Question
    let index: Int
    let total: Int
    let chosen: Int?
    let onAnswer: (Int) -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    private var isRevealed: Bool { chosen != nil }
    private var isCorrect: Bool { chosen == question.correct }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text(question.prompt)
                .typeRole(.headline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { pair in
                    option(pair.element, at: pair.offset)
                }
            }

            if isRevealed {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verdictLine)
                        .typeRole(.caption, appliesForeground: false)
                        .foregroundStyle(isCorrect ? Palette.accent.dynamic : Palette.caution.dynamic)
                        // The marking is the point of the exercise, and it
                        // appears in place rather than as a new screen, so it
                        // has to be announced instead of waiting to be found.
                        .accessibilityAddTraits(.updatesFrequently)

                    Text(question.explanation)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(index + 1 < total ? "Next question" : "Show the review") { onNext() }
                        .buttonStyle(.primaryAction)
                }
                .transition(.opacity)
            }

            if !isRevealed {
                // A caption-sized, tertiary "Skip" next to the counter is a
                // control you hit by accident while reading the counter — and it
                // ends the exercise for the whole game. Full width, its own row,
                // and it says what it gives up.
                Button("Skip the questions · go straight to the review") { onSkip() }
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .buttonStyle(.pressable)
            }
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    private var header: some View {
        HStack {
            Text("Before the engine")
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(index + 1) of \(total)")
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .foregroundStyle(.tertiary)
        }
    }

    private var verdictLine: String {
        guard isCorrect else { return "Not that one — it was \(question.answer.label)." }
        return "That's it."
    }

    private func option(_ option: ReviewSelfCheck.Question.Option, at slot: Int) -> some View {
        // Once answered, the *right* answer is always marked, not merely the
        // one that was tapped: a user who guessed wrong needs to see where the
        // move actually was more than they need their own guess highlighted.
        let isAnswer = slot == question.correct
        let isChoice = slot == chosen
        let tint: Color? =
            isRevealed
            ? (isAnswer ? Palette.accent.dynamic : (isChoice ? Palette.caution.dynamic : nil))
            : nil

        return Button {
            onAnswer(slot)
        } label: {
            HStack(spacing: 8) {
                Text(option.label)
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(tint ?? .primary)
                Spacer(minLength: 0)
                if isRevealed, isAnswer {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.accent.dynamic)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                    .fill(Palette.surfaceSunken.dynamic)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                            .strokeBorder(tint ?? .clear, lineWidth: 1.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRevealed)
        // Colour is the only thing that separates "the right move" from "the one
        // you picked" on screen, and a VoiceOver user was hearing the correct
        // option announced as selected while their own answer read as a plain
        // button — the exact opposite of what happened.
        .accessibilityLabel(accessibilityLabel(isAnswer: isAnswer, isChoice: isChoice, label: option.label))
        .accessibilityAddTraits(isRevealed && isAnswer ? [.isSelected] : [])
    }

    private func accessibilityLabel(isAnswer: Bool, isChoice: Bool, label: String) -> String {
        guard isRevealed else { return label }
        switch (isAnswer, isChoice) {
        case (true, true): return "\(label), correct answer, your answer"
        case (true, false): return "\(label), correct answer"
        case (false, true): return "\(label), your answer, not correct"
        case (false, false): return label
        }
    }
}
