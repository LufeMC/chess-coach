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
struct ReviewScreen: View {

    @State private var model: ReviewModel
    /// Mac only; harmless elsewhere.
    @State private var isCoachCollapsed = false

    private let style = BoardStyle.default

    init(gameID: UUID) {
        _model = State(initialValue: ReviewModel(gameID: gameID))
    }

    /// Injection point for previews and for a future coach service.
    init(model: ReviewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .navigationTitle("Review")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await model.load() }
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

                    scrubber
                        .padding(.horizontal, 16)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let notice = analysisNotice {
                                notice.padding(.horizontal, 16)
                            }
                            filmstripSection(width: proxy.size.width)
                            coachSection.padding(.horizontal, 16)
                            ReviewMoveList(
                                rows: model.moveRows,
                                currentPly: model.currentPly,
                                selectedPly: model.selectedRowPly,
                                style: style,
                                onSelect: { model.selectRow(ply: $0) },
                                onAsk: { model.askAboutMove(ply: $0) }
                            )
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 16)
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
                        evalBar
                            .frame(maxWidth: 520)
                        scrubber
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
                            selectedPly: model.selectedRowPly,
                            style: style,
                            onSelect: { model.selectRow(ply: $0) },
                            onAsk: { model.askAboutMove(ply: $0) }
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
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.quaternary)
                            )
                    }
                    .buttonStyle(.plain)
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
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Hide the coach panel")
                        }
                    ) {
                        ScrollView {
                            coachSection
                                .padding(12)
                        }
                    }
                    .frame(width: 340)
                }
            }
            .padding(10)
            .animation(.snappy(duration: 0.2), value: isCoachCollapsed)
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
            // when analysis finishes.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
                .frame(height: 94)
                .overlay {
                    Text(model.analysisState == .failed ? "No evaluation" : "Evaluation pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func filmstripSection(width: CGFloat) -> some View {
        if !model.momentCards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // Counter first, at the leading edge: it says how far through
                    // a fixed-size set you are, which is the question a strip of
                    // three cards raises.
                    Text(counterText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("MOMENTS")
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
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

    /// The coach card, or nothing at all.
    ///
    /// `Moment.coachText` is nil whenever generation never ran — no API key, or a
    /// failed request. That is an ordinary state for this app, so it renders as
    /// the absence of a card rather than as an error the user has to dismiss.
    @ViewBuilder
    private var coachSection: some View {
        if let focus = model.coachFocus {
            let state = model.coachState(for: focus)
            if state != .unavailable {
                ReviewCoachCard(state: state, subtitle: coachSubtitle(for: focus))
            } else if case .question(let ply) = focus {
                // The user explicitly asked something; silence would look broken.
                Text("Coaching is not connected yet, so there is no note for move \((ply + 1) / 2).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func coachSubtitle(for focus: ReviewCoachFocus) -> String? {
        switch focus {
        case .moment(let id):
            guard let card = model.card(withID: id) else { return nil }
            return "Move \(card.moveNumber) · \(card.classification.title)"
        case .question(let ply):
            return "Move \((ply + 1) / 2)"
        }
    }

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
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
        )
    }
}

/// One line of status, in the same filled-rect vocabulary as the rest.
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
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)
        )
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
