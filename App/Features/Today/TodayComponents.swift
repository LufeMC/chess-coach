//
//  TodayComponents.swift
//  ChessCoach
//

import BoardUI
import SwiftUI

// MARK: - Rung banner

/// The section banner: rung, weekly focus, and required-skill progress on a
/// solid violet card with a hard bottom lip, and the app's signature checker
/// fading out of its top-right corner.
///
/// This is the loudest surface on the home screen, which makes it the one place
/// the identity has to be unambiguous — see ``CheckerMotif`` for why a coloured
/// slab alone was not enough.
struct RungCard: View {
    let rung: RungPresentation
    /// True while the progress figure is still being computed. Shows a skeleton
    /// in the bar's exact geometry rather than an empty bar, which would be a
    /// claim of zero progress.
    let isMeasuring: Bool

    private let barHeight: CGFloat = 8

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // `Rung 2 of 4`, not `Rung 2`. The ladder's length is what turns a
            // label into a position, and this card is the first place in the
            // app most users meet the word at all.
            Text("Rung \(rung.rung) of \(rung.rungCount)")
                .typeRole(.label, appliesForeground: false)
                .foregroundStyle(.white.opacity(0.85))

            Text(rung.title)
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(.white)

            // Its own line rather than pinned opposite the eyebrow: the habit
            // is a sentence, and a sentence squeezed into the gap left by a
            // label truncates at the word that carried it.
            if let focusHabit = rung.focusHabit {
                FocusChip(text: focusHabit)
            }

            progressArea
        }
        .padding(16)
        // Motif first, fill second: successive `.background`s stack behind one
        // another, so the checker lands between the violet and the text.
        .checkerMotif(cornerRadius: CornerRadius.card)
        .background(shape.fill(Palette.accent.dynamic))
        .background(shape.fill(Palette.accentEdge.dynamic).offset(y: EdgeDepth.card))
        .contentShape(shape)
    }

    @ViewBuilder
    private var progressArea: some View {
        if let skills = rung.skills {
            VStack(alignment: .leading, spacing: 5) {
                ProgressTrack(progress: skills.fraction)
                    .frame(height: barHeight)
                // A bar with no unit is a claim the reader has to guess at.
                // This one is the fraction of the rung's required skills that
                // are met, and finishing it is what moves you up a rung.
                //
                // Counted rather than given as a percentage: see
                // ``RungSkillProgress`` for why a bar that moves in thirds must
                // not be labelled as if it moved in points.
                Text("\(RungPresentation.progressCaption) · \(skills.caption)")
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RungPresentation.progressCaption)
            .accessibilityValue(skills.caption)
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
                        .white.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                    )
                    .frame(width: 44, height: barHeight)
                Text(rung.unmeasuredNote)
                    .typeRole(.caption, appliesForeground: false)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

/// White-on-green progress, like the banner it lives on.
private struct ProgressTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.30))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

/// This week's habit, framed as what it is.
///
/// The framing is drawn, not just spoken: an imperative sentence floating in a
/// white pill on the rung card could be a tip, a badge or a task, and the word
/// in front of it is the only thing that says which.
private struct FocusChip: View {
    let text: String

    var body: some View {
        Text("Focus · \(text)")
            .typeRole(.caption, appliesForeground: false)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.22)))
            .accessibilityLabel("This week's focus: \(text)")
    }
}

// MARK: - Streak strip

/// Seven day marks, and — once there is one — the streak count behind a flame.
///
/// The count stays honest: it appears only from day one, and a missed day is a
/// plain grey circle, never a red X.
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
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Palette.streakFlame.dynamic)
                    DenominatorText(streak, role: .headline)
                }
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(streak.accessibilityText) streak")
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

    private let size: CGFloat = 20

    var body: some View {
        Group {
            switch marker {
            case .done:
                Circle()
                    .fill(Palette.gold.dynamic)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
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
                        Palette.gold.dynamic,
                        style: todayStarted
                            ? StrokeStyle(lineWidth: 3)
                            : StrokeStyle(lineWidth: 3, dash: [3, 3])
                    )

            case .tomorrow, .upcoming:
                // Dashed, so "not yet" cannot be mistaken for "missed".
                Circle()
                    .strokeBorder(
                        Palette.hairlinePending.dynamic
                            .opacity(marker == .tomorrow ? 1 : 0.6),
                        style: StrokeStyle(lineWidth: 2, dash: [3, 3])
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - The path

/// The daily loop drawn as a winding path of chunky nodes — game, moments,
/// puzzles — with the day's opponent standing beside the first one.
///
/// Nodes are buttons where the step is startable and plain status where it is
/// not; the CTA at the bottom of the screen still names the one step the loop
/// wants next, so the path never has to shout.
struct TodayPathView: View {
    let steps: [StepRowState]
    /// Who today's game is against. Drawn beside the game node so the path has
    /// a face on it, exactly like the reference.
    let opponentName: String?
    let onTap: (TodayStep) -> Void

    /// The winding: how far each node strays from the centre line.
    private let sway: [CGFloat] = [0, -64, 52]

    var body: some View {
        VStack(spacing: 26) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                ZStack {
                    PathNodeView(state: step, onTap: onTap)
                        .offset(x: sway[index % sway.count])

                    if index == 0, let opponentName {
                        HStack {
                            Spacer()
                            OpponentAvatar(name: opponentName, size: 88)
                                .padding(.trailing, 28)
                        }
                        .accessibilityHidden(true)
                    }
                }
                .transition(.opacity.animation(Motion.staggered(index: index)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

/// One path node: a fat 3D disc with the step's glyph, its label underneath,
/// and a floating START bubble when it is the step the loop points at.
private struct PathNodeView: View {
    let state: StepRowState
    let onTap: (TodayStep) -> Void

    private var isTappable: Bool {
        state.status == .current || state.status == .available
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                node
                    // Room for the ring around the current node to breathe.
                    .padding(.top, 14)

                if state.status == .current {
                    StartBubble()
                        .offset(y: -22)
                }
            }

            VStack(spacing: 2) {
                Text(state.title)
                    .typeRole(.headline, appliesForeground: false)
                    .foregroundStyle(state.status.isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))

                if let note = state.note {
                    Text(note)
                        .typeRole(.caption)
                } else if let tally = state.tally, state.status != .done {
                    Text(tally.accessibilityText)
                        .typeRole(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(state.status.isDimmed ? (state.note ?? "") : "")
    }

    @ViewBuilder
    private var node: some View {
        if isTappable {
            Button {
                onTap(state.step)
            } label: {
                glyph
            }
            .buttonStyle(
                PathNodeStyle(
                    fill: Palette.accent,
                    edge: Palette.accentEdge,
                    ringed: state.status == .current
                )
            )
        } else {
            NodeDisc(
                fill: state.status == .done ? Palette.gold : Palette.lockedFill,
                edge: state.status == .done ? Palette.goldEdge : Palette.lockedEdge,
                depressed: false
            ) {
                glyph
            }
        }
    }

    private var glyph: some View {
        Image(systemName: glyphName)
            .font(.system(size: 26, weight: .heavy))
            .foregroundStyle(glyphTint)
    }

    private var glyphName: String {
        switch state.status {
        case .done: "checkmark"
        case .locked: "lock.fill"
        case .waiting: "hourglass"
        case .empty: "minus"
        default:
            switch state.step {
            case .game: "star.fill"
            case .moments: "book.fill"
            case .puzzles: "puzzlepiece.fill"
            }
        }
    }

    private var glyphTint: Color {
        state.status.isDimmed
            ? DualColor(light: 0xAFAFAF, dark: 0x52656D).dynamic
            : .white
    }
}

/// The disc itself: face, hard lip, optional depress — one construction shared
/// by the tappable and static nodes so they cannot drift apart.
private struct NodeDisc<Content: View>: View {
    let fill: DualColor
    let edge: DualColor
    let depressed: Bool
    @ViewBuilder var content: Content

    static var diameter: CGFloat { 74 }

    var body: some View {
        content
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Circle().fill(fill.dynamic))
            // A soft top-light, which is what makes the disc read as a
            // pressable clay button rather than a flat badge.
            .overlay(
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: Self.diameter * 0.72, height: Self.diameter * 0.34)
                    .blur(radius: 4)
                    .offset(y: -Self.diameter * 0.26)
                    .allowsHitTesting(false)
            )
            .offset(y: depressed ? EdgeDepth.control : 0)
            .background(Circle().fill(edge.dynamic).offset(y: EdgeDepth.control))
            .animation(Motion.snappy, value: depressed)
    }
}

/// The chunky press for a path node, plus the ring that singles out the
/// current one.
private struct PathNodeStyle: ButtonStyle {
    let fill: DualColor
    let edge: DualColor
    let ringed: Bool

    func makeBody(configuration: Configuration) -> some View {
        NodeDisc(fill: fill, edge: edge, depressed: configuration.isPressed) {
            configuration.label
        }
        .padding(6)
        .overlay {
            if ringed {
                Circle()
                    .strokeBorder(fill.dynamic.opacity(0.35), lineWidth: 5)
            }
        }
    }
}

/// The floating "START" callout over the current node.
private struct StartBubble: View {
    @State private var bounce = false

    var body: some View {
        VStack(spacing: -1) {
            Text("Start")
                .font(.system(.footnote, design: .rounded, weight: .heavy))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Palette.accent.dynamic)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                        .fill(Palette.surfaceRaised.dynamic)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous)
                        .strokeBorder(Palette.hairline.dynamic, lineWidth: 2)
                )

            Triangle()
                .fill(Palette.surfaceRaised.dynamic)
                .frame(width: 12, height: 7)
                .overlay(Triangle().stroke(Palette.hairline.dynamic, lineWidth: 2))
                .clipShape(Triangle())
        }
        .offset(y: bounce ? -3 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bounce)
        .onAppear { bounce = true }
        .accessibilityHidden(true)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
            return path
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
