//
//  TodayScreen.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// The daily loop: 1 game → 3 moments → 10 puzzles.
///
/// ## Four states, one screen
///
/// First run, mid-progress, complete and returned-after-a-gap are all the *same
/// screen* with different content. Nothing is swapped out for a trophy, a
/// mascot, or a marketing empty state. That continuity is what makes the
/// checklist satisfying to finish and survivable to miss: the user always
/// recognises where they are, and the rung card and the week strip are still
/// exactly where they left them.
///
/// One filled button, and it names the next incomplete step, who it is against,
/// and what it costs, rather than offering a menu. The three steps are status,
/// not buttons.
struct TodayScreen: View {

    @Environment(AppModel.self) private var model
    @State private var todayModel = TodayModel()

    // The training surface, hosted here since the merge. Home and Train were two
    // front doors to one daily loop — Home's "Puzzles 1 of 10" *was* Train's
    // "Today's set" — and the split was already producing disagreeing numbers,
    // because Home never saw the length chosen on the other screen. One screen
    // cannot disagree with itself.
    @State private var trainModel = TrainHomeModel()
    @State private var trainingRoute: TrainRoute?
    /// A focus carried in from a rating leak, replacing the week's habit for
    /// exactly one session.
    @State private var requestedFocus: WeeklyFocus?
    /// The drill the set just finished wants played, opened once the session
    /// cover is out of the way.
    @State private var pendingDrill: EndgameDrillKind?

    var body: some View {
        let plan = todayModel.plan

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Lead with the present. On a return, "Good to see you." is the
                // first thing read — before any accounting of the absence.
                returnBanner(plan)

                unavailableBanner

                // Directly above the card it rewrites. This control used to
                // exist only on the Train tab, so a user who lived on Home sat
                // at a full rung bar forever with no way to take the promotion
                // the bar was telling them they had earned.
                if let promotion = trainModel.promotion {
                    PromotionRow(promotion: promotion) {
                        Task {
                            await trainModel.acceptPromotion()
                            await todayModel.load()
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                RungCard(rung: todayModel.rung, isMeasuring: todayModel.isRungProgressPending)

                StreakStrip(
                    slots: todayModel.daySlots,
                    streak: todayModel.streak,
                    todayStarted: !(todayModel.snapshot?.progress ?? .zero).isUntouched
                )

                completionBanner(plan)

                checklist(plan)

                // The one decision left to the user, next to the squares it
                // resizes. It is not a judgement about chess — it is them
                // saying how much time they have today, which is the one thing
                // only they know. Hidden once the set is done, when changing it
                // would resize a promise already kept.
                setLengthControl

                practiceMore(plan)

                // The long arc. The three squares above are only today; this is
                // the thing they are for.
                TodayClimbStrip(rating: todayModel.snapshot?.userRating)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .animation(Motion.standard, value: plan)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        // No screen title. The stat row is the header, the green rung banner
        // names where you are, and a large "Today" above both would push the
        // path down a third of the screen to say what the tab already said.
        // Past games and settings ride at the end of the stat row: both are
        // still one tap from here, neither is worth a fifth tab.
        #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                TodayStatHeader(
                    rating: todayModel.snapshot?.userRating,
                    ratingDelta: todayModel.snapshot?.ratingDelta
                )
            }
        #endif
        .safeAreaInset(edge: .bottom) {
            actionBar(plan)
        }
        .task {
            await todayModel.load()
            await trainModel.prepare()
            consumeLeakRequest()
            consumeStartRequest()
        }
        // The tab stays alive once visited, so a request arriving later would
        // never reach `task`. Both entry points run the same consume, which is
        // what stops a stale request aiming a session the user has moved on
        // from.
        .onChange(of: model.pendingTrainingHabit) { _, habit in
            if habit != nil { consumeLeakRequest() }
        }
        .onChange(of: model.pendingTrainRequest) { _, requested in
            if requested { consumeStartRequest() }
        }
        .trainingCover(item: $trainingRoute) { route in
            trainingDestination(for: route)
        }
        // A set closed early still did work: the concept is marked taught the
        // moment its lesson is shown and every puzzle is graded as it is
        // answered. Both models are reloaded, not just the training one — the
        // squares, the streak and the CTA all live on this screen now, and
        // dismissing a cover does not re-run `task`.
        .onChange(of: trainingRoute) { _, newValue in
            guard newValue == nil else { return }
            requestedFocus = nil
            Task {
                await todayModel.load()
                await trainModel.load()
            }
        }
        .onChange(of: pendingDrill) { _, kind in
            guard let kind else { return }
            pendingDrill = nil
            trainingRoute = .drill(kind)
        }
    }

    /// The one decision left to the user, next to the squares it resizes.
    ///
    /// Not a judgement about chess — it is them saying how much time they have
    /// today, which is the one thing only they know. Hidden once the set is
    /// done, when changing it would resize a promise already kept.
    @ViewBuilder
    private var setLengthControl: some View {
        if todayModel.snapshot?.hasHistory == true,
            todayModel.snapshot?.progress.isDone(.puzzles) == false
        {
            LengthSelector(lengths: TrainHomeModel.lengths, selection: $todayModel.setLength)
        }
    }

    /// Below the plan, always.
    ///
    /// The plan is the day's recommendation; this is the answer to "what if I
    /// want more", and putting them side by side would make them read as two
    /// ways to train and invite picking one. Hidden on a first run, where the
    /// user has no context for anything beyond the first instruction.
    @ViewBuilder
    private func practiceMore(_ plan: TodayPlan) -> some View {
        if todayModel.snapshot?.hasHistory == true {
            PracticeMoreSection(
                calculationSupply: trainModel.calculationSupply,
                calculationBand: trainModel.calculationBand,
                dueCount: trainModel.dueCount,
                taughtCount: trainModel.covered.filter(\.isTaught).count,
                conceptCount: trainModel.covered.count,
                canRepeatSet: todayModel.snapshot?.progress.isDone(.puzzles) == true,
                onAnotherSet: { startSet(focus: nil) },
                onCalculation: { trainingRoute = .calculation },
                onTraining: { model.navigate(to: .training) }
            )
        }
    }

    // MARK: Banners

    @ViewBuilder
    private func returnBanner(_ plan: TodayPlan) -> some View {
        if plan.greeting != nil || plan.streakNote != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let greeting = plan.greeting {
                    Text(greeting)
                        .typeRole(.title)
                }
                if let note = plan.streakNote {
                    // Said once, without a number. The count of what was lost
                    // has exactly one effect, and it is not returning tomorrow.
                    Text(note)
                        .typeRole(.body, appliesForeground: false)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// Said out loud, because the zeroed screen underneath it is not the truth.
    ///
    /// With no store the streak, the rating and the history all read as a first
    /// run, and the game the user is about to play will be thrown away when it
    /// ends. Silence here is the app letting them spend twenty-five minutes on
    /// a game it has already decided to lose.
    @ViewBuilder
    private var unavailableBanner: some View {
        if todayModel.snapshot?.isUnavailable == true {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your training data could not be opened.")
                    .typeRole(.headline)
                Text("Today's numbers are blank because nothing could be read, and games played now will not be saved. Reopening the app is the first thing to try.")
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .elevation(.raised, cornerRadius: CornerRadius.card)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func completionBanner(_ plan: TodayPlan) -> some View {
        if let note = plan.completionNote {
            VStack(alignment: .leading, spacing: 4) {
                Text(TodayPlanner.completionHeadline)
                    .typeRole(.title)
                // Identity, not praise. "You're on fire" is a claim about a
                // mood that has expired by morning; a vote toward the player
                // you are becoming is as true on day 400 as on day 4.
                Text(note)
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Checklist

    private func checklist(_ plan: TodayPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The tally lives here — small caps, right-aligned, dimmer — and
            // not inside the button. A button carrying "1 of 3" is promising a
            // tally it can only move by one.
            SectionHeader(title: "Today", qualifier: plan.headerQualifier.accessibilityText)

            // Said once, on the day it is needed. "Moments" is this app's own
            // word — the positions the engine flagged in your game — and the
            // CTA one screen-height below uses it as though it were common
            // knowledge. The order is load-bearing too: the game is what
            // produces the moments, which is why puzzles are not first.
            if plan.phase == .firstRun {
                Text("Play a game, review the moments it turned on — the positions the engine flags — then drill the patterns behind them.")
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                // The tab bar carries four glyphs and no labels, by design —
                // but two of the four open ideas that have no icon: the puzzle
                // piece is the whole drill queue, and the bar chart is the leak
                // diagnosis, which is the most valuable screen in the app and
                // the least likely to be found by poking. "Rung" is named here
                // for the same reason: it is on the card directly above and
                // nothing else on this screen says what it counts.
                Text("The puzzle-piece tab holds your drills. The bar chart holds your rating, your rung — which of the four stages of the plan you're on — and the leaks your own games keep showing.")
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The day's work as three squares off a rank — see ``TodayBoardRow``
            // for why this is not a path.
            TodayBoardRow(
                steps: plan.steps,
                opponentName: todayModel.snapshot?.opponentName
            ) { step in
                model.navigate(to: todayModel.route(for: step.destination))
            }
        }
        .padding(.top, 4)
    }

    // MARK: Action bar

    private func actionBar(_ plan: TodayPlan) -> some View {
        VStack(spacing: 4) {
            TodayActionButton(action: plan.primary) { perform(plan.primary) }

            if let alternative = plan.alternative {
                TodayActionButton(action: alternative) { perform(alternative) }
                // The reason an action is being offered, when the action's own
                // name cannot carry it. "Guided game · check opponent threats"
                // says what happens; it cannot say that the rung is stuck
                // waiting on the one metric no ordinary game produces, and a
                // user who does not know that has no reason to choose it.
                if let subtitle = alternative.subtitle {
                    Text(subtitle)
                        .typeRole(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // A solid deck with a hard rule, not a blur. The path scrolls *behind*
        // this, and a translucent strip over the coloured nodes reads as a
        // smudge rather than as a surface.
        .background(Palette.surfaceGround.dynamic)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.hairline.dynamic)
                .frame(height: 2)
        }
    }

    private func perform(_ action: TodayAction) {
        // A coached game is the one destination that is not a plain route: it
        // carries the habit the prompts are about, and Play has to be told
        // before it starts the game rather than after.
        if case .playGuided(let habit) = action.destination {
            model.navigate(toGuidedGame: habit)
            return
        }
        // The set opens here rather than anywhere else, which is the merge in
        // one line: `.train` used to select a tab, and now it is a request this
        // screen consumes.
        if case .train = action.destination {
            startSet(focus: nil)
            return
        }
        model.navigate(to: todayModel.route(for: action.destination))
    }

    // MARK: Training

    /// Opens today's set.
    ///
    /// The `canStartSession` guard is the same one the old `Start` button
    /// carried: a build with no puzzle corpus must not answer the CTA with a
    /// full-screen "Training unavailable" the user has to find their way out of.
    private func startSet(focus: WeeklyFocus?) {
        guard trainModel.canStartSession, trainingRoute == nil else { return }
        requestedFocus = focus
        trainingRoute = .puzzles
    }

    /// Turns a tapped rating leak into the next session's focus and opens it.
    ///
    /// The habit is resolved against the live leak table so the session carries
    /// the leak's own cost and cause tag rather than a bare habit id — that is
    /// what `SessionAssembler` weights the drill mix by.
    private func consumeLeakRequest() {
        guard let habit = model.consumeTrainingHabit() else { return }
        guard trainModel.canStartSession else { return }
        startSet(focus: trainModel.focus(for: habit))
    }

    /// Opens the set a route asked for — Review's Done button, Profile's leak
    /// table, or Today's own CTA.
    ///
    /// Deferred by one runloop turn on purpose. `advance(to:)` pops `todayPath`
    /// and sets the request in the same state change, so presenting immediately
    /// races a navigation pop that is still animating — the classic dropped
    /// SwiftUI presentation, where the cover simply never appears and the button
    /// looks broken.
    private func consumeStartRequest() {
        guard model.consumeTrainRequest() else { return }
        Task { @MainActor in
            await Task.yield()
            startSet(focus: requestedFocus)
        }
    }

    @ViewBuilder
    private func trainingDestination(for route: TrainRoute) -> some View {
        switch route {
        case .puzzles:
            if let service = trainModel.makeTrainingService() {
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
                    focus: requestedFocus ?? trainModel.focus,
                    evaluator: EnginePuzzleEvaluator(service: model.engineService),
                    concept: trainModel.nextConcept,
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
                        focusName: (requestedFocus ?? trainModel.focus).map { FocusVocabulary.chipTitle($0.habit) }
                    ) { kind in pendingDrill = kind }
                }
            } else {
                unavailable
            }
        case .calculation:
            if let service = trainModel.makeCalculationService() {
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
            if let service = trainModel.makeTrainingService() {
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
                        recorder: trainModel.makeTrainingService()
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
            Button("Close") { trainingRoute = nil }
                .buttonStyle(.secondaryAction)
        }
    }
}

// MARK: - Previews

#Preview("First run") {
    TodayPreview(progress: .zero, hasHistory: false, streakBroken: false)
}

#Preview("In progress") {
    TodayPreview(
        progress: DailyProgress(gamePlayed: true, momentsReviewed: 1, puzzlesDone: 0),
        hasHistory: true,
        streakBroken: false
    )
}

#Preview("Complete") {
    TodayPreview(
        progress: DailyProgress(gamePlayed: true, momentsReviewed: 3, puzzlesDone: 10),
        hasHistory: true,
        streakBroken: false
    )
}

#Preview("Streak restarted") {
    TodayPreview(progress: .zero, hasHistory: true, streakBroken: true)
}

/// A database-free rendering of one state, so all four can be inspected in
/// Xcode without contriving a day's worth of rows.
private struct TodayPreview: View {
    let progress: DailyProgress
    let hasHistory: Bool
    let streakBroken: Bool

    var body: some View {
        let plan = TodayPlanner.plan(
            progress: progress,
            hasHistory: hasHistory,
            streakBroken: streakBroken,
            // Named, because the un-named copy is the fallback for a screen that
            // could not read one — previewing it would be previewing the
            // degraded state and calling it the design.
            opponentName: "Oscar"
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let greeting = plan.greeting {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting).typeRole(.title)
                        if let note = plan.streakNote {
                            Text(note)
                                .typeRole(.body, appliesForeground: false)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                RungCard(
                    rung: RungPresentation(
                        rung: 2,
                        rungCount: 4,
                        title: "Tactical Vision",
                        skills: hasHistory
                            ? RungSkillProgress(met: 1, total: 3, unmeasured: 1)
                            : nil,
                        focusHabit: hasHistory ? "Check opponent threats" : nil,
                        unmeasuredNote: RungPresentation.firstRunNote
                    ),
                    isMeasuring: false
                )

                StreakStrip(
                    slots: previewSlots,
                    streak: hasHistory && !streakBroken ? .streak(4) : nil,
                    todayStarted: !progress.isUntouched
                )

                if let note = plan.completionNote {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TodayPlanner.completionHeadline).typeRole(.title)
                        Text(note)
                            .typeRole(.body, appliesForeground: false)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionHeader(title: "Today", qualifier: plan.headerQualifier.accessibilityText)

                TodayPathView(steps: plan.steps, opponentName: "Oscar") { _ in }

                VStack(spacing: 4) {
                    TodayActionButton(action: plan.primary) {}
                    if let alternative = plan.alternative {
                        TodayActionButton(action: alternative) {}
                    }
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
    }

    private var previewSlots: [DaySlot] {
        let initials = ["S", "M", "T", "W", "T", "F", "S"]
        let markers: [DayMarker] = hasHistory
            ? (streakBroken
                ? [.done, .done, .missed, .missed, .today, .tomorrow, .upcoming]
                : [.done, .done, .done, .done, .today, .tomorrow, .upcoming])
            : [.upcoming, .upcoming, .upcoming, .upcoming, .today, .tomorrow, .upcoming]
        return zip(initials.indices, markers).map { index, marker in
            DaySlot(dayKey: "d\(index)", initial: initials[index], marker: marker)
        }
    }
}
