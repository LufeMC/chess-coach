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

                    Text(question.explanation)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(index + 1 < total ? "Next question" : "Show the review") { onNext() }
                        .buttonStyle(.primaryAction)
                }
                .transition(.opacity)
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
            if !isRevealed {
                Button("Skip") { onSkip() }
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
            }
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
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isRevealed && isAnswer ? [.isSelected] : [])
    }
}
