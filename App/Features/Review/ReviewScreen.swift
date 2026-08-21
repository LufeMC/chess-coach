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
                await model.load()
                if let focusMomentID { model.select(momentID: focusMomentID) }
            }
            .modifier(ReviewKeyboardCommands(model: model))
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .missing:
            ContentUnavailableView {
                Label("Game not found", systemImage: "questionmark.folder")
            } description: {
                Text("It may have been deleted on another device.")
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

                    scrubber
                        .padding(.horizontal, 16)

                    ScrollView {
                        // The self-check card grows when it marks an answer, and
                        // it sits under a full-width board — so the explanation
                        // and the button that continues appear below the fold on
                        // the very tap that creates them. Reading is not the
                        // problem; a "Next" the user cannot see is.
                        ScrollViewReader { scroll in
                        VStack(alignment: .leading, spacing: 20) {
                            if let notice = analysisNotice {
                                notice.padding(.horizontal, 16)
                            }
                            // The engine's read stays covered until the user
                            // has committed to their own. See
                            // ``ReviewSelfCheck`` for why a review that opens
                            // with the verdict teaches nothing.
                            if model.isSelfCheckActive {
                                selfCheckSection
                                    .padding(.horizontal, 16)
                                    .id(Self.selfCheckAnchor)
                            } else {
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
                        if let notice = analysisNotice { notice }
                        board
                            .frame(maxWidth: 520)
                        capturedRow
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
            style: style
        )
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
                moments: momentMarks,
                index: Binding(
                    get: { model.selectedIndex },
                    set: { model.select(index: $0) }
                ),
                style: style
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
                    Text(model.analysisState == .failed ? "No evaluation" : "Evaluation pending")
                        .typeRole(.caption)
                }
        }
    }

    private var momentMarks: [Int: BoardUI.MoveClassification] {
        model.momentCards.reduce(into: [:]) { marks, card in
            // Marked at the ply the mistake was *made*, which is the position
            // index after the move — that is where the curve moves.
            marks[card.ply] = card.classification
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
                value: model.accuracy.map { "\(Int($0.rounded()))%" },
                comparison: accuracyComparison
            )
            ReviewStatPill(
                label: "Mistakes",
                value: model.analysisState == .complete ? "\(model.userMistakeCount)" : nil
            )
            ReviewStatPill(
                label: "Moments",
                value: model.analysisState == .complete ? "\(model.momentCards.count)" : nil
            )
        }
    }

    private var accuracyComparison: ReviewStatComparison? {
        guard let accuracy = model.accuracy, let average = model.accuracyAverage else { return nil }
        return ReviewStatComparison(
            value: accuracy,
            reference: average,
            text: "your avg \(Int(average.rounded()))%"
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
                suggestedQuestions: model.suggestedQuestions(forMoment: card.id)
            )
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

    // MARK: - Status

    /// Honest reporting of where analysis stands. Nothing at all once it is done.
    private var analysisNotice: ReviewNoticeRow? {
        switch model.analysisState {
        case .complete:
            nil
        case .pending:
            ReviewNoticeRow(
                symbol: "clock",
                title: "Not analysed yet",
                detail: "Evaluations and moments appear once the post-game pass runs."
            )
        case .running:
            ReviewNoticeRow(
                symbol: nil,
                title: "Analysing",
                detail: "The curve fills in as the engine walks the game.",
                showsProgress: true
            )
        case .failed:
            ReviewNoticeRow(
                symbol: "exclamationmark.triangle",
                title: "Analysis failed",
                detail: "The moves are here; the evaluation is not."
            )
        }
    }
}

// MARK: - Support views

/// One number, its label, and the grey chip that puts it in context.
private struct ReviewStatPill: View {
    let label: String
    /// `nil` until analysis has produced it.
    let value: String?
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

    /// A dead band, because a caret on a 0.2-point difference claims a trend
    /// that does not exist.
    static let tolerance = 0.5

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

    var body: some View {
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
        .padding(12)
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
