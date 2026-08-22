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

                // Below the set, always. The daily set is the day's work and
                // this is the addition to it; putting them side by side would
                // make them read as two ways to train and invite picking one.
                if home.canStartSession {
                    calculationCard
                }

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
        // The leak request is consumed before the curriculum recompute, not
        // after it. `measure()` replays up to twenty games, and a user who
        // tapped "Train blunder-checking" on Profile was left looking at this
        // screen for the length of that replay, with nothing saying a session
        // was coming.
        .task {
            await home.prepare()
            consumeLeakRequest()
            consumeStartRequest()
            await home.measure()
        }
        // The tab stays alive once visited, so a leak tapped later would never
        // reach `task`. Both entry points run the same consume, which is what
        // stops a stale request aiming a session the user has moved on from.
        .onChange(of: model.pendingTrainingHabit) { _, habit in
            if habit != nil { consumeLeakRequest() }
        }
        // Same pair for Today's CTA, and for the same reason.
        .onChange(of: model.pendingTrainRequest) { _, requested in
            if requested { consumeStartRequest() }
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
                    Text("Today's set").typeRole(.headline)
                    Text(setSubtitle).typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let focus = focusLine {
                Text(focus)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LengthSelector(lengths: TrainHomeModel.lengths, selection: $home.length)

            Button(startTitle) { route = .puzzles }
                .buttonStyle(.primaryAction)
                .disabled(!home.canStartSession)
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    /// What the set contains, in the order it arrives in.
    ///
    /// The old subtitle counted the puzzles and nothing else, which is not what
    /// a set is: a lesson or its exercise comes first, and the length promise
    /// covering only the puzzles is a promise the user cannot budget against.
    /// The concept is named by *family*, never by title — "The outpost" is most
    /// of the answer to its own exercise.
    private var setSubtitle: String {
        guard home.canStartSession else { return "The puzzle corpus is missing from this build." }

        let puzzles = "\(home.length) puzzles"
        let opening: String
        if let selection = home.nextConcept {
            let family = selection.concept.family.label.lowercased()
            let article = PuzzleConcept.article(for: family)
            opening = selection.teachFirst
                ? "\(article.prefix(1).uppercased() + article.dropFirst()) \(family) to learn, then \(puzzles)"
                : "\(article.prefix(1).uppercased() + article.dropFirst()) \(family) to practise, then \(puzzles)"
        } else {
            opening = puzzles.prefix(1).uppercased() + puzzles.dropFirst()
        }

        guard home.dueCount > 0 else { return "\(opening)." }
        // "Due for review" is the scheduler's word for it. What the user
        // recognises is that these are the ones they got wrong before.
        return "\(opening) — \(home.dueCount) of them you missed before."
    }

    /// The habit the mix is weighted toward, and where it came from.
    ///
    /// Computed for every session and shown nowhere: sixty per cent of the
    /// fresh puzzles are themed to it, so the one line that connects "your leak
    /// is king safety" to "these puzzles" was missing from both ends.
    private var focusLine: String? {
        guard home.canStartSession, home.focus != nil else { return nil }
        return "Weighted toward \(home.focusChipTitle.lowercased()) — the habit your own games say costs you most."
    }

    private var startTitle: String {
        guard home.canStartSession else { return "Start" }
        return "Start the set · ~\(home.estimatedMinutes) min"
    }

    // MARK: Calculation

    /// The slow set: a few puzzles from above the user's band, worked out rather
    /// than recognised.
    ///
    /// ## Why this is not a fourth Length chip
    ///
    /// Because it is not more of the same thing. The daily set is a recognition
    /// dose — inside 150 points of the user, graded `.easy` under ten seconds,
    /// over the moment the first move is right — and doing fifteen of those
    /// instead of ten trains the same reflex for longer. What separates 1500
    /// from 2000 is holding a line four to six plies deep, which needs a
    /// position the user *cannot* see at a glance and permission to sit on it.
    /// Neither is available anywhere on the length control, so it is a separate
    /// step with its own price on its own button.
    ///
    /// Bordered rather than filled: `Start the set` is this screen's one accent,
    /// and the daily set is still the thing to do first.
    private var calculationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                // A branching arrow, sunken like the set's own glyph. A tree of
                // variations is what the card is asking for, and it is the one
                // symbol in the set that is not a board or a clock — both of
                // which would say the opposite of what this mode means.
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.surfaceSunken.dynamic))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Calculation").typeRole(.headline)
                    Text(calculationSubtitle)
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            // No button at all when the band is empty, rather than a disabled
            // one. A control that names three puzzles and twelve minutes while
            // the line above it says there are none is the app arguing with
            // itself, and a greyed-out button reads as something the user did
            // wrong.
            if home.canStartCalculation {
                Button(calculationTitle) { route = .calculation }
                    .buttonStyle(.secondaryAction)
            }
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    /// What the calculation set is, or why there is none. See ``CalculationCopy``.
    private var calculationSubtitle: String {
        guard home.canStartCalculation else {
            return CalculationCopy.emptyBand(home.calculationBand)
        }
        return CalculationCopy.offer(
            offsetLabel: home.calculationOffsetLabel,
            minutesPerPuzzle: home.calculationMinutesPerPuzzle
        )
    }

    private var calculationTitle: String {
        CalculationCopy.title(puzzles: home.calculationSupply, minutes: home.calculationMinutes)
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

            // "Set" and "idea" are this screen's own words and nothing defined
            // them. One sentence buys both, and the row's own affordance —
            // tapping to read a lesson again — with it.
            Text("Each set teaches one idea before its puzzles. Tap one to read it again.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

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

    /// What is still to come, said in enough detail to be worth reading.
    ///
    /// "17 more, one per set, as your rating reaches them" is a count and a
    /// scheduling rule, and it answers none of the questions somebody looking at
    /// this row is asking: what *are* they, and what am I working towards?
    ///
    /// The old comment's argument for withholding them is right about exactly
    /// one family. A positional title is very nearly its own solution — being
    /// told "the outpost" is coming hands over most of the exercise. An opening
    /// and an endgame are the opposite: they are named techniques, the name is
    /// the thing being learned, and knowing that Lucena is ahead spoils nothing
    /// anybody could have solved from the position anyway. So the two nameable
    /// families are named, and the one that would be spoiled is counted.
    /// The concepts that can actually turn up next, named.
    private var nextUpTitles: [String] {
        home.covered.filter { !$0.isTaught && $0.isUnlocked }.map(\.concept.title)
    }

    /// What is waiting on rating, grouped by the rating that releases it.
    ///
    /// Shown as thresholds rather than as a queue because that is what they
    /// are. A locked concept is not scheduled behind the others — it is not in
    /// `TrainingConcept.available(atRating:)` at all, so no amount of playing
    /// sets brings it closer. Only the rating does.
    private var lockedTiers: [(rating: Int, titles: [String])] {
        let locked = home.covered.filter { !$0.isTaught && !$0.isUnlocked }
        return Dictionary(grouping: locked, by: \.concept.fromRating)
            .sorted { $0.key < $1.key }
            .map { (rating: $0.key, titles: $0.value.map(\.concept.title)) }
    }

    private func upcomingRow(_ remaining: Int) -> some View {
        let next = nextUpTitles
        let tiers = lockedTiers

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceSunken.dynamic)
                    .frame(width: 32, height: 32)
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                // The headline counts only what can actually arrive. The old
                // line counted every untaught concept and said "one per set",
                // which invites the arithmetic the reader then does: thirteen
                // sets, five puzzles each, sixty-five puzzles. Eleven of those
                // thirteen were not queued behind anything — they were waiting
                // on rating, and no amount of puzzles releases them.
                if next.isEmpty {
                    Text("Nothing new until your rating goes up")
                        .typeRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(next.count == 1 ? "1 more to come, in your next set" : "\(next.count) more to come, one per set")
                        .typeRole(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(next.joined(separator: ", "))
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tiers.isEmpty {
                    Text("Then, as your rating climbs")
                        .typeRole(.caption, appliesForeground: false)
                        .foregroundStyle(.tertiary)
                    ForEach(tiers, id: \.rating) { tier in
                        Text("\(tier.rating)+ · \(tier.titles.joined(separator: ", "))")
                            .typeRole(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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
        // A leak tap used to route into the cover unconditionally, which is how
        // a build with no puzzle corpus produced a full-screen "Training
        // unavailable" with no way back. `Start` has always been disabled in
        // that state; this path simply bypassed it.
        guard home.canStartSession else { return }
        requestedFocus = home.focus(for: habit)
        route = .puzzles
    }

    /// Opens the set Today's CTA already priced.
    ///
    /// Today names the length the user chose here and the minutes it costs, so
    /// arriving at a length selector and a second `Start` is the app asking
    /// again for a decision it already has. The week's own focus is left alone —
    /// this is the ordinary daily set, not a leak drill.
    ///
    /// The `canStartSession` guard is the same one `Start` carries: a build with
    /// no puzzle corpus must not answer the CTA with a full-screen "Training
    /// unavailable" the user has to find their way out of.
    private func consumeStartRequest() {
        guard model.consumeTrainRequest() else { return }
        guard home.canStartSession, route == nil else { return }
        route = .puzzles
    }

    @ViewBuilder
    private func destination(for route: TrainRoute) -> some View {
        switch route {
        case .puzzles:
            if let service = home.makeTrainingService() {
                // The concept the card has been advertising, handed over rather
                // than resolved a second time. Both sides ask the same
                // scheduler with the same rows, so they normally agree — but
                // "an endgame to learn, then 10 puzzles" is a promise, and a
                // second resolution can answer differently the moment anything
                // in between touches `lastSeenAt`. Nil when the home screen's
                // read has not landed yet, in which case the session resolves
                // its own, which is what it always did.
                let session = PuzzleSessionModel(
                    driver: service,
                    focus: requestedFocus ?? home.focus,
                    evaluator: EnginePuzzleEvaluator(service: model.engineService),
                    concept: home.nextConcept,
                    // A leak drill names its own subject on the button that
                    // opened it, so it skips the lesson slot: the scheduler's
                    // next concept is chosen by rotation, and arriving at one
                    // after tapping "Train blunder-checking" reads as the app
                    // ignoring the request.
                    teachesConcept: requestedFocus == nil
                )
                NavigationStack {
                    // A set whose concept was an endgame ends by *offering* the
                    // drill. Handed back rather than pushed from inside the
                    // session, because the drill has its own screen and its own
                    // model and the session cover is not the place to host a
                    // second one — and handed back only when the user asked for
                    // it, so closing a set early is not answered with another
                    // twenty moves.
                    PuzzleSessionScreen(
                        model: session,
                        focusName: (requestedFocus ?? home.focus).map { FocusVocabulary.chipTitle($0.habit) }
                    ) { kind in pendingDrill = kind }
                }
            } else {
                unavailable
            }
        case .calculation:
            if let service = home.makeCalculationService() {
                NavigationStack {
                    // No concept, no focus, no drill handoff. The card priced
                    // this at three puzzles; anything else in front of them is
                    // time the user was not told about, and on the one set whose
                    // premise is that the minutes go on the position.
                    PuzzleSessionScreen(
                        model: PuzzleSessionModel(
                            driver: service,
                            evaluator: EnginePuzzleEvaluator(service: model.engineService),
                            isCalculationSet: true
                        )
                    )
                }
            } else {
                unavailable
            }
        case let .concept(concept):
            if let service = home.makeTrainingService() {
                NavigationStack {
                    // The same handoff as the set. Without it, revisiting an
                    // endgame technique from the training list showed the
                    // lesson, said "Got it", and then went back to this screen
                    // having practised nothing — which is the one thing that
                    // row advertises.
                    PuzzleSessionScreen(
                        model: PuzzleSessionModel(
                            driver: service,
                            evaluator: EnginePuzzleEvaluator(service: model.engineService),
                            soloConcept: concept
                        )
                    ) { kind in pendingDrill = kind }
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

    /// The cover's root when there is nothing to serve.
    ///
    /// It carries its own way out: this is a full-screen cover, which cannot be
    /// swiped away, and the stage it replaces is the one that would have had
    /// the close button.
    private var unavailable: some View {
        ContentUnavailableView {
            Label("Training unavailable", systemImage: "square.grid.3x3")
        } description: {
            Text("The app could not open its databases.")
        } actions: {
            Button("Back to Train") { route = nil }
                .buttonStyle(.secondaryAction)
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
        .accessibilityLabel("Set length")
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
            // "Rung" stays — it is what Profile's ladder calls the same number,
            // and two words for one thing is worse than one unfamiliar word.
            // What was missing is what it means and what accepting it changes.
            Text("Rung \(promotion.rung)")
                .typeRole(.label)

            Text(promotion.title)
                .typeRole(.headline)

            Text("The ladder's next step is unlocked: every required skill on your current rung is "
                + "met. Moving up raises the puzzle difficulty and changes what your sets practise.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Button("Move up to rung \(promotion.rung)", action: onAccept)
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
    /// The slow set, drawn from a band above the user's rating.
    case calculation
    case drill(EndgameDrillKind)
    /// One concept revisited on its own, from the training list.
    case concept(TrainingConcept)

    var id: String {
        switch self {
        case .puzzles: "puzzles"
        case .calculation: "calculation"
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
