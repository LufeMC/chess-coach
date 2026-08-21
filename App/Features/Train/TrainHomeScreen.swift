//
//  TrainHomeScreen.swift
//  ChessCoach
//

import Database
import SwiftUI
import TrainingCore

/// The Train tab: one set, and one decision about it.
///
/// ## Why the drills are no longer a second thing to pick
///
/// This screen used to offer endgame drills as their own grid beside the puzzle
/// set. The stated reason was honest — a drill runs twenty moves and would have
/// made "10 puzzles" mean anywhere from four minutes to forty — but the effect
/// was that endgames got practised by exactly the people who already knew they
/// mattered. Everyone else did the puzzles, because the puzzles had the button.
///
/// Now a set is its puzzles *plus one concept the app chooses*: an opening, an
/// endgame technique or a positional idea, taught the first time and exercised
/// after. The original objection is answered by the length promise covering the
/// puzzles only, which is what the user is actually budgeting time against.
/// Where the concept turns out to be an endgame, the drill is handed back to
/// this screen when the set closes — it still needs its own board and its own
/// twenty moves, it just no longer needs to be *chosen*.
struct TrainHomeScreen: View {

    @Environment(AppModel.self) private var model
    @State private var home = TrainHomeModel()
    @State private var route: TrainRoute?
    /// A focus carried in from a rating leak, replacing the week's habit for
    /// exactly one session.
    @State private var requestedFocus: WeeklyFocus?
    /// The drill the set just finished wants played, opened once the session
    /// cover is out of the way.
    @State private var pendingDrill: EndgameDrillKind?

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

                if !home.covered.isEmpty {
                    coveredSection
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
        // A set closed early still did work. The concept is marked taught the
        // moment its lesson is shown, and every puzzle is graded and written as
        // it is answered — none of that waits for the summary. What did wait
        // was this screen: `.task` runs once on appear, and dismissing a
        // full-screen cover does not re-trigger it, so the training list went
        // on showing the counts from before the session.
        .onChange(of: route) { _, newValue in
            guard newValue == nil else { return }
            Task { await home.load() }
        }
        .onChange(of: pendingDrill) { _, kind in
            guard let kind else { return }
            pendingDrill = nil
            route = .drill(kind)
        }
    }

    // MARK: Queue

    /// The day's one action, and the only decision left to the user.
    ///
    /// ## Why the focus picker is gone
    ///
    /// It offered nine habits and asked the user to pick the one they were
    /// worst at — which is precisely the judgement someone on their way to 2000
    /// does not yet have, and the reason they are here. Choosing it wrong
    /// spends a whole week's sessions rehearsing something that was already
    /// fine. The app computes the week's focus from the user's own leaks and it
    /// is better at it than they are, so the choice is not offered: what is
    /// worth practising is not a preference.
    ///
    /// Length stays, because it is not a judgement about chess. It is the user
    /// saying how much time they have today, which is a thing only they know.
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
                    Text("Set").typeRole(.headline)
                    Text(setSubtitle).typeRole(.caption)
                }

                Spacer(minLength: 0)
            }

            LengthSelector(lengths: TrainHomeModel.lengths, selection: $home.length)

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

    // MARK: What the sets have covered

    /// The training in order, with what has been taught so far marked.
    ///
    /// ## Why this is not the drill grid again
    ///
    /// The grid that used to live here asked "what do you want to practise",
    /// which is the question the user is least equipped to answer. This asks
    /// nothing. It is a record of ground covered, in the order the app covers
    /// it, and the only thing it lets you *do* is go back over something
    /// already taught — a different decision from choosing what comes next, and
    /// a reasonable one to leave with the reader, since it is also the only way
    /// to see a lesson a second time.
    ///
    /// What has not been taught is one line, not twelve. Naming them would hand
    /// over most of the answer to exercises the user has not met — "The
    /// outpost" is very nearly its own solution — and a column of identical
    /// padlocks is a worse thing to look at than a short list of what you have
    /// plus a note that there is more.
    private var coveredSection: some View {
        let taught = home.covered.filter(\.isTaught)
        let remaining = home.covered.count - taught.count

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your training", qualifier: taughtQualifier)

            VStack(spacing: 0) {
                ForEach(Array(taught.enumerated()), id: \.element.id) { row in
                    if row.offset > 0 { Divider().padding(.leading, 44) }
                    CoveredConceptRow(row: row.element) {
                        route = .concept(row.element.concept)
                    }
                }

                if remaining > 0 {
                    if !taught.isEmpty { Divider().padding(.leading, 44) }
                    upcomingRow(remaining)
                }
            }
            .padding(.horizontal, 16)
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
    }

    private func upcomingRow(_ remaining: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceSunken.dynamic)
                    .frame(width: 32, height: 32)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            Text(
                home.covered.contains(where: \.isTaught)
                    ? "\(remaining) more, as your sets reach them"
                    : "\(remaining) ideas your sets will teach you"
            )
            .typeRole(.body, appliesForeground: false)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private var taughtQualifier: String {
        "\(home.covered.filter(\.isTaught).count) of \(home.covered.count)"
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
                let session = PuzzleSessionModel(
                    driver: service,
                    focus: requestedFocus ?? home.focus,
                    evaluator: EnginePuzzleEvaluator(service: model.engineService)
                )
                NavigationStack {
                    PuzzleSessionScreen(model: session)
                }
                // A set whose concept was an endgame ends by asking for the
                // drill. Read on dismissal rather than pushed from inside the
                // session, because the drill has its own screen and its own
                // model and the session cover is not the place to host a
                // second one.
                .onDisappear { pendingDrill = session.pendingDrill }
            } else {
                unavailable
            }
        case let .concept(concept):
            if let service = home.makeTrainingService() {
                NavigationStack {
                    PuzzleSessionScreen(
                        model: PuzzleSessionModel(
                            driver: service,
                            evaluator: EnginePuzzleEvaluator(service: model.engineService),
                            soloConcept: concept
                        )
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

// MARK: - Length selector

/// The three session lengths, all of them visible, one tap to change.
///
/// Not a `Menu`. The platform picker hides three short numbers behind a tap and
/// a system sheet, which is a lot of ceremony for the only choice on the screen
/// — and it renders as someone else's control in the middle of a hand-built
/// one. With the focus decision gone there is room to simply show them.
///
/// The selected pill is *raised*, not accented: this screen's one accent is
/// spent on `Start`, and a second filled accent would make the user read both
/// to find out which one is the action.
private struct LengthSelector: View {

    let lengths: [Int]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(lengths, id: \.self) { length in
                segment(length)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.chip + 4, style: .continuous)
                .fill(Palette.surfaceSunken.dynamic)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session length")
    }

    private func segment(_ length: Int) -> some View {
        let isSelected = length == selection
        return Button {
            withAnimation(Motion.crossfade) { selection = length }
        } label: {
            VStack(spacing: 1) {
                Text("\(length)")
                    .typeRole(.headline, monospacedDigits: true, appliesForeground: false)
                Text("puzzles")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                    .fill(isSelected ? Palette.surfaceRaised.dynamic : .clear)
                    .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 3, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(length) puzzles")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
    /// One concept revisited on its own, from the training list.
    case concept(TrainingConcept)

    var id: String {
        switch self {
        case .puzzles: "puzzles"
        case let .drill(kind): "drill.\(kind.rawValue)"
        case let .concept(concept): "concept.\(concept.id)"
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

// MARK: - Covered concept row

/// One line of the training list: what it is, whether it has been taught, and
/// how the exercises have gone.
private struct CoveredConceptRow: View {

    let row: TrainHomeModel.CoveredConcept
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                marker

                VStack(alignment: .leading, spacing: 2) {
                    // An untaught concept is named only by its family. The
                    // title of a positional idea is most of the answer to its
                    // own exercise.
                    Text(row.isTaught ? row.concept.title : "\(row.concept.family.label) — not yet")
                        .typeRole(.body, appliesForeground: false)
                        .foregroundStyle(row.isTaught ? .primary : .secondary)
                        .multilineTextAlignment(.leading)

                    if row.isTaught {
                        Text(row.record.map { "\(row.concept.family.label) · \($0)" }
                            ?? row.concept.family.label)
                            .typeRole(.caption)
                    }
                }

                Spacer(minLength: 0)

                if row.isTaught {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isTaught)
        .accessibilityLabel(
            row.isTaught
                ? "\(row.concept.title), \(row.concept.family.label). Practise again."
                : "\(row.concept.family.label), not covered yet"
        )
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(row.isTaught ? Palette.accentWash.dynamic : Palette.surfaceSunken.dynamic)
                .frame(width: 32, height: 32)
            Image(systemName: row.isTaught ? "checkmark" : "lock.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(row.isTaught ? Palette.accent.dynamic : Color.secondary)
        }
    }
}
