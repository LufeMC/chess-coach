import AnalysisKit
import SwiftUI

/// The coach's read on one position.
///
/// Ordered as a diagnosis rather than as a paragraph with a heading: the cause
/// the analysis settled on, the step of the move routine it belongs to, then the
/// sentences that prove both. The label above the prose is the same one the
/// Profile leak table uses for this cause, which is what lets a reader connect
/// the move they just lost a piece to with the row costing them the most rating.
///
/// Bounded on purpose. The prose slot always reserves exactly three lines and
/// the rest of the note sits behind the pill, so the card is the same height for
/// every moment in the strip and the filmstrip above it never moves under the
/// finger that just tapped it.
struct ReviewCoachCard: View {

    let note: String
    /// The cause and the thinking step it belongs to.
    let diagnosis: ReviewDiagnosis
    /// Context line, e.g. `"Move 23 · Blunder"`.
    var subtitle: String?
    /// The Socratic lead-in, shown at the top of the detail sheet where there is
    /// room to sit with it.
    var question: String?
    /// Questions the app can answer from its own data.
    var suggestedQuestions: [ReviewSuggestedQuestion] = []

    @State private var isShowingDetail = false
    @State private var revealedQuestionIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let step = diagnosis.step {
                stepRow(step)
            }
            prose
            footer

            if !suggestedQuestions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(suggestedQuestions) { suggestion in
                        questionChip(suggestion)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .animation(Motion.contentSwap, value: revealedQuestionIDs)
    }

    // MARK: Header

    /// The cause on the left, the position on the right.
    ///
    /// The cause takes the card's title slot because it is the finding; a header
    /// that named the feature instead would spend the most legible line on the
    /// word "Coach", which tells the reader nothing they did not know from
    /// having opened the screen.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(diagnosis.title)
                .typeRole(.label, appliesForeground: false)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let subtitle {
                Text(subtitle)
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
        }
    }

    /// Which step of the move routine this belongs to.
    ///
    /// Plain text rather than a filled chip, because the two rounded rects below
    /// are buttons: a third one that does nothing when tapped teaches the reader
    /// that the shape means nothing.
    private func stepRow(_ step: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(step)
                .typeRole(.caption)
            Spacer(minLength: 0)
        }
    }

    // MARK: Prose

    private var prose: some View {
        Text(note)
            .typeRole(.body)
            .lineLimit(3, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One line, always, so the card keeps its height across a selection change.
    private var footer: some View {
        Button {
            isShowingDetail = true
        } label: {
            Text("Go deeper")
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(Palette.accent.dynamic)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Palette.surfaceSunken.dynamic))
        }
        .buttonStyle(.pressable)
        .sheet(isPresented: $isShowingDetail) {
            ReviewCoachDetail(note: note, question: question, subtitle: subtitle)
        }
    }

    // MARK: Suggested questions

    /// A question and, once tapped, the answer underneath it.
    ///
    /// Full-width rather than a pair of pills: these are sentences, and two
    /// sentences side by side on a phone wrap to three lines each.
    private func questionChip(_ suggestion: ReviewSuggestedQuestion) -> some View {
        let isRevealed = revealedQuestionIDs.contains(suggestion.id)

        return Button {
            if isRevealed {
                revealedQuestionIDs.remove(suggestion.id)
            } else {
                revealedQuestionIDs.insert(suggestion.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(suggestion.question)
                        .typeRole(.caption, appliesForeground: false)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: isRevealed ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if isRevealed {
                    Text(suggestion.answer)
                        .typeRole(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                    .fill(Palette.surfaceSunken.dynamic)
            )
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityHint(isRevealed ? "Hides the answer" : "Shows the answer")
    }
}

// MARK: - Verdict

/// The game's one-line verdict, and the paragraph under it.
///
/// Separate from ``ReviewCoachCard`` because it answers a different question:
/// the card explains one position, and this says what the game amounted to. It
/// sits above every number on the screen, because a verdict arriving after four
/// statistics is a caption, not a verdict.
struct ReviewVerdictCard: View {

    let verdict: GameSummary

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.accent.dynamic)
                Text("Verdict")
                    .typeRole(.label)
                Spacer(minLength: 0)
            }

            Text(verdict.headline)
                .typeRole(.headline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !verdict.body.isEmpty {
                Text(verdict.body)
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)

                Button(isExpanded ? "Less" : "More") {
                    isExpanded.toggle()
                }
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(Palette.accent.dynamic)
                .buttonStyle(.pressable)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .animation(Motion.standard, value: isExpanded)
    }
}

// MARK: - Sheet

/// The full note, behind the pill.
///
/// The question comes first and the explanation second, which is the order a
/// coach would use: a student who has been asked what the piece was doing on
/// that square reads the answer differently from one who was handed it.
private struct ReviewCoachDetail: View {
    let note: String
    let question: String?
    let subtitle: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let subtitle {
                        Text(subtitle)
                            .typeRole(.caption)
                    }
                    if let question {
                        Text(question)
                            .typeRole(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(note)
                        .typeRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
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

#Preview("Coach card") {
    ScrollView {
        VStack(spacing: 16) {
            ReviewVerdictCard(
                verdict: GameSummary(
                    headline: "The middlegame is where this one was decided",
                    body: """
                    You played 71% accuracy over 34 moves. Moving a piece onto a square it \
                    could be taken on came up twice — that is the pattern, not the individual \
                    moves. Work through the positions below on a board before you read the lines.
                    """
                )
            )

            ReviewCoachCard(
                note: """
                    Nxe5 put your knight on e5, where it can just be taken. Rxe5 takes it — two \
                    attackers to one defender on e5, 310cp. Step 5, the blunder check, is what \
                    would have caught this.
                    """,
                diagnosis: ReviewDiagnosis(title: "Hanging pieces", step: "Step 5 · Blunder check"),
                subtitle: "Move 23 · Blunder",
                question: CoachingQuestions.question(forCauseTag: .hungMovedPiece),
                suggestedQuestions: [
                    ReviewSuggestedQuestion(
                        id: "best",
                        question: "What should I have played?",
                        answer: "Re8 — the engine's move in this position."
                    ),
                    ReviewSuggestedQuestion(
                        id: "habit",
                        question: "How do I catch this next time?",
                        answer: "Blunder-check every move"
                    ),
                ]
            )

            ReviewCoachCard(
                note: """
                    Rxe5 was the engine's first choice, and the position genuinely branched \
                    here — the next-best line was 0.18 of a point worse. Note what made you \
                    look at this move; that is the habit worth repeating.
                    """,
                diagnosis: ReviewDiagnosis(title: ReviewDiagnoses.praiseTitle),
                subtitle: "Move 24 · Great"
            )
        }
        .padding()
    }
    .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
}
