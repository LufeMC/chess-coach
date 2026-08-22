import BoardUI
import ChessKit
import Combine
import Database
import Foundation
import SwiftUI

/// Post-game review.
///
/// Two layouts, one model. On iPhone the board is pinned at the top with the
/// scrubber directly beneath it — the graph *drives* the board, so the two must
/// be visible at the same time or the primary interaction is only available at
/// scroll-top — and everything else scrolls under them. On Mac the same material
/// is split into three named panels.
///
/// The scrolling half is ordered as the story of the game: the verdict, then the
/// numbers behind it, then the three positions it turned on, then the coach on
/// whichever of them is selected. The move list comes last and closed, because a
/// list of sixty half-moves is reference material — it answers "what happened on
/// move 41", which is a question you arrive with, not one the screen should
/// spend its first screenful anticipating.
struct ReviewScreen: View {

    @State private var model: ReviewModel
    /// Mac only; harmless elsewhere.
    @State private var isCoachCollapsed = false
    @State private var isMoveListExpanded = false
    /// Shown under the graph until the reader has scrubbed once, ever. Nothing
    /// on the screen said the curve was draggable or that the pieces are
    /// tappable in replay, and neither is discoverable by looking.
    @AppStorage("review.hasScrubbed") private var hasScrubbed = false

    /// Optional so previews and hosts that build no services still render.
    @Environment(AppModel.self) private var appModel: AppModel?

    /// The daily loop's next step and its price, read once when the screen
    /// opens. Nil while it is being read, and nil for good when the day has
    /// nothing left in it — see ``handoff``.
    @State private var nextStep: (title: String, destination: TodayDestination)?

    /// Read through the shared appearance rather than captured once, so a theme
    /// changed in Settings is reflected the next time this screen draws.
    private var style: BoardStyle { BoardAppearance.shared.style }

    /// A moment to scrub to once the game has loaded.
    ///
    /// Carried rather than applied immediately because the positions do not
    /// exist until `load()` has run; selecting before then would silently do
    /// nothing and leave the user at move 1 wondering what they tapped.
    private let focusMomentID: UUID?

    init(gameID: UUID) {
        _model = State(initialValue: ReviewModel(gameID: gameID))
        focusMomentID = nil
    }

    /// Opens the game already scrubbed to one moment — the destination of a
    /// moment route, where the user asked for that position specifically.
    init(gameID: UUID, focusMomentID: UUID) {
        _model = State(initialValue: ReviewModel(gameID: gameID))
        self.focusMomentID = focusMomentID
    }

    /// Injection point for previews.
    init(model: ReviewModel) {
        _model = State(initialValue: model)
        focusMomentID = nil
    }

    var body: some View {
        content
            .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
            .navigationTitle("Review")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                nextStep = TodayModel.nextStepAfterReview()
                await model.load()
                if let focusMomentID { model.select(momentID: focusMomentID) }
                // The pass is usually still running when this screen opens — the
                // handoff from Summary is a few seconds after the game — so the
                // screen keeps reading until it settles rather than promising a
                // curve that only a back-and-re-enter would ever produce.
                await model.followAnalysis()
            }
            .modifier(ReviewKeyboardCommands(model: model))
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            // The final layout is known before the read finishes — board,
            // scrubber slot, three pills — so it is drawn rather than covered.
            // `craft-standards.md`: no spinners outside a button.
            ReviewSkeleton()

        case .missing:
            ContentUnavailableView {
                Label("Game not found", systemImage: "questionmark.folder")
            } description: {
                // Nothing here syncs and there is no account, so "another
                // device" invented a cause the reader knows is impossible.
                Text("This game is no longer in your history.")
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Could not open this game", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }

        case .ready:
            #if os(macOS)
                macLayout
            #else
                phoneLayout
            #endif
        }
    }

    // MARK: - iPhone

    /// Scroll target for the self-check card.
    private static let selfCheckAnchor = "review.selfCheck"

    /// The pre-engine questions, in the slot the verdict will take once they
    /// are done.
    @ViewBuilder
    private var selfCheckSection: some View {
        if let question = model.selfCheckQuestion {
            ReviewSelfCheckCard(
                question: question,
                index: model.selfCheckIndex,
                total: model.selfCheckQuestions.count,
                chosen: model.selfCheckRevealed ? model.selfCheckAnswers[question.id] : nil,
                onAnswer: { model.answerSelfCheck($0) },
                onNext: { withAnimation(Motion.crossfade) { model.advanceSelfCheck() } },
                onSkip: { withAnimation(Motion.crossfade) { model.skipSelfCheck() } }
            )
        }
    }

    #if !os(macOS)
        private var phoneLayout: some View {
            GeometryReader { proxy in
                VStack(spacing: 12) {
                    // Capped against height as well as width: at full width the
                    // board would leave nothing for the scrubber on a small phone,
                    // and the scrubber is not optional here.
                    let side = min(proxy.size.width - 24, proxy.size.height * 0.44)

                    board
                        .frame(width: side, height: side)

                    capturedRow
                        .padding(.horizontal, 16)

                    evalReadingRow
                        .padding(.horizontal, 16)

                    scrubber
                        .padding(.horizontal, 16)

                    stepRow
                        .padding(.horizontal, 16)

                    ScrollView {
                        // The self-check card grows when it marks an answer, and
                        // it sits under a full-width board — so the explanation
                        // and the button that continues appear below the fold on
                        // the very tap that creates them. Reading is not the
                        // problem; a "Next" the user cannot see is.
                        ScrollViewReader { scroll in
                        VStack(alignment: .leading, spacing: 20) {
                            analysisNotice.padding(.horizontal, 16)
                            // The engine's read stays covered until the user
                            // has committed to their own. See
                            // ``ReviewSelfCheck`` for why a review that opens
                            // with the verdict teaches nothing.
                            if model.isSelfCheckActive {
                                selfCheckSection
                                    .padding(.horizontal, 16)
                                    .id(Self.selfCheckAnchor)
                            } else {
                                if let result = model.selfCheckResult {
                                    // What the questions came to, before the
                                    // engine's read starts talking over it.
                                    Text(result)
                                        .typeRole(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 16)
                                }
                                if let verdict = model.verdict {
                                    ReviewVerdictCard(verdict: verdict)
                                        .padding(.horizontal, 16)
                                }
                                statPills
                                    .padding(.horizontal, 16)
                                filmstripSection(width: proxy.size.width)
                                coachSection.padding(.horizontal, 16)
                            }
                            moveListSection
                                .padding(.horizontal, 16)
                            handoff
                                .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 16)
                        .onChange(of: model.selfCheckRevealed) { _, revealed in
                            guard revealed else { return }
                            withAnimation(Motion.crossfade) {
                                scroll.scrollTo(Self.selfCheckAnchor, anchor: .bottom)
                            }
                        }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    #endif

    // MARK: - Mac

    #if os(macOS)
        /// Three named panels with a real gutter between them, each carrying its
        /// own header row. Naming the panels is what makes a three-pane layout
        /// legible: without headers the reader has to infer what each column is
        /// for from its contents.
        private var macLayout: some View {
            HStack(spacing: 10) {
                ReviewPanel(title: "Board") {
                    VStack(spacing: 14) {
                        analysisNotice
                        board
                            .frame(maxWidth: 520)
                        capturedRow
                            .frame(maxWidth: 520)
                        evalReadingRow
                            .frame(maxWidth: 520)
                        evalBar
                            .frame(maxWidth: 520)
                        scrubber
                        statPills
                        filmstripSection(width: 520)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                }

                ReviewPanel(title: "Moves") {
                    ScrollView {
                        ReviewMoveList(
                            rows: model.moveRows,
                            currentPly: model.currentPly,
                            style: style,
                            onSelect: { model.select(index: $0) }
                        )
                        .padding(12)
                    }
                }
                .frame(width: 280)

                if isCoachCollapsed {
                    // Collapsed to a rail rather than removed: a panel with no way
                    // back is a panel the user loses.
                    Button {
                        isCoachCollapsed = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity)
                            .frame(width: 28)
                            .elevation(.raised, cornerRadius: CornerRadius.chip)
                    }
                    .buttonStyle(.pressable)
                    .help("Show the coach panel")
                } else {
                    ReviewPanel(
                        title: "Coach",
                        accessory: {
                            Button {
                                isCoachCollapsed = true
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.pressable)
                            .foregroundStyle(.secondary)
                            .help("Hide the coach panel")
                        }
                    ) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if let verdict = model.verdict {
                                    ReviewVerdictCard(verdict: verdict)
                                }
                                coachSection
                            }
                            .padding(12)
                        }
                    }
                    .frame(width: 340)
                }
            }
            .padding(10)
            .animation(Motion.standard, value: isCoachCollapsed)
        }

        private var evalBar: some View {
            EvalBarView(
                score: model.whiteWinPercent ?? 50,
                mate: model.whiteMate,
                orientation: model.orientation,
                thickness: 12,
                showsLabel: true
            )
            .frame(height: 12)
            .opacity(model.whiteWinPercent == nil ? 0.3 : 1)
        }
    #endif

    // MARK: - Pieces

    private var board: some View {
        BoardView(
            position: model.position,
            orientation: model.orientation,
            // `.replay` rather than `.locked`: you cannot change the game, but
            // "where could that knight have gone?" is most of why anyone replays.
            interaction: .replay,
            highlights: model.highlights,
            // The engine's move, once the reader has asked for it. See
            // ``ReviewModel/boardArrows``.
            arrows: model.boardArrows,
            style: style
        )
    }

    /// One line under the board saying which way the position is going.
    ///
    /// The curve above it is drawn White-at-top and never flipped, so a reader
    /// who played Black watches it climb while they lose. This is the sentence
    /// that resolves it, and it is the only place on the phone that answers "am
    /// I winning here?" in words while scrubbing. It keeps its slot when there
    /// is no evaluation so the board does not jump as analysis lands.
    private var evalReadingRow: some View {
        Text(model.evalReading ?? " ")
            .typeRole(.caption)
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .contentTransition(.opacity)
            .animation(Motion.crossfade, value: model.evalReading)
            .accessibilityLabel(Text(model.evalReading ?? "Not evaluated yet"))
    }

    /// The material count for the position on screen. In review it moves as the
    /// scrubber does — watching the trays fill move by move is the material
    /// story of the game told at the pace the user chooses.
    private var capturedRow: some View {
        CapturedTrayRow(perspective: model.orientation, position: model.position)
    }

    @ViewBuilder
    private var scrubber: some View {
        if model.track.points.count > 1 {
            ReviewScrubber(
                points: model.track.points,
                segments: model.phaseSegments,
                // The coloured dots are the answer to "where did you lose
                // material?", so they stay off the curve until the question has
                // been answered — see ``ReviewSelfCheck``.
                moments: model.isSelfCheckActive ? [:] : momentMarks,
                index: Binding(
                    get: { model.selectedIndex },
                    set: {
                        hasScrubbed = true
                        model.select(index: $0)
                    }
                ),
                style: style,
                // The side actually played, not the board orientation: flipping
                // the board must not move the "· you" onto the other axis label.
                playedSide: model.playedSide
            )
        } else {
            // No curve yet. The strip keeps its slot so the layout does not jump
            // when analysis finishes, and it is drawn as a pending slot rather
            // than an empty card — nothing has failed here.
            Color.clear
                .frame(height: 94)
                .elevation(.raised, cornerRadius: CornerRadius.card, fill: Palette.surfaceSunken)
                .pendingOutline(cornerRadius: CornerRadius.card)
                .overlay {
                    Text(scrubberPlaceholder)
                        .typeRole(.caption)
                }
        }
    }

    /// What the empty curve slot says.
    ///
    /// A game resigned on move one is marked complete with a single position in
    /// it, and "Evaluation pending" there waits for something that is never
    /// coming.
    private var scrubberPlaceholder: String {
        switch model.analysisState {
        case .failed: "No evaluation"
        case .complete: "Too short to evaluate"
        case .pending, .running: "Evaluation pending"
        }
    }

    /// One half-move at a time, in both directions.
    ///
    /// On a 70-ply game the scrubber maps four points to a half-move, so
    /// landing on "the move before the blunder" by finger is luck. These were
    /// wired for the Mac menu only; on the phone the alternative was a 64-row
    /// table.
    private var stepRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                stepButton(symbol: "chevron.left", label: "Previous move") {
                    hasScrubbed = true
                    model.stepBackward()
                }
                Text(stepLabel)
                    .typeRole(.caption, monospacedDigits: true)
                    .frame(maxWidth: .infinity)
                stepButton(symbol: "chevron.right", label: "Next move") {
                    hasScrubbed = true
                    model.stepForward()
                }
            }

            if !hasScrubbed {
                Text("Drag the graph to move through the game, or tap a piece to see where it could go.")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepLabel: String {
        guard let ply = model.currentPly else { return "Start" }
        return "Move \((ply + 1) / 2)"
    }

    private func stepButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: 34, height: 34)
                .elevation(.raised, cornerRadius: 17)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(Text(label))
    }

    private var momentMarks: [Int: BoardUI.MoveClassification] {
        model.momentCards.reduce(into: [:]) { marks, card in
            // The dot goes where the *card* goes: the position before the move,
            // which is the choice the moment is about. Marking it one to the
            // right — after the move, where the curve visibly drops — broke the
            // screen's primary interaction, because dragging the scrubber onto a
            // coloured dot then landed on a position no card claims, and the
            // coach card vanished instead of appearing. The curve still drops
            // immediately to the right of the dot, which is legible; a dot you
            // cannot select is not.
            marks[card.positionIndex] = card.classification
        }
    }

    // MARK: - Stats

    /// The three numbers the game comes down to, each with the comparison the
    /// app can honestly draw.
    ///
    /// Only accuracy carries a comparison chip, and that is a data fact rather
    /// than an oversight: it is the one per-game number stored on every past
    /// game, so it is the only one that can be averaged without re-reading every
    /// game's moves. A chip under the other two would either be a guess or a
    /// table scan on a screen that has to open instantly.
    private var statPills: some View {
        HStack(alignment: .top, spacing: 10) {
            ReviewStatPill(
                label: "Accuracy",
                value: model.accuracy.map { "\(Int($0.rounded()))%" }
                    ?? settledPlaceholder,
                caption: accuracyComparison == nil ? nil : "against opponents near this rating",
                comparison: accuracyComparison
            )
            // Both captions exist because the two counts are not the same kind
            // of thing and nothing else on the screen says so: one excludes
            // inaccuracies on purpose, and the other is a ceiling of three that
            // can include a move the analysis picked out as well played.
            ReviewStatPill(
                label: "Mistakes",
                value: model.analysisState == .complete
                    ? "\(model.userMistakeCount)" : settledPlaceholder,
                caption: "blunders and mistakes"
            )
            ReviewStatPill(
                label: "To review",
                value: model.analysisState == .complete
                    ? "\(model.momentCards.count)" : settledPlaceholder,
                caption: "positions worth studying"
            )
        }
    }

    /// What a stat shows when there is no number and none is coming.
    ///
    /// The app's rule, which the summary screen already follows: a skeleton
    /// means "still on its way", so leaving one pulsing under a notice that says
    /// the analysis *failed* promises a number that will never arrive. A settled
    /// pass with nothing to show says so with a dash.
    ///
    /// Complete counts as settled too, for the game resigned on move one: it is
    /// analysed instantly and has no accuracy to report, and the skeleton there
    /// was waiting on a number that had already not been produced.
    private var settledPlaceholder: String? {
        model.analysisState == .failed || model.analysisState == .complete ? "—" : nil
    }

    private var accuracyComparison: ReviewStatComparison? {
        guard let accuracy = model.accuracy, let reference = model.accuracyReference else { return nil }
        return ReviewStatComparison(
            value: accuracy,
            reference: reference.average,
            text: "avg \(Int(reference.average.rounded()))% · last \(reference.count)"
        )
    }

    // MARK: - Moments

    @ViewBuilder
    private func filmstripSection(width: CGFloat) -> some View {
        if !model.momentCards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Moments", qualifier: counterText)
                    .padding(.horizontal, 16)

                MomentFilmstrip(
                    moments: model.momentCards.map(\.thumbnail),
                    selection: Binding(
                        get: { model.activeMomentID },
                        set: { id in
                            guard let id else { return }
                            model.select(momentID: id)
                        }
                    ),
                    style: style,
                    // Sized so the whole set fits at once. With three moments there
                    // is nothing to page through, and a strip that scrolls when it
                    // does not need to invites hunting for a fourth card.
                    cardWidth: filmstripCardWidth(containerWidth: width)
                )
            }
        }
    }

    /// Three cards, their padding, their spacing and the strip's own inset,
    /// solved for the board width. `MomentFilmstrip` pads each card by 8 on both
    /// sides, spaces them by 12, and insets the row by 16.
    private func filmstripCardWidth(containerWidth: CGFloat) -> CGFloat {
        let chrome: CGFloat = 3 * 16 + 2 * 12 + 2 * 16
        return max(88, (containerWidth - chrome) / 3)
    }

    private var counterText: String {
        let total = model.momentCards.count
        guard
            let id = model.activeMomentID,
            let ordinal = model.momentOrdinal(of: id)
        else {
            return "—/\(total)"
        }
        return "\(ordinal)/\(total)"
    }

    // MARK: - Coach

    /// The coach card for the moment the board is standing on, or nothing at all.
    ///
    /// A note either exists on the row or it does not — it is written by the
    /// analysis pass, so by the time this screen can draw anything the answer is
    /// already settled. Its absence renders as the absence of a card rather than
    /// as an error: a game analysed by a build that predates the notes still has
    /// its board, its curve and its moments, and none of that is broken.
    @ViewBuilder
    private var coachSection: some View {
        if let card = model.focusedCard, let note = card.coachText {
            ReviewCoachCard(
                note: note,
                diagnosis: card.diagnosis,
                subtitle: "Move \(card.moveNumber) · \(card.classification.title)",
                question: card.question,
                suggestedQuestions: model.suggestedQuestions(forMoment: card.id),
                revealedQuestionIDs: model.revealedSuggestionIDs,
                onToggleQuestion: { model.toggleSuggestion(id: $0) },
                onReveal: { model.markReviewed(momentID: card.id) },
                onDrill: appModel.map { app in { habit in app.navigate(toTrain: habit) } }
            )
            // Keyed on the moment, so the next card opens covered rather than
            // inheriting the last one's uncovered state.
            .id(card.id)
            .animation(Motion.contentSwap, value: note)
        }
    }

    // MARK: - Moves

    /// The full table, closed by default.
    ///
    /// A `DisclosureGroup` rather than a link to another screen: the answer to
    /// "what did I play on move 41" belongs beside the board it scrubs, and a
    /// push would take the board away to show it.
    private var moveListSection: some View {
        DisclosureGroup(isExpanded: $isMoveListExpanded) {
            ReviewMoveList(
                rows: model.moveRows,
                currentPly: model.currentPly,
                style: style,
                // The chips and the cost column are the engine's verdict on each
                // move, which is exactly what the questions above are asking
                // for. They come back with the rest of the review.
                showsJudgement: !model.isSelfCheckActive,
                onSelect: { model.select(index: $0) }
            )
            .padding(.top, 10)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("All moves")
                    .typeRole(.headline)
                Spacer(minLength: 8)
                Text("\(model.moveRows.count)")
                    .typeRole(.caption, monospacedDigits: true)
            }
        }
        .tint(Palette.accent.dynamic)
        .animation(Motion.standard, value: isMoveListExpanded)
    }

    // MARK: - Handoff

    /// The daily loop's next step, at the end of the review that precedes it.
    ///
    /// The review used to end on the move list, which is reference material: the
    /// user who had just worked through their three moments got no signal that
    /// they were finished and no idea what followed, and the loop lost its
    /// momentum at the exact hinge it exists to turn. Named and priced in
    /// Today's own vocabulary, because it is Today's step — the words have to
    /// match or the two screens read as two different offers.
    ///
    /// Bordered, not filled: the coach card above owns this screen's one accent,
    /// and a second filled button would make the reader check which of the two
    /// is the thing they came here to do.
    ///
    /// Absent when the day has nothing left in it. "Done for today" belongs on
    /// Today, where the completed state is already written; inventing extra work
    /// here to keep a button on screen is the thing the button is against.
    @ViewBuilder
    private var handoff: some View {
        // Not while the self-check is still asking its questions: "Done" before
        // the review has begun is an exit offered in place of the work.
        if let nextStep, let appModel, !model.isSelfCheckActive {
            Button("Done · \(nextStep.title)") {
                switch nextStep.destination {
                case .train: appModel.advance(to: .train)
                case .play: appModel.advance(to: .play)
                // A coached game is the Play tab started differently, not a
                // push, so it goes through its own entry point — routing it to
                // `.play` would open an ordinary game and quietly drop the habit
                // the step named in its own title.
                case .playGuided(let habit):
                    appModel.todayPath.removeAll()
                    appModel.navigate(toGuidedGame: habit)
                case .progress: appModel.advance(to: .profile)
                // `nextStepAfterReview` never returns the review step — a button
                // pointing at the screen it is drawn on is the dead end this
                // whole affordance removes — so this is the safe fallback only.
                case .reviewLatestGame: appModel.selectedTab = .today
                }
            }
            .buttonStyle(.secondaryAction)
            .padding(.top, 4)
        }
    }

    // MARK: - Status

    /// Honest reporting of where analysis stands. Nothing at all once it is done.
    ///
    /// The two unfinished states carry a button, because neither of them is
    /// something the app reliably gets out of on its own: backgrounding
    /// suspends the engine and nothing restarts the queue until the next game
    /// or the next launch, and a failed pass is never picked up again at all.
    @ViewBuilder
    private var analysisNotice: some View {
        switch model.analysisState {
        case .complete:
            EmptyView()
        case .pending:
            ReviewNoticeRow(
                symbol: "clock",
                title: "Not analysed yet",
                detail: "Evaluations and moments appear once the post-game pass runs. "
                    + "It pauses whenever Rookly is in the background.",
                actionTitle: "Analyse now",
                action: startAnalysis
            )
        case .running:
            ReviewNoticeRow(
                symbol: nil,
                title: "Analysing",
                detail: "The curve fills in as the engine walks the game. "
                    + "Keep Rookly open — the pass pauses in the background.",
                showsProgress: true
            )
        case .failed:
            ReviewNoticeRow(
                symbol: "exclamationmark.triangle",
                title: "Analysis failed",
                detail: "The moves are here; the evaluation is not. "
                    + "Nothing retries this on its own.",
                actionTitle: "Try the analysis again",
                action: startAnalysis
            )
        }
    }

    /// Runs the pass for this game, now.
    ///
    /// Addressed at the game rather than at the queue, deliberately: the queue
    /// only ever selects rows still marked `pending`, so a failed game — which
    /// is written `failed` and never looked at again — could not be recovered by
    /// draining. One transient engine hiccup otherwise removes that game from
    /// the training loop permanently.
    private func startAnalysis() {
        guard let engineService = appModel?.engineService else { return }
        let gameID = model.gameID
        Task {
            guard let service = AnalysisService.shared(engineService: engineService) else { return }
            await service.analyze(gameID: gameID)
            await model.reload()
        }
    }
}

// MARK: - Support views

/// The screen's own shape, drawn while the game is read off disk.
///
/// Board, the scrubber's 94pt slot, three pills — the same geometry the real
/// content lands in, so nothing moves when it arrives.
private struct ReviewSkeleton: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 12) {
                let side = min(proxy.size.width - 24, proxy.size.height * 0.44)

                SkeletonView(width: side, height: side, cornerRadius: CornerRadius.card)

                SkeletonView(height: 94, cornerRadius: CornerRadius.card)
                    .padding(.horizontal, 16)

                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonView(height: 78, cornerRadius: CornerRadius.card)
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .accessibilityLabel(Text("Loading this game"))
    }
}

/// One number, its label, and the grey chip that puts it in context.
private struct ReviewStatPill: View {
    let label: String
    /// `nil` until analysis has produced it.
    let value: String?
    /// What the number counts, for a label that is not self-defining.
    var caption: String? = nil
    var comparison: ReviewStatComparison? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .typeRole(.label)

            if let value {
                Text(value)
                    .typeRole(.title, monospacedDigits: true)
                    .contentTransition(.numericText())
            } else {
                // Measured against the real number's own geometry, so nothing
                // moves when analysis lands.
                SkeletonView(width: 52, height: 26)
                    .padding(.vertical, 2)
            }

            if let caption {
                Text(caption)
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let comparison {
                HStack(spacing: 3) {
                    Image(systemName: comparison.symbolName)
                        .font(.system(size: 8, weight: .semibold))
                    Text(comparison.text)
                        .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                }
                // Grey, never semantic: above average is good for accuracy and
                // bad for mistakes, and a colour that means both means neither.
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                        .fill(Palette.surfaceSunken.dynamic)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .elevation(.raised, cornerRadius: CornerRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// One phrase, not a number followed by two fragments.
    private var accessibilityText: String {
        var text = "\(label): \(value ?? "still being worked out")"
        if let caption { text += ", \(caption)" }
        if let comparison { text += ", \(comparison.text)" }
        return text
    }
}

/// How a number compares to the user's own recent average.
struct ReviewStatComparison: Equatable {
    var value: Double
    var reference: Double
    /// The chip's words, e.g. `"your avg 79%"`.
    var text: String

    /// A dead band, because a caret claims a trend and most differences are not
    /// one.
    ///
    /// Three points rather than the half-point it used to be. The accuracy it
    /// compares is computed from a search of roughly a third of a second a ply,
    /// and a search that shallow disagrees with itself by more than half a point
    /// between runs — so a caret at 0.5 was mostly drawing the engine's own
    /// noise as progress. Three points is not a measured noise floor, which is
    /// why it is not called one; it is the smallest gap this screen is willing
    /// to call a direction.
    static let tolerance = 3.0

    var symbolName: String {
        if value - reference > Self.tolerance { return "arrowtriangle.up.fill" }
        if reference - value > Self.tolerance { return "arrowtriangle.down.fill" }
        return "minus"
    }
}

#if os(macOS)
    /// A named panel: header row, hairline, content.
    private struct ReviewPanel<Content: View, Accessory: View>: View {
        let title: String
        let accessory: Accessory
        let content: Content

        init(
            title: String,
            @ViewBuilder accessory: () -> Accessory = { EmptyView() },
            @ViewBuilder content: () -> Content
        ) {
            self.title = title
            self.accessory = accessory()
            self.content = content()
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .typeRole(.label)
                    Spacer()
                    accessory
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
    }
#endif

/// One line of status, in the same raised-rect vocabulary as the rest.
private struct ReviewNoticeRow: View {
    var symbol: String?
    var title: String
    var detail: String
    var showsProgress = false
    /// Present only where there is something the reader can actually do; a
    /// status line with no action is the generic error the craft doc argues
    /// against.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .typeRole(.headline)
                    Text(detail)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if let actionTitle, let action {
                Button(actionTitle) { action() }
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(Palette.accent.dynamic)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                            .strokeBorder(Palette.accent.dynamic.opacity(0.45), lineWidth: 2)
                    )
                    .buttonStyle(.pressable)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}

/// Wires the Review menu's keyboard shortcuts, which arrive as notifications
/// because the menu lives in the `App` scene and the screen does not.
private struct ReviewKeyboardCommands: ViewModifier {
    let model: ReviewModel

    func body(content: Content) -> some View {
        #if os(macOS)
            content
                .onReceive(NotificationCenter.default.publisher(for: .reviewStepForward)) { _ in
                    model.stepForward()
                }
                .onReceive(NotificationCenter.default.publisher(for: .reviewStepBackward)) { _ in
                    model.stepBackward()
                }
                .onReceive(NotificationCenter.default.publisher(for: .reviewFlipBoard)) { _ in
                    model.flipBoard()
                }
        #else
            content
        #endif
    }
}
