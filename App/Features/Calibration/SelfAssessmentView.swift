//
//  SelfAssessmentView.swift
//  ChessCoach
//

import BoardUI
import SwiftUI

/// `How much chess have you played?` — the question that opens calibration.
///
/// Radio rows, each with a signal-bars glyph that fills progressively. The bars
/// do the work a number would do badly: the four answers are ordered but the
/// gaps between them are not measurable, so bars claim "more than the one above"
/// and stop there.
///
/// The selected row gets a tinted fill, an accent border, and a filled radio
/// glyph. Redundant on purpose — a single tint is easy to miss at a glance and
/// impossible to see at all with a strong colour-vision deficiency, and the
/// glyph is a *shape* change, which is the only redundancy that always works.
///
/// ## The escape hatch
///
/// The seed is genuinely optional: `CalibrationSeed.opponentRating(for: nil)`
/// exists and starts the ladder at 1100. A user who does not want to place
/// themselves — which is most people who have no idea, and some who do — must
/// therefore be able to move on, or the app has gated itself behind a question
/// it does not need answered.
struct SelfAssessmentView: View {

    let progress: CalibrationProgress
    let selection: ChessExperience?
    let onSelect: (ChessExperience) -> Void
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CalibrationHeader(progress: progress, step: .question)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Let's find your level")
                        .typeRole(.title)

                    // Said once, here, and never repeated between phases.
                    Text(CalibrationModel.framingLine)
                        .typeRole(.body, appliesForeground: false)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The cost and the escape, on the screen where the user is
                    // deciding whether to spend the evening on this.
                    Text(CalibrationModel.costLine)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)

                    // And what the hour buys, which until now was answered for
                    // the first time by the reveal at the end of it.
                    Text(CalibrationModel.payoffLine)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The question is the content of this screen, not a label on a
                // section of it, so it keeps a content role rather than being
                // demoted into small caps.
                Text("How much chess have you played?")
                    .typeRole(.headline)
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    ForEach(ChessExperience.allCases) { experience in
                        ExperienceRow(
                            experience: experience,
                            isSelected: selection == experience,
                            onTap: { onSelect(experience) }
                        )
                    }
                }

                // The escape hatch, said as a fact rather than offered as a
                // second button. Leaving the question unanswered is a supported
                // path, so the only thing missing was somebody saying so.
                if selection == nil {
                    Text(
                        "Not sure? Leave it — the first opponent plays at about club-beginner level, and each game after that gets harder or easier depending on how the last one went."
                    )
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .animation(Motion.crossfade, value: selection)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            // Names the step and its cost rather than saying `Continue`, and is
            // never disabled: the question seeds the measurement, it does not
            // gate it.
            Button("Play game 1 · 15 min on your clock", action: onContinue)
                .buttonStyle(.primaryAction)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(Palette.surfaceGround.dynamic)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Palette.hairline.dynamic)
                        .frame(height: 2)
                }
        }
    }
}

private struct ExperienceRow: View {

    let experience: ChessExperience
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                SignalBars(filled: experience.bars)
                    .frame(width: 22, height: 18)

                Text(experience.title)
                    .typeRole(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Palette.accent.dynamic : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .elevation(
                .raised,
                cornerRadius: CornerRadius.card,
                fill: isSelected ? Palette.accent.opacity(0.12) : nil
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? Palette.accent.dynamic : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Four bars of increasing height, `filled` of them lit.
///
/// Never accented. The bars are a description of the answer, not the selection
/// — tinting them too would spend the screen's accent on decoration and leave
/// the radio glyph saying the same thing twice.
private struct SignalBars: View {

    let filled: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(
                        index <= filled
                            ? Color.primary.opacity(0.55)
                            : Palette.inactiveMark.dynamic
                    )
                    .frame(width: 3.5, height: 5 + CGFloat(index - 1) * 4.2)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Answered") {
    SelfAssessmentView(
        progress: CalibrationProgress(),
        selection: .playsRegularly,
        onSelect: { _ in },
        onContinue: {}
    )
}

#Preview("Unanswered") {
    SelfAssessmentView(
        progress: CalibrationProgress(),
        selection: nil,
        onSelect: { _ in },
        onContinue: {}
    )
}
