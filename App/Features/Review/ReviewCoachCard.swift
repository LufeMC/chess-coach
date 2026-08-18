import BoardUI
import SwiftUI

/// The coach's read on one position.
///
/// Bounded on purpose. The card is a bordered rect with a fixed three-line prose
/// slot and a `Go deeper` pill, so the height it occupies while a note is being
/// generated is exactly the height it occupies afterwards — layout jump is
/// structurally impossible rather than merely unlikely. While generating it draws
/// its own skeleton at those same three line widths, with a label that names the
/// work instead of a spinner: "Analyzing move 23…" tells you what is happening,
/// a bouncing dot tells you only that something is.
struct ReviewCoachCard: View {

    let state: ReviewCoachState
    /// Context line, e.g. `"Move 23 · Blunder"`.
    let subtitle: String?

    @State private var isShowingDetail = false

    /// The three skeleton widths. Prose wraps short on the last line, and a
    /// skeleton whose last bar runs full width reads as a loading *bar*.
    private let skeletonWidths: [Double] = [1.0, 0.94, 0.58]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch state {
            case .unavailable:
                // Nothing to say and no error to report. The caller normally does
                // not render the card at all in this state; this branch exists so
                // a state change mid-flight cannot leave an empty box.
                Text("No coach note for this position.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)

            case .generating(let label):
                skeleton(label: label)

            case .ready(let text):
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

            case .failed(let reason):
                // States the fact and stops. No "don't worry" — reassurance would
                // imply the failure warranted distress.
                Text("Coach note unavailable. \(reason)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
            }

            if case .ready(let text) = state {
                Button {
                    isShowingDetail = true
                } label: {
                    Text("Go deeper")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.quaternary))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingDetail) {
                    ReviewCoachDetail(text: text, subtitle: subtitle)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Filled *and* bordered: the house style puts prose in a filled rect
            // (see design-conventions), and the border is what makes the card read
            // as a distinct voice rather than as another data panel.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Coach")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func skeleton(label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(skeletonWidths.enumerated()), id: \.offset) { _, fraction in
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: proxy.size.width * fraction, height: 11)
                    }
                }
            }
            .frame(height: 47)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // The label sits under the bars, in the leading position the prose will
        // occupy, so the eye does not have to move when the text arrives.
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

/// The full note, behind the pill.
private struct ReviewCoachDetail: View {
    let text: String
    let subtitle: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Coach")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}

#Preview("Coach card states") {
    VStack(spacing: 16) {
        ReviewCoachCard(
            state: .generating(label: "Analyzing move 23…"),
            subtitle: "Move 23 · Blunder"
        )
        ReviewCoachCard(
            state: .ready(
                """
                Nxe5 loses a piece to the pin on the e-file. Before taking, check what \
                is holding the knight — here nothing is. The habit to build is asking \
                what your opponent's last move attacked.
                """
            ),
            subtitle: "Move 23 · Blunder"
        )
    }
    .padding()
}
