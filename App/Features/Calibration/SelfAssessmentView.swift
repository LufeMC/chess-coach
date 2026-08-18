//
//  SelfAssessmentView.swift
//  ChessCoach
//

import SwiftUI

/// `How much chess have you played?` — the question that opens calibration.
///
/// Radio rows, each with a signal-bars glyph that fills progressively. The bars
/// do the work a number would do badly: the four answers are ordered but the
/// gaps between them are not measurable, so bars claim "more than the one above"
/// and stop there.
///
/// The selected row gets all three of a tinted fill, an accent border and an
/// accent label. Redundant on purpose — a single tint is easy to miss at a
/// glance and impossible to see at all with a strong colour-vision deficiency,
/// and this is the one control on the screen.
struct SelfAssessmentView: View {

    let selection: ChessExperience?
    let onSelect: (ChessExperience) -> Void
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Let's find your level")
                        .font(.title2.bold())

                    // Said once, here, and never repeated between phases.
                    Text(CalibrationModel.framingLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("How much chess have you played?")
                    .font(.headline)
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
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selection == nil)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.regularMaterial)
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
                SignalBars(filled: experience.bars, isSelected: isSelected)
                    .frame(width: 22, height: 18)

                Text(experience.title)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Four bars of increasing height, `filled` of them lit.
private struct SignalBars: View {

    let filled: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint(for: index))
                    .frame(width: 3.5, height: 5 + CGFloat(index - 1) * 4.2)
            }
        }
        .accessibilityHidden(true)
    }

    private func tint(for index: Int) -> Color {
        guard index <= filled else { return Color.secondary.opacity(0.25) }
        return isSelected ? Color.accentColor : Color.primary.opacity(0.55)
    }
}

#Preview {
    SelfAssessmentView(selection: .playsRegularly, onSelect: { _ in }, onContinue: {})
}
