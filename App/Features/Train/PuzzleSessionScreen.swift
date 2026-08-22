//
//  PuzzleSessionScreen.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import SwiftUI
import TrainingCore

/// The solve surface: ten puzzles, one board, a banner between them.
struct PuzzleSessionScreen: View {

    @State private var model: PuzzleSessionModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// True while the opponent's setup move is playing.
    ///
    /// The Lichess convention is that move 1 of the stored line belongs to the
    /// *opponent*: it is the move that creates the tactic. Dropping the user
    /// straight into the position after it is the classic puzzle-app mistake —
    /// they have to reconstruct what just happened before they can start. So the
    /// board opens on the stored FEN and the setup move animates in, which is
    /// also how a real game would have shown it to them.
    @State private var isPlayingSetupMove = false

    /// Handed the drill the set's concept earned, and only when the user asks
    /// for it on the summary.
    ///
    /// The Train screen used to read `pendingDrill` off the model when the
    /// cover closed, however it closed — so a user who left at puzzle two
    /// because they were out of time was answered with a second full-screen
    /// board. Closing a set is a signal, and the app was ignoring it.
    private let onDrillRequested: (EndgameDrillKind) -> Void

    /// The habit this set is weighted toward, named on screen.
    ///
    /// Passed in rather than read off the model, which holds the focus
    /// privately. It is the line that was missing from both ends of the
    /// handoff: the user taps "Train blunder-checking" on Profile, the tab
    /// switches, a board opens with an empty title, and nothing anywhere says
    /// the tap did what it promised.
    private let focusName: String?

    init(
        model: PuzzleSessionModel,
        focusName: String? = nil,
        onDrillRequested: @escaping (EndgameDrillKind) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.focusName = focusName
        self.onDrillRequested = onDrillRequested
    }

    var body: some View {
        Group {
            switch model.stage {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(message):
                unavailable(message)
            case .summary:
                summary
            case let .teaching(concept):
                ConceptLessonView(concept: concept) { model.beginConceptExercise() }
            case .solving, .verdict:
                solving
            }
        }
        // The close button belongs to the cover, not to one stage of it. It
        // used to hang off `solving` alone, which meant a session that failed
        // to build, or hung loading, or opened on a lesson the user did not
        // want, had no exit at all — a full-screen cover cannot be swiped away.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close the set")
            }
        }
        .task { await model.start() }
        // The set's clock stops with the app. Nobody solves a puzzle from the
        // lock screen, and counting the phone call that interrupted the set as
        // time spent on it turns the summary's `Time` into a reading of how long
        // the user left the app open.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resumeClock()
            } else {
                model.pauseClock()
            }
        }
    }

    // MARK: Summary

    /// The end of the set, with the next step named.
    private var summary: some View {
        SessionSummaryView(
            progress: model.progress,
            missed: model.missed,
            nextStep: nextStep,
            isCalculationSet: model.isCalculationSet,
            onContinue: {
                if let kind = model.pendingDrill { onDrillRequested(kind) }
                dismiss()
            },
            onDefer: model.pendingDrill == nil ? nil : { dismiss() }
        )
    }

    private var nextStep: SessionSummaryView.NextStep {
        guard let kind = model.pendingDrill else { return .done }
        let drills = EndgameDrill.drills(kind: kind)
        return .drill(
            title: DrillFamilyPresentation.all.first { $0.kind == kind }?.title ?? "endgame",
            positions: max(1, drills.count),
            moveBudget: EndgameDrillTuning.default.moveBudget(
                for: kind,
                curriculum: DomainTuning.default.curriculum
            )
        )
    }

    // MARK: Solving

    private var solving: some View {
        VStack(spacing: 12) {
            // A plain statement of the task, above the board rather than under
            // it: it is the first thing to read and the last thing to re-read,
            // and a board that starts at the top edge leaves the user hunting
            // for whose move it is.
            VStack(alignment: .leading, spacing: 2) {
                // The mode outranks the habit, and never joins it: a calculation
                // set carries no weekly focus, so the two can never both be
                // true, and a caller that passed a stale focus name in would
                // otherwise label a theme-blind set as weighted toward one.
                if let mode = model.modeNote {
                    Text(mode)
                        .typeRole(.caption)
                } else if let focusName {
                    Text("Weighted toward \(focusName.lowercased())")
                        .typeRole(.caption)
                }
                Text(model.taskLine)
                    .typeRole(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            board
                .padding(.horizontal, 12)

            // Both sides' losses, under the board. A puzzle opens mid-game from
            // somebody else's position, so the material count is the only way to
            // know whether the tactic is worth playing for — finding a move that
            // wins a rook matters rather differently when you are a queen down.
            capturedRow
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                SessionProgressBar(progress: model.progress, label: model.progressLabel)
            }
        }
        // Keyed on the model's own identity rather than on the plan, because
        // the set's concept exercise has no plan behind it — it is not an SRS
        // card — and `planOnScreen?.id` was therefore `nil` for it both before
        // and after, so the animation never ran on the one item the user meets
        // first.
        .task(id: model.itemIdentity) { await playSetupMove() }
    }

    /// You on the left, the opponent on the right — the solver's row first,
    /// because it is the one being asked to act.
    @ViewBuilder
    private var capturedRow: some View {
        if let position = model.position {
            CapturedTrayRow(perspective: model.orientation, position: position)
        }
    }

    private var board: some View {
        BoardView(
            position: displayedPosition,
            orientation: model.orientation,
            interaction: interaction,
            highlights: highlights,
            style: BoardAppearance.shared.style
        )
        .overlay {
            BoardAnnotationOverlay(
                orientation: model.orientation,
                ring: ring,
                hint: hintArrow,
                style: BoardAppearance.shared.style
            )
        }
    }

    /// The pre-setup position for the length of the animation, then the real one.
    private var displayedPosition: Position {
        if isPlayingSetupMove, let setup = model.setupMove { return setup.position }
        return model.position ?? .standard
    }

    private func playSetupMove() async {
        guard model.setupMove != nil else {
            isPlayingSetupMove = false
            return
        }
        isPlayingSetupMove = true
        // Long enough to read as a move rather than a jump cut, short enough
        // that ten of them do not add a minute to the session.
        try? await Task.sleep(for: .milliseconds(380))
        isPlayingSetupMove = false
        // The board only becomes the user's now, so this is where the solve
        // clock starts. Those 380ms are the app's animation, not the user's
        // thinking, and `AutoGrader` reads latency both absolutely and against
        // a band median — so counting them makes every item look slower than it
        // was and inflates the median they are all measured against.
        model.markPositionInteractive()
    }

    private var interaction: BoardInteraction {
        guard case .solving = model.stage, !isPlayingSetupMove else { return .replay }
        return .userMove { from, to in
            model.attemptMove(from: from, to: to)
        }
    }

    /// The last move's wash, plus — after a miss — the answer's destination in
    /// `BoardUI`'s dashed green target.
    ///
    /// The dashed border is a state of its own rather than a louder version of
    /// the hint ring: "this was the answer" is what the user needs after they
    /// have already committed, and drawing it with the same solid ring the hint
    /// uses would make the two indistinguishable in memory a puzzle later. The
    /// user's own wrong square keeps its orange ring from
    /// ``BoardAnnotationOverlay`` — amber, never red, for the reason stated
    /// there — so the two marks never collide in shape or in colour.
    private var highlights: [SquareHighlight] {
        guard !isPlayingSetupMove else { return [] }

        var marks = model.lastOpponentMove.map { SquareHighlight.lastMove(from: $0.from, to: $0.to) } ?? []
        if case let .verdict(verdict) = model.stage,
            let answer = PuzzleConcept.destination(ofUCI: verdict.answer) {
            marks.append(SquareHighlight(answer, .correctAnswer))
        }
        return marks
    }

    private var ring: BoardRing? {
        if case let .verdict(verdict) = model.stage { return verdict.ring }
        return model.liveRing
    }

    /// The hint arrow while solving, and the answer arrow after a miss — the
    /// same thin grey arrow either way, because they are the same information.
    private var hintArrow: (from: Square, to: Square)? {
        let uci: String?
        if case let .verdict(verdict) = model.stage {
            uci = verdict.answer
        } else {
            uci = model.hintMove
        }
        guard let pair = MovePair(uci: uci) else { return nil }
        return (pair.from, pair.to)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if case let .verdict(verdict) = model.stage {
            ResultBanner(
                verdict: verdict,
                continueTitle: isLastItem ? "Finish" : "Next",
                onContinue: { model.continueAfterVerdict() }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            solveActions
        }
    }

    private var isLastItem: Bool {
        model.progress.completed >= model.progress.displayTotal
    }

    /// The two ways out of a puzzle, both of them priced on the label.
    ///
    /// Neither is free and neither used to say so. The hint button spends the
    /// attempt the moment it is tapped — `AutoGrader` grades any hint `.again`
    /// — and "Skip" is graded as a failure outright. A user who learns that
    /// from the summary's `Hints` row has already spent the cost twice, and
    /// "Skip" in every other app on the phone means "come back to it later, no
    /// penalty".
    ///
    /// The first tap buys a nudge and the second the arrow, so the row also
    /// carries whatever the nudge said. It stays inside the banner's reserved
    /// height, which is what keeps the board from moving when a verdict
    /// replaces it.
    private var solveActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nudge = model.hintText {
                Text(nudge)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    model.revealHint()
                    announceHint()
                } label: {
                    Label(hintTitle, systemImage: "lightbulb")
                        .typeRole(.caption, appliesForeground: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.hintLevel == .answer)

                Spacer()

                Button {
                    Task { await model.skip() }
                } label: {
                    Text("Give up · counts as missed")
                        .typeRole(.caption, appliesForeground: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        // The same height the banner occupies, so swapping one for the other
        // does not move the board.
        .frame(height: ResultBanner.height, alignment: .bottom)
        .padding(.horizontal, 4)
    }

    /// What the hint button is offering next.
    ///
    /// Both rungs carry the same price on the label because they carry the same
    /// price: the attempt is spent on the first tap either way.
    private var hintTitle: String {
        switch model.hintLevel {
        case .none: "Hint · counts as missed"
        case .nudge: "Show the answer"
        case .answer: "Answer shown"
        }
    }

    /// Says the hint out loud.
    ///
    /// The arrow is drawn on a `Canvas`, which is nothing at all to a VoiceOver
    /// user — so the one control whose whole purpose is to hand over help used
    /// to hand over silence, having already spent the attempt.
    private func announceHint() {
        if model.hintLevel == .nudge, let nudge = model.hintText {
            AccessibilityNotification.Announcement(nudge).post()
            return
        }
        guard let move = PuzzleReason.description(ofMove: model.hintMove, in: model.position) else { return }
        AccessibilityNotification.Announcement("The answer is \(move).").post()
    }

    /// The session could not be built.
    ///
    /// Titled for the failure rather than for the day: "No puzzles today" says
    /// the app chose not to serve any, which is not what happened and leaves
    /// the user with nothing to try.
    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Training could not start", systemImage: "square.grid.3x3")
        } description: {
            Text(message)
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.secondaryAction)
        }
    }
}
