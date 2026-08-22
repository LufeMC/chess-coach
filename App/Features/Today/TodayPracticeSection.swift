//
//  TodayPracticeSection.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Everything the user can do *beyond* today's plan.
///
/// ## Why it is a list and not a shelf
///
/// The Train tab used to offer a grid of drills beside the daily set, and the
/// effect was that endgames got practised by exactly the people who already knew
/// they mattered — everyone else did the puzzles, because the puzzles had the
/// button. So the plan above stays the one recommendation, and this is the
/// answer to "what if I want more", which is a different question and deserves a
/// quieter answer.
///
/// ## Why nothing here is counted
///
/// The streak and the day's total both key on the loop's three steps. A
/// calculation set that ticked the day would let "Done for today" arrive without
/// a game, which is the one thing the loop is for. The caption says so out loud
/// rather than leaving the user to discover that extra work moved no number.
struct PracticeMoreSection: View {

    let calculationSupply: Int
    let calculationBand: ClosedRange<Int>?
    let dueCount: Int
    let taughtCount: Int
    let conceptCount: Int
    let canRepeatSet: Bool
    let onAnotherSet: () -> Void
    let onCalculation: () -> Void
    let onTraining: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Practice more", qualifier: nil)

            Text("Extra work, on top of today's plan — not counted in the time above.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                if canRepeatSet {
                    PracticeRow(
                        symbol: "square.grid.3x3.fill",
                        title: "Another set",
                        trailing: "10 puzzles",
                        action: onAnotherSet
                    )
                    Divider().padding(.leading, 60)
                }

                if calculationSupply > 0 {
                    PracticeRow(
                        symbol: "arrow.triangle.branch",
                        title: "Calculation",
                        trailing: "\(calculationSupply) puzzles · no clock",
                        action: onCalculation
                    )
                } else {
                    // A dim row with its reason, never a disabled button: the
                    // rule the user is bumping into — this set only ever draws
                    // from above them — is the explanation, and hiding the row
                    // would make training look broken instead of finished.
                    PracticeRow(
                        symbol: "arrow.triangle.branch",
                        title: "Calculation",
                        trailing: calculationBand.map { "nothing rated \($0.lowerBound)–\($0.upperBound)" }
                            ?? "nothing above you yet",
                        action: nil
                    )
                }

                if dueCount > 0 {
                    Divider().padding(.leading, 60)
                    // Informational, not a door. Due cards are served inside the
                    // daily set automatically; a button here would offer a
                    // second way to do work the plan already schedules.
                    PracticeRow(
                        symbol: "clock.arrow.circlepath",
                        title: "Due for review",
                        trailing: dueCount == 1 ? "1 card, in today's set" : "\(dueCount) cards, in today's set",
                        action: nil
                    )
                }

                Divider().padding(.leading, 60)

                PracticeRow(
                    symbol: "books.vertical.fill",
                    title: "Your training",
                    trailing: "\(taughtCount) of \(conceptCount) taught",
                    action: onTraining
                )
            }
            .padding(.horizontal, 16)
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
    }
}

/// One line of the practice list.
private struct PracticeRow: View {

    let symbol: String
    let title: String
    let trailing: String
    /// `nil` when the row has nothing to open, which dims it and drops the
    /// chevron rather than presenting a control that does nothing.
    let action: (() -> Void)?

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceSunken.dynamic))

                Text(title)
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(action == nil ? .secondary : .primary)

                Spacer(minLength: 8)

                Text(trailing)
                    .typeRole(.caption)
                    .multilineTextAlignment(.trailing)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel("\(title). \(trailing)")
    }
}

// MARK: - Due row

/// One due card: a decay ring, the concept, and how well the theme is known.
private struct DueCardRow: View {

    let card: DueCardPresentation

    var body: some View {
        HStack(spacing: 12) {
            RecallRing(recall: card.recall)
                .frame(width: 22, height: 22)

            Text(card.subtitle)
                .typeRole(.body)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.subtitle)
        .accessibilityValue("\(Int((card.recall * 100).rounded())) percent recalled")
    }
}

/// How much of this card is still remembered.
///
/// The ring empties as the memory decays, which is the one thing about spaced
/// repetition worth showing: it explains *why* this card is here today without
/// putting a stability figure or an interval on screen for the user to optimise
/// against. Drawn in the accent's own family rather than red at the low end — a
/// card the scheduler expects to be forgotten is working exactly as designed.
private struct RecallRing: View {

    let recall: Double

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.surfaceSunken.dynamic, lineWidth: 3)

            Circle()
                .trim(from: 0, to: max(0.02, min(1, recall)))
                .stroke(Palette.accent.dynamic, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Set length

/// The three session lengths, all of them visible, one tap to change.
///
/// Not a `Menu`. The platform picker hides three short numbers behind a tap and
/// a system sheet, which is a lot of ceremony for the only choice on the screen
/// — and it renders as someone else's control in the middle of a hand-built
/// one. With the focus decision gone there is room to simply show them.
///
/// The selected pill is *raised*, not accented: this screen's one accent is
/// spent on `Start`, and a second filled accent would make the user read both
/// to find out which one is the action.
struct LengthSelector: View {

    let lengths: [Int]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(lengths, id: \.self) { length in
                segment(length)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.chip + 4, style: .continuous)
                .fill(Palette.surfaceSunken.dynamic)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set length")
    }

    private func segment(_ length: Int) -> some View {
        let isSelected = length == selection
        return Button {
            withAnimation(Motion.crossfade) { selection = length }
        } label: {
            VStack(spacing: 1) {
                Text("\(length)")
                    .typeRole(.headline, monospacedDigits: true, appliesForeground: false)
                Text("puzzles")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                    .fill(isSelected ? Palette.surfaceRaised.dynamic : .clear)
                    .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 3, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(length) puzzles")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Promotion

/// The rung the user has earned, offered once.
///
/// Deliberately a row and not a modal. `Docs/DesignBrief.md` reserves
/// celebration for rung completion "at most", and even then restrained — so this
/// is a line of type, the rung's own name, and one bordered button. No confetti,
/// no medal, no sheet to dismiss: the reward for clearing a rung is the next
/// rung, and dressing it up would make the next four weeks of work look like the
/// price of an animation.
///
/// The button is bordered rather than filled because `Start` is this screen's one
/// filled action, and today's session is still the thing to do.
struct PromotionRow: View {

    let promotion: TrainHomeModel.Promotion
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // "Rung" stays — it is what Profile's ladder calls the same number,
            // and two words for one thing is worse than one unfamiliar word.
            // What was missing is what it means and what accepting it changes.
            Text("Rung \(promotion.rung)")
                .typeRole(.label)

            Text(promotion.title)
                .typeRole(.headline)

            Text("The ladder's next step is unlocked: every required skill on your current rung is "
                + "met. Moving up raises the puzzle difficulty and changes what your sets practise.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Button("Move up to rung \(promotion.rung)", action: onAccept)
                .buttonStyle(.secondaryAction)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}
