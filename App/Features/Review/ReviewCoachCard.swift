import AnalysisKit
import SwiftUI
import TrainingCore

/// The coach's read on one position.
///
/// Ordered as a diagnosis rather than as a paragraph with a heading: the cause
/// the analysis settled on, the step of the move routine it belongs to, then the
/// sentences that prove both. The label above the prose is the same one the
/// Profile leak table uses for this cause, which is what lets a reader connect
/// the move they just lost a piece to with the row costing them the most rating.
///
/// ## The question comes first
///
/// The note is covered until the reader asks for it. The best-written coaching
/// copy in the app — "Before you let go of that piece, what would be attacking
/// it on the square you picked?" — used to sit inside a sheet *behind* the
/// answer, which defeats the whole point of asking: a student who has been asked
/// what the piece was doing on that square reads the answer differently from one
/// who was handed it. The self-check already proves the app is willing to
/// withhold; this does it per moment.
///
/// Uncovering is also what counts the moment as reviewed. It is the one act on
/// this screen that requires the reader to have looked at the position first —
/// selecting a thumbnail is not, which is why the day's "Review 3 moments" used
/// to be satisfiable by opening the screen and tapping twice.
///
/// The whole note is shown once uncovered. It is budgeted to 400 characters and
/// written as happened → proof → step, so clipping it to three lines cut it in
/// the middle of the proof and put the only clause a player can act on tomorrow
/// below the fold.
struct ReviewCoachCard: View {

    let note: String
    /// The cause and the thinking step it belongs to.
    let diagnosis: ReviewDiagnosis
    /// Context line, e.g. `"Move 23 · Blunder"`.
    var subtitle: String?
    /// The Socratic lead-in. `nil` on a praised move and on a moment no detector
    /// explained, where there is nothing honest to ask.
    var question: String?
    /// Questions the app can answer from its own data.
    var suggestedQuestions: [ReviewSuggestedQuestion] = []
    /// Which answers are uncovered.
    ///
    /// Owned by the model rather than by this card, because one of the answers
    /// is also drawn on the board — the engine's move as an arrow — and the
    /// board is not this card's to draw on.
    var revealedQuestionIDs: Set<String> = []
    var onToggleQuestion: (String) -> Void = { _ in }
    /// Called the first time the reader uncovers the note.
    var onReveal: () -> Void = {}
    /// Sends the reader to Train, filtered to this moment's habit.
    var onDrill: ((Habit) -> Void)? = nil

    @State private var isNoteShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let step = diagnosis.step {
                stepRow(step)
            }

            if let question, !isNoteShown {
                ask(question)
            } else {
                prose

                if !isNoteShown {
                    // Nothing to ask on this one, so the note is already
                    // legible. The button is what makes reading it a deliberate
                    // act rather than a side effect of scrolling past.
                    Button("Mark this one reviewed") { reveal() }
                        .buttonStyle(.primaryAction)
                        .padding(.top, 2)
                } else {
                    if !suggestedQuestions.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(suggestedQuestions) { suggestion in
                                questionChip(suggestion)
                            }
                        }
                        .padding(.top, 2)
                    }
                    drillRow
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .animation(Motion.contentSwap, value: revealedQuestionIDs)
        .animation(Motion.contentSwap, value: isNoteShown)
    }

    /// The Socratic lead-in, and the only way past it.
    private func ask(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question)
                .typeRole(.headline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Button("Show the answer") { reveal() }
                .buttonStyle(.primaryAction)
        }
    }

    private func reveal() {
        guard !isNoteShown else { return }
        isNoteShown = true
        onReveal()
    }

    /// The way from a mistake to the drill for it.
    ///
    /// The app exists to run play → review → drill, and until this row the last
    /// element on the screen was a disclosure triangle: the user finished
    /// reading why they lost a piece and had nowhere to go with it.
    @ViewBuilder
    private var drillRow: some View {
        if let onDrill, let habit = suggestedQuestions.compactMap(\.habit).first {
            Button {
                onDrill(habit)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "target")
                        .font(.caption)
                    Text("Drill this in Train · \(habit.microGoalTitle)")
                        .typeRole(.caption, appliesForeground: false)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Palette.accent.dynamic)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                        .strokeBorder(Palette.accent.dynamic.opacity(0.45), lineWidth: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous))
            }
            .buttonStyle(.pressable)
            .padding(.top, 2)
        }
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

    /// The whole note, unclipped.
    ///
    /// No `lineLimit`. The note is bounded at ``MomentExplainer/characterBudget``
    /// characters and its last clause is the step to take at the board, so three
    /// reserved lines hid the mechanism and kept the diagnosis the reader had
    /// already seen in the title.
    private var prose: some View {
        Text(note)
            .typeRole(.body)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Suggested questions

    /// A question and, once tapped, the answer underneath it.
    ///
    /// Full-width rather than a pair of pills: these are sentences, and two
    /// sentences side by side on a phone wrap to three lines each.
    private func questionChip(_ suggestion: ReviewSuggestedQuestion) -> some View {
        let isRevealed = revealedQuestionIDs.contains(suggestion.id)

        return Button {
            onToggleQuestion(suggestion.id)
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

                    if suggestion.arrowUCI != nil {
                        // Says where to look. Without it the arrow appearing on
                        // a board four inches away is a change nobody is
                        // watching for.
                        Text("It is drawn on the board.")
                            .typeRole(.caption, appliesForeground: false)
                            .foregroundStyle(.tertiary)
                    }
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

#Preview("Coach card") {
    ScrollView {
        VStack(spacing: 16) {
            ReviewVerdictCard(
                verdict: GameSummary(
                    headline: "The middlegame is where this one was decided",
                    body: """
                    You played 71% accuracy over 34 moves. Moving a piece onto a square it \
                    could be taken on came up twice — that is the pattern, not the individual \
                    moves. Tap each position below and find the better move yourself before you
                    open the coach's note.
                    """
                )
            )

            ReviewCoachCard(
                note: """
                    Nxe5 put your knight on e5, where it can just be taken. Rxe5 takes it — two \
                    attackers to one defender on e5, about three pawns. One blunder check before \
                    releasing the piece is all this needed.
                    """,
                diagnosis: ReviewDiagnosis(title: "Hanging pieces", step: "Blunder check"),
                subtitle: "Move 23 · Blunder",
                question: CoachingQuestions.question(forCauseTag: .hungMovedPiece),
                suggestedQuestions: [
                    ReviewSuggestedQuestion(
                        id: "best",
                        question: "What should I have played?",
                        answer: "Re8 — the line runs Re8 Nxe5 Rxe5. Set the position up and play "
                            + "Nxe5 instead: the answer is Rxe5."
                    ),
                    ReviewSuggestedQuestion(
                        id: "habit",
                        question: "How do I catch this next time?",
                        answer: ReviewSuggestedQuestions.habitInstruction(.blunderCheck),
                        habit: .blunderCheck
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
