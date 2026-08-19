//
//  TodayScreen.swift
//  ChessCoach
//

import SwiftUI

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

    var body: some View {
        let plan = todayModel.plan

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Lead with the present. On a return, "Good to see you." is the
                // first thing read — before any accounting of the absence.
                returnBanner(plan)

                RungCard(rung: todayModel.rung, isMeasuring: todayModel.isRungProgressPending)

                StreakStrip(
                    slots: todayModel.daySlots,
                    streak: todayModel.streak,
                    todayStarted: !(todayModel.snapshot?.progress ?? .zero).isUntouched
                )

                completionBanner(plan)

                checklist(plan)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .animation(Motion.standard, value: plan)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle("Today")
        #if os(iOS)
            .toolbar {
                // Past games live behind the history glyph rather than a fifth
                // tab: reviewing is something you do after a game, not a
                // destination you navigate to cold.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GameLibraryScreen()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Past games")
                }
                // Settings lives behind a gear rather than a fifth tab: it is
                // configuration, not part of the daily loop.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        #endif
        .safeAreaInset(edge: .bottom) {
            actionBar(plan)
        }
        .task { await todayModel.load() }
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

            VStack(spacing: 14) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    TodayStepRow(state: step)
                        .transition(
                            .opacity.animation(Motion.staggered(index: index))
                        )
                }
            }
            .padding(16)
            .elevation(.raised, cornerRadius: CornerRadius.card)
        }
        .padding(.top, 4)
    }

    // MARK: Action bar

    private func actionBar(_ plan: TodayPlan) -> some View {
        VStack(spacing: 4) {
            TodayActionButton(action: plan.primary) { perform(plan.primary) }

            if let alternative = plan.alternative {
                TodayActionButton(action: alternative) { perform(alternative) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.regularMaterial)
    }

    private func perform(_ action: TodayAction) {
        model.navigate(to: todayModel.route(for: action.destination))
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
                        title: "Tactical Vision",
                        progress: hasHistory ? 0.35 : nil,
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

                VStack(spacing: 14) {
                    ForEach(plan.steps) { TodayStepRow(state: $0) }
                }
                .padding(16)
                .elevation(.raised, cornerRadius: CornerRadius.card)

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
