import SwiftUI

/// The daily loop: 1 game → 3 moments → 10 puzzles.
///
/// One filled button on the screen, and it names the *next incomplete step*
/// rather than offering a menu. The three steps are status, not buttons.
struct TodayScreen: View {
    @Environment(AppModel.self) private var model

    // Placeholder progress until the training services are wired in.
    @State private var gamePlayed = false
    @State private var momentsReviewed = 0
    @State private var puzzlesDone = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                RungCard(
                    rung: 2,
                    title: "Tactical Vision",
                    progress: 0.35,
                    focusHabit: "check opponent threats"
                )
                StreakStrip(completedDays: [0, 1, 2, 4], today: 5, streak: 4)
                stepList
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Today")
        #if os(iOS)
            // Settings lives behind a gear rather than a fifth tab: it is
            // configuration, not part of the daily loop.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        #endif
        .safeAreaInset(edge: .bottom) {
            primaryAction
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.regularMaterial)
        }
    }

    private var stepList: some View {
        VStack(spacing: 12) {
            StepRow(
                index: 1,
                title: "1 game",
                detail: gamePlayed ? "done" : "0/1",
                state: gamePlayed ? .done : .current
            )
            StepRow(
                index: 2,
                title: "3 moments",
                detail: "\(momentsReviewed)/3",
                state: stepState(done: momentsReviewed >= 3, unlocked: gamePlayed)
            )
            StepRow(
                index: 3,
                title: "10 puzzles",
                detail: "\(puzzlesDone)/10",
                state: stepState(done: puzzlesDone >= 10, unlocked: momentsReviewed >= 3)
            )
        }
        .padding(.vertical, 4)
    }

    private func stepState(done: Bool, unlocked: Bool) -> StepRow.State {
        if done { return .done }
        return unlocked ? .current : .pending
    }

    private var primaryAction: some View {
        Button {
            model.navigate(to: nextRoute)
        } label: {
            Text(nextActionTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var nextActionTitle: String {
        if !gamePlayed { return "Play Oscar" }
        if momentsReviewed < 3 { return "Review 3 moments" }
        if puzzlesDone < 10 { return "Train 10 puzzles" }
        return "Done for today"
    }

    private var nextRoute: AppModel.Route {
        if !gamePlayed { return .play }
        if momentsReviewed < 3 { return .play }
        return .train
    }
}

/// Rung + weekly focus in a single card — the habit rides as a chip rather than
/// claiming a card of its own, so the screen keeps one clear hierarchy.
private struct RungCard: View {
    let rung: Int
    let title: String
    let progress: Double
    let focusHabit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RUNG \(rung)")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Focus: \(focusHabit)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
            }

            Text(title)
                .font(.title3.bold())

            Capsule()
                .fill(.quaternary)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 6)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary))
    }
}

/// A training log, not a game streak: seven small day marks, count at
/// `.subheadline` rather than a 48pt hero.
private struct StreakStrip: View {
    let completedDays: Set<Int>
    let today: Int
    let streak: Int

    private let labels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { day in
                    VStack(spacing: 5) {
                        Text(labels[day])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        marker(for: day)
                    }
                    .frame(width: 24)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                Text("\(streak)")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary))
    }

    @ViewBuilder
    private func marker(for day: Int) -> some View {
        if completedDays.contains(day) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.background)
                }
        } else if day == today {
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: 18, height: 18)
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: 18, height: 18)
        }
    }
}

private struct StepRow: View {
    enum State { case done, current, pending }

    let index: Int
    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 24, height: 24)

            Text(title)
                .font(.body.weight(.medium))
                .strikethrough(state == .done)
                .foregroundStyle(state == .done ? .secondary : .primary)

            Spacer()

            Text(detail)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
        case .current:
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .overlay {
                    Text("\(index)")
                        .font(.caption2.weight(.bold))
                }
        case .pending:
            Circle().fill(.quaternary)
        }
    }
}
