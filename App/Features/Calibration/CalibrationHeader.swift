//
//  CalibrationHeader.swift
//  ChessCoach
//

import SwiftUI

/// `Game 3 of 5 — Calibration games ⌄`, with the phase list behind the chevron.
///
/// SoFi's onboarding header. The counter is monospaced so the digits do not
/// jitter between items, and the whole line is `.secondary` — it is orientation,
/// not content, and a bold progress line at the top of a board screen competes
/// with the position.
///
/// The phase name is the disclosure. Making the *name* tappable rather than
/// adding a separate control is the trick worth keeping: the user who wonders
/// "what else is there?" is already looking straight at the phase name, so that
/// is where the answer should be.
struct CalibrationHeader: View {

    let progress: CalibrationProgress
    @State private var isShowingPhases = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                isShowingPhases.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(progress.counterLabel)
                        .monospacedDigit()
                    Text("—")
                    Text(progress.phase.title)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isShowingPhases ? 180 : 0))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isShowingPhases {
                phaseList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            SectionedProgressBar(
                fractions: progress.sectionFractions,
                weights: progress.sectionWeights
            )
        }
        .animation(.snappy(duration: 0.22), value: isShowingPhases)
        .animation(.snappy(duration: 0.28), value: progress)
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(CalibrationPhase.allCases.enumerated()), id: \.element.id) { index, phase in
                HStack(spacing: 8) {
                    Image(systemName: symbol(forPhaseAt: index))
                        .font(.caption)
                        .foregroundStyle(index <= progress.phaseIndex ? Color.accentColor : .secondary)
                        .frame(width: 16)

                    Text(phase.title)
                        .font(.footnote)
                        .foregroundStyle(index == progress.phaseIndex ? .primary : .secondary)

                    Spacer()

                    Text("\(progress.completed[safe: index] ?? 0)/\(progress.required[safe: index] ?? 0)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
    }

    private func symbol(forPhaseAt index: Int) -> String {
        if index < progress.phaseIndex { return "checkmark.circle.fill" }
        if index == progress.phaseIndex { return "circle.dashed" }
        return "circle"
    }
}

/// One section per phase, hairline gaps between them, only the current section
/// filling.
///
/// The gaps are what carry the information a single bar cannot: they say the
/// flow has parts, and how many, without any text. See ``CalibrationProgress``
/// for why the sections are equal width rather than sized by item count.
struct SectionedProgressBar: View {

    let fractions: [Double]
    var weights: [Double] = []
    var height: CGFloat = 4
    var gap: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let resolved = weights.count == fractions.count ? weights : fractions.map { _ in 1 }
            let totalWeight = max(0.0001, resolved.reduce(0, +))
            let available = max(0, proxy.size.width - gap * CGFloat(max(0, fractions.count - 1)))

            HStack(spacing: gap) {
                ForEach(Array(fractions.enumerated()), id: \.offset) { index, fill in
                    let width = available * (resolved[index] / totalWeight)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(0, width * min(1, max(0, fill))))
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calibration progress")
    }
}

extension Array {
    /// Bounds-checked subscript, for header rows that render before the model
    /// has been sized.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    VStack(spacing: 30) {
        CalibrationHeader(
            progress: CalibrationProgress(required: [5, 20], completed: [2, 0], phaseIndex: 0)
        )
        CalibrationHeader(
            progress: CalibrationProgress(required: [5, 20], completed: [5, 9], phaseIndex: 1)
        )
    }
    .padding()
}
