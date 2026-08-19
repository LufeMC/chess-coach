//
//  TodayComponents.swift
//  ChessCoach
//

import SwiftUI

// MARK: - Rung card

/// Rung, weekly focus, and required-skill progress in one card.
///
/// The habit rides as a chip rather than claiming a card of its own, so the
/// screen keeps a single hierarchy: where you are, then what today asks of you.
struct RungCard: View {
    let rung: RungPresentation
    /// True while the progress figure is still being computed. Shows a skeleton
    /// in the bar's exact geometry rather than an empty bar, which would be a
    /// claim of zero progress.
    let isMeasuring: Bool

    private let barHeight: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rung \(rung.rung)")
                    .typeRole(.label, appliesForeground: false)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let focusHabit = rung.focusHabit {
                    FocusChip(text: focusHabit)
                }
            }

            Text(rung.title)
                .typeRole(.headline)

            progressArea
        }
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    @ViewBuilder
    private var progressArea: some View {
        if let progress = rung.progress {
            ProgressTrack(progress: progress)
                .frame(height: barHeight)
                .accessibilityLabel("Rung progress")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        } else if isMeasuring {
            // Exactly the bar's geometry, so nothing moves when the real value
            // lands. That is the entire job of a skeleton.
            SkeletonView(height: barHeight, cornerRadius: barHeight / 2)
        } else {
            // A pending condition gets a dashed slot, never an illustration and
            // never a zeroed bar. The note states what is missing and stops.
            HStack(spacing: 8) {
                Capsule()
                    .strokeBorder(
                        Palette.hairlinePending.dynamic,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: 44, height: barHeight)
                Text(rung.unmeasuredNote)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ProgressTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceSunken.dynamic)
                Capsule()
                    .fill(Palette.accent.dynamic)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

private struct FocusChip: View {
    let text: String

    var body: some View {
        Text(text)
            .typeRole(.caption, appliesForeground: false)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Palette.surfaceSunken.dynamic)
            )
            .accessibilityLabel("This week's focus: \(text)")
    }
}

// MARK: - Streak strip

/// Seven day marks and, once there is one, the streak count.
///
/// A training log, not a scoreboard. The count sits at caption size rather than
/// as a 48pt hero, and there is no flame: heat metaphors escalate, and by day
/// 40 the only moves left are louder or a let-down.
struct StreakStrip: View {
    let slots: [DaySlot]
    /// Nil below one day — and nil is rendered as *nothing*, not as a zero.
    let streak: Denominator?
    /// Whether today already has progress, which changes today's mark from a
    /// dashed "not yet" to a solid "underway".
    let todayStarted: Bool

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                ForEach(slots) { slot in
                    VStack(spacing: 6) {
                        Text(slot.initial)
                            .typeRole(.label, appliesForeground: false)
                            .foregroundStyle(.tertiary)
                        DayMarkerView(marker: slot.marker, todayStarted: todayStarted)
                    }
                    .frame(width: 22)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: slot))
                }
            }

            Spacer(minLength: 8)

            if let streak {
                DenominatorText(streak, role: .caption)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }

    private func accessibilityLabel(for slot: DaySlot) -> String {
        switch slot.marker {
        case .done: "\(slot.initial), done"
        case .missed: "\(slot.initial), no session"
        case .today: "\(slot.initial), today"
        case .tomorrow: "\(slot.initial), tomorrow"
        case .upcoming: "\(slot.initial), upcoming"
        }
    }
}

private struct DayMarkerView: View {
    let marker: DayMarker
    let todayStarted: Bool

    private let size: CGFloat = 18

    var body: some View {
        Group {
            switch marker {
            case .done:
                Circle()
                    .fill(Palette.accent.dynamic)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                    }

            case .missed:
                // A plain grey circle. Never red, never an X, never a break in
                // a chain: a gap in the record, not a wound. The user already
                // knows they missed it; the app's only job is to not make that
                // the loudest thing on the screen.
                Circle().fill(Palette.inactiveMark.dynamic)

            case .today:
                Circle()
                    .strokeBorder(
                        Palette.accent.dynamic,
                        style: todayStarted
                            ? StrokeStyle(lineWidth: 2)
                            : StrokeStyle(lineWidth: 2, dash: [3, 2.5])
                    )

            case .tomorrow, .upcoming:
                // Dashed, so "not yet" cannot be mistaken for "missed".
                Circle()
                    .strokeBorder(
                        Palette.hairlinePending.dynamic
                            .opacity(marker == .tomorrow ? 1 : 0.6),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Step row

/// One checklist row. Status, not a button — the CTA is the only thing on this
/// screen that takes an order.
struct TodayStepRow: View {
    let state: StepRowState

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 22, height: 22)

            Text(state.title)
                // Completed rows shift to secondary and keep the check filled.
                // No strikethrough: a line through finished work reads as
                // cancellation, which is the opposite of what happened.
                .typeRole(.headline, appliesForeground: false)
                .foregroundStyle(foreground)

            Spacer(minLength: 8)

            if let reason = state.lockedReason {
                Text(reason)
                    .typeRole(.caption)
            } else if let tally = state.tally {
                DenominatorText(
                    tally,
                    role: .caption,
                    valueStyle: AnyShapeStyle(
                        state.status == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                    )
                )
            }
        }
        .opacity(state.status.isDimmed ? 0.45 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(state.status == .locked ? (state.lockedReason ?? "") : "")
    }

    private var foreground: AnyShapeStyle {
        state.status == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 21))
                .foregroundStyle(Palette.accent.dynamic)
                .transition(.scale.combined(with: .opacity))

        case .current:
            Circle()
                .strokeBorder(Palette.accent.dynamic, lineWidth: 2)
                .overlay {
                    Text("\(state.step.rawValue)")
                        .typeRole(.label, appliesForeground: false)
                        .foregroundStyle(Palette.accent.dynamic)
                }

        case .available:
            Circle()
                .strokeBorder(Palette.hairline.dynamic, lineWidth: 1.5)
                .overlay {
                    Text("\(state.step.rawValue)")
                        .typeRole(.label, appliesForeground: false)
                        .foregroundStyle(.secondary)
                }

        case .locked:
            Circle()
                .strokeBorder(
                    Palette.hairlinePending.dynamic,
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])
                )
        }
    }
}

// MARK: - Action

/// Renders a ``TodayAction`` at the weight its emphasis asks for.
struct TodayActionButton: View {
    let action: TodayAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Text(action.title)
        }
        .buttonStyle(for: action.emphasis)
        .accessibilityLabel(action.title)
    }
}

private extension View {
    @ViewBuilder
    func buttonStyle(for emphasis: ActionEmphasis) -> some View {
        switch emphasis {
        case .primary: buttonStyle(.primaryAction)
        case .secondary: buttonStyle(.secondaryAction)
        case .tertiary: buttonStyle(.tertiaryAction)
        }
    }
}
