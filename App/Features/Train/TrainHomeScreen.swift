//
//  TrainHomeScreen.swift
//  ChessCoach
//

import Database
import SwiftUI
import TrainingCore

/// The Train tab: today's puzzle set, and the endgame drills.
///
/// Two entries, kept apart on purpose. A puzzle is one move to find and ten of
/// them is a bounded, predictable session; a drill is a technique played out
/// against an engine for twenty moves. Mixing drills into the queue would make
/// "10 puzzles" mean anywhere between four minutes and forty, which is exactly
/// the kind of promise a daily habit cannot afford to break.
struct TrainHomeScreen: View {

    @Environment(AppModel.self) private var model
    @State private var home = TrainHomeModel()
    @State private var route: TrainRoute?
    /// A focus carried in from a rating leak, replacing the week's habit for
    /// exactly one session.
    @State private var requestedFocus: WeeklyFocus?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let promotion = home.promotion {
                    PromotionRow(promotion: promotion) {
                        Task { await home.acceptPromotion() }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                queueCard

                if !home.due.isEmpty {
                    dueSection
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Endgame drills")

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(DrillFamilyPresentation.all) { family in
                            EndgameDrillCard(
                                family: family,
                                mastery: home.mastery(for: family.kind),
                                onSelect: { route = .drill(family.kind) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Train")
        .task {
            await home.load()
            consumeLeakRequest()
        }
        // The tab stays alive once visited, so a leak tapped later would never
        // reach `task`. Both entry points run the same consume, which is what
        // stops a stale request aiming a session the user has moved on from.
        .onChange(of: model.pendingTrainingHabit) { _, habit in
            if habit != nil { consumeLeakRequest() }
        }
        .trainingCover(item: $route) { route in
            destination(for: route)
        }
    }

    // MARK: Queue

    /// The day's one action, and the two decisions that shape it.
    ///
    /// The chips sit *above* `Start` rather than behind a settings glyph because
    /// they are the two things about a session worth changing, and both change
    /// what the next tap produces: the length is the promise about how long today
    /// takes, and the focus decides 60% of what is in the queue.
    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // A filled circle, but a *sunken* one: the accent on this screen
                // is spent on `Start`, and an accent disc behind an icon nobody
                // can tap is the decorative use the colour rules rule out.
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceSunken.dynamic))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's set").typeRole(.headline)
                    Text(setSubtitle).typeRole(.caption)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                lengthChip
                focusChip
            }

            Button("Start") { route = .puzzles }
                .buttonStyle(.primaryAction)
                .disabled(!home.canStartSession)
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    private var setSubtitle: String {
        guard home.canStartSession else { return "The puzzle corpus is missing from this build." }
        guard home.dueCount > 0 else { return "\(home.length) puzzles." }
        return "\(home.length) puzzles — \(home.dueCount) due for review."
    }

    private var lengthChip: some View {
        Menu {
            ForEach(TrainHomeModel.lengths, id: \.self) { length in
                Button { home.length = length } label: {
                    MenuChoice(title: "\(length) puzzles", isSelected: length == home.length)
                }
            }
        } label: {
            PickerChip(label: "Length", value: "\(home.length)")
        }
        .accessibilityLabel("Session length, \(home.length) puzzles")
    }

    private var focusChip: some View {
        Menu {
            ForEach(home.habitChoices, id: \.self) { habit in
                Button {
                    Task { await home.chooseFocus(habit) }
                } label: {
                    // The imperative, not the chip word: the menu is where the
                    // user decides what they are working on, and "Blunder-check
                    // every move" is the instruction they are agreeing to.
                    MenuChoice(title: habit.microGoalTitle, isSelected: habit == home.focus?.habit)
                }
            }
        } label: {
            PickerChip(label: "Focus", value: home.focusChipTitle)
        }
        .disabled(home.habitChoices.isEmpty)
        .accessibilityLabel("This week's focus, \(home.focusChipTitle)")
    }

    // MARK: Due today

    private var dueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Due today", qualifier: "\(home.dueCount)")

            VStack(spacing: 0) {
                ForEach(Array(home.due.enumerated()), id: \.element.id) { row in
                    if row.offset > 0 { Divider().padding(.leading, 44) }
                    DueCardRow(card: row.element)
                }
            }
            .padding(.horizontal, 16)
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
    }

    // MARK: Routing

    /// Turns a tapped rating leak into the next session's focus and opens it.
    ///
    /// The habit is resolved against the live leak table so the session carries
    /// the leak's own cost and cause tag rather than a bare habit id — that is
    /// what `SessionAssembler` weights the drill mix by.
    private func consumeLeakRequest() {
        guard let habit = model.consumeTrainingHabit() else { return }
        requestedFocus = home.focus(for: habit)
        route = .puzzles
    }

    @ViewBuilder
    private func destination(for route: TrainRoute) -> some View {
        switch route {
        case .puzzles:
            if let service = home.makeTrainingService() {
                NavigationStack {
                    PuzzleSessionScreen(
                        model: PuzzleSessionModel(driver: service, focus: requestedFocus ?? home.focus)
                    )
                }
            } else {
                unavailable
            }
        case let .drill(kind):
            NavigationStack {
                EndgameDrillScreen(
                    model: EndgameDrillModel(
                        kind: kind,
                        opponent: EngineDrillOpponent(engine: model.engineService),
                        recorder: home.makeTrainingService()
                    )
                )
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Training unavailable", systemImage: "square.grid.3x3")
        } description: {
            Text("The app could not open its databases.")
        }
    }
}

// MARK: - Menu choice

/// One row of a picker menu, with the platform's own selection checkmark.
private struct MenuChoice: View {

    let title: String
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

// MARK: - Picker chip

/// `Length: 10`. A label, its value, and a disclosure chevron.
///
/// A chip rather than a segmented control: there are three lengths and nine
/// habits, and a control that has to be wide enough for the longest habit name
/// would take the whole row for a decision most users make once.
private struct PickerChip: View {

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.secondary)
            Text(value)
                .typeRole(.caption, appliesForeground: false)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                .fill(Palette.surfaceSunken.dynamic)
        )
    }
}

// MARK: - Due row

/// One due card: a decay ring, the concept, and how well the theme is known.
private struct DueCardRow: View {

    let card: DueCardPresentation

    var body: some View {
        HStack(spacing: 12) {
            RecallRing(recall: card.recall)
                .frame(width: 22, height: 22)

            Text(card.subtitle)
                .typeRole(.body)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.subtitle)
        .accessibilityValue("\(Int((card.recall * 100).rounded())) percent recalled")
    }
}

/// How much of this card is still remembered.
///
/// The ring empties as the memory decays, which is the one thing about spaced
/// repetition worth showing: it explains *why* this card is here today without
/// putting a stability figure or an interval on screen for the user to optimise
/// against. Drawn in the accent's own family rather than red at the low end — a
/// card the scheduler expects to be forgotten is working exactly as designed.
private struct RecallRing: View {

    let recall: Double

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.surfaceSunken.dynamic, lineWidth: 3)

            Circle()
                .trim(from: 0, to: max(0.02, min(1, recall)))
                .stroke(Palette.accent.dynamic, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Promotion

/// The rung the user has earned, offered once.
///
/// Deliberately a row and not a modal. `Docs/DesignBrief.md` reserves
/// celebration for rung completion "at most", and even then restrained — so this
/// is a line of type, the rung's own name, and one bordered button. No confetti,
/// no medal, no sheet to dismiss: the reward for clearing a rung is the next
/// rung, and dressing it up would make the next four weeks of work look like the
/// price of an animation.
///
/// The button is bordered rather than filled because `Start` is this screen's one
/// filled action, and today's session is still the thing to do.
private struct PromotionRow: View {

    let promotion: TrainHomeModel.Promotion
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rung \(promotion.rung)")
                .typeRole(.label)

            Text(promotion.title)
                .typeRole(.headline)

            Text("Every required skill on your rung is met.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Button("Move up", action: onAccept)
                .buttonStyle(.secondaryAction)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}

/// Where the Train tab can go.
enum TrainRoute: Identifiable, Hashable {
    case puzzles
    case drill(EndgameDrillKind)

    var id: String {
        switch self {
        case .puzzles: "puzzles"
        case let .drill(kind): "drill.\(kind.rawValue)"
        }
    }
}

extension View {

    /// A full-screen cover on iPhone, a sheet on Mac.
    ///
    /// Both are the same decision: a solve session takes the whole surface,
    /// because a board with a tab bar under it invites leaving mid-puzzle, and a
    /// half-finished puzzle is scored as a failure.
    @ViewBuilder
    func trainingCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
            fullScreenCover(item: item, content: content)
        #else
            sheet(item: item, content: content)
        #endif
    }
}
