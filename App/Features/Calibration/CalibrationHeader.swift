//
//  CalibrationHeader.swift
//  ChessCoach
//

import SwiftUI

/// `Game 3 of 5 ⌄` on the left, `STEP 2 OF 4` on the right, and a sectioned bar
/// under both.
///
/// Every calibration screen carries this, including the question and the reveal,
/// so the flow's length is never something the user has to infer from how tired
/// they are. Two numbers, answering two different questions: the counter says
/// where you are inside the thing you are doing right now, the qualifier says
/// how much of the whole thing there is.
///
/// The counter is the disclosure. Making the *number* tappable rather than
/// adding a separate control is the trick worth keeping — the user who wonders
/// "is any of this optional?" is already looking straight at it, so that is
/// where the answer lives.
///
/// The whole line is `.caption` and `.secondary`: it is orientation, not
/// content, and a bold progress line at the top of a board screen competes with
/// the position.
struct CalibrationHeader: View {

    let progress: CalibrationProgress
    /// Defaults to the phase's own step so the two board screens need not
    /// restate what their phase already says.
    var step: CalibrationStep

    @State private var isShowingSteps = false

    init(progress: CalibrationProgress, step: CalibrationStep? = nil) {
        self.progress = progress
        self.step = step ?? progress.phase.step
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                isShowingSteps.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    counter
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isShowingSteps ? 180 : 0))
                    Spacer(minLength: 8)
                    Text("Step \(step.position) of \(CalibrationStep.count)")
                        .typeRole(.label, monospacedDigits: true, appliesForeground: false)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Shows every step of calibration")

            if isShowingSteps {
                stepList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            SectionedProgressBar(
                fractions: progress.sectionFractions,
                weights: progress.sectionWeights
            )
        }
        .animation(Motion.snappy, value: isShowingSteps)
        .animation(Motion.snappy, value: progress)
    }

    // MARK: Counter

    /// The item counter on the two working steps, and the step's own name on the
    /// two that have nothing to count. Neither the question nor the reveal has
    /// items, and inventing a `1 of 1` for them would be a number that carries
    /// no information dressed as one that does.
    @ViewBuilder
    private var counter: some View {
        switch step {
        case .games, .puzzles:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(progress.phase.itemNoun)
                    .typeRole(.caption)
                DenominatorText(
                    .of(progress.currentPosition, progress.currentRequired),
                    role: .caption
                )
            }
        case .question, .result:
            Text(step.title)
                .typeRole(.caption)
        }
    }

    private var accessibilityLabel: String {
        let position = "Step \(step.position) of \(CalibrationStep.count)"
        switch step {
        case .games, .puzzles: return "\(progress.counterLabel). \(position)"
        case .question, .result: return "\(step.title). \(position)"
        }
    }

    // MARK: Step list

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CalibrationStep.allCases) { entry in
                stepRow(entry)
            }

            // The line the disclosure exists to deliver. A first-run user
            // opening this is asking whether the twenty puzzles are a tax on
            // top of the five games; they are not, and saying so is cheaper
            // than letting them find out by finishing.
            Text("Both halves feed one number. Nothing here is practice.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    private func stepRow(_ entry: CalibrationStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(for: entry))
                .font(.caption2)
                // The accent marks the current step and nothing else here.
                // Completed steps carry a filled check, which is a shape rather
                // than a colour and therefore survives any vision difference.
                .foregroundStyle(entry == step ? Palette.accent.dynamic : Color.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(entry == step ? .primary : .secondary)
                Text(entry.contribution)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let tally = tally(for: entry) {
                Text(tally)
                    .typeRole(.caption, monospacedDigits: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func symbol(for entry: CalibrationStep) -> String {
        if entry.position < step.position { return "checkmark.circle.fill" }
        if entry == step { return "circle.dashed" }
        return "circle"
    }

    /// Counts belong only to the steps that have items.
    private func tally(for entry: CalibrationStep) -> String? {
        guard let phase = CalibrationPhase.allCases.first(where: { $0.step == entry }) else {
            return nil
        }
        let done = progress.completed[safe: phase.rawValue] ?? 0
        let total = progress.required[safe: phase.rawValue] ?? 0
        return "\(done)/\(total)"
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
                        Capsule().fill(Palette.surfaceSunken.dynamic)
                        Capsule()
                            .fill(Palette.accent.dynamic)
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
            progress: CalibrationProgress(required: [5, 20], completed: [0, 0], phaseIndex: 0),
            step: .question
        )
        CalibrationHeader(
            progress: CalibrationProgress(required: [5, 20], completed: [2, 0], phaseIndex: 0)
        )
        CalibrationHeader(
            progress: CalibrationProgress(required: [5, 20], completed: [5, 9], phaseIndex: 1)
        )
        CalibrationHeader(
            progress: CalibrationProgress(required: [5, 20], completed: [5, 20], phaseIndex: 1),
            step: .result
        )
    }
    .padding()
    .background(Palette.surfaceGround.dynamic)
}
