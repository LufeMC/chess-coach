import SwiftUI

/// The status row: one pill, three segments.
///
/// ## Why one container and not three capsules
///
/// Separate floating capsules with gaps between them read as three unresolved
/// decisions. A single container with 1pt internal rules reads as one designed
/// object, which is what every shipped app in this shape does. The segments are
/// ordered position → their clock → your clock, so the number that describes the
/// game comes first and the clock you are burning sits nearest your thumb.
///
/// ## Why nothing moves when the turn changes
///
/// Over a 40-move game the turn changes eighty times. Anything that resizes,
/// recolours or slides on that boundary is eighty pieces of motion the user did
/// not ask for. So the active side is signalled by *contrast only* — full
/// foreground versus secondary, a filled clock glyph versus an outline one —
/// crossfaded over 0.2s, and every glyph keeps its position and its weight. The
/// widest string the clock can ever print is reserved up front so `10:00`
/// becoming `9:59` does not shift the segment either.
struct PlayStatusPill: View {

    struct ClockState {
        /// Time charged as of the start of the current move.
        var chargedMs: Int
        var startedAt: Date
        var isRunning: Bool
        var isActive: Bool
        var widthSample: String
        var accessibilityName: String
    }

    let eval: PlayEvalReading
    let opponentClock: ClockState
    let userClock: ClockState
    /// True once the game is over: the clocks stop meaning anything and drop
    /// back, while the eval — the final material count — stays legible.
    var clocksDimmed: Bool = false

    private let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            EvalSegment(reading: eval)
                .frame(maxHeight: .infinity)

            rule

            ClockSegment(state: opponentClock)
                .frame(maxHeight: .infinity)
                .opacity(clocksDimmed ? 0.4 : 1)

            rule

            ClockSegment(state: userClock)
                .frame(maxHeight: .infinity)
                .opacity(clocksDimmed ? 0.4 : 1)
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
        )
        .overlay(
            // Hairline, never a shadow: shadows on small chrome are the most
            // reliable tell of a mid-tier app.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: clocksDimmed)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Eval segment

/// Arrow, then a number, both in the semantic colour at full strength.
///
/// The arrow is not decoration: colour alone would leave the reading invisible
/// to a red/green colourblind player, and this is the one number on the screen
/// that has to be readable in a glance.
private struct EvalSegment: View {
    let reading: PlayEvalReading

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reading.symbolName)
                .font(.system(size: 10, weight: .bold))
            Text(reading.text)
                .font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit())
                .tracking(0.6)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: reading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(reading.accessibilityText))
    }

    private var tint: Color {
        switch reading.direction {
        case .ahead: .green
        // Red here and nowhere else on this screen: it means "advantage lost",
        // full stop. Time pressure goes amber instead.
        case .behind: .red
        case .level: .secondary
        }
    }
}

// MARK: - Clock segment

private struct ClockSegment: View {
    let state: PlayStatusPill.ClockState

    var body: some View {
        // Scoped to this segment so a ticking clock redraws a 70pt view rather
        // than the board.
        TimelineView(.periodic(from: state.startedAt, by: tickInterval)) { context in
            content(reading: PlayClock.reading(milliseconds: milliseconds(at: context.date)))
        }
    }

    private func content(reading: ClockReading) -> some View {
        HStack(spacing: 5) {
            ZStack {
                // Both glyphs are drawn and crossfaded: swapping the symbol name
                // outright pops, and the filled and outline variants have
                // different optical widths.
                Image(systemName: "clock.fill").opacity(state.isActive ? 1 : 0)
                Image(systemName: "clock").opacity(state.isActive ? 0 : 1)
            }
            .font(.system(size: 11, weight: .semibold))

            Text(state.widthSample)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(reading.text)
                }
                .font(.system(size: 15, weight: weight(for: reading.pressure), design: .rounded).monospacedDigit())
        }
        .foregroundStyle(foreground(for: reading.pressure))
        .padding(.horizontal, 11)
        .animation(.easeInOut(duration: 0.2), value: state.isActive)
        .animation(.easeInOut(duration: 0.2), value: reading.pressure)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(state.accessibilityName): \(reading.accessibilityText)"))
    }

    private func milliseconds(at date: Date) -> Int {
        PlayClock.remainingMs(
            chargedMs: state.chargedMs,
            startedAt: state.startedAt,
            now: date,
            isRunning: state.isRunning
        )
    }

    /// A stopped clock does not need a heartbeat; a clock near the flag needs a
    /// tenth-of-a-second one. Everything in between ticks twice a second, which
    /// is enough for a display that only prints whole seconds.
    private var tickInterval: TimeInterval {
        guard state.isRunning else { return 3600 }
        return state.chargedMs <= 40_000 ? 0.1 : 0.5
    }

    private func weight(for pressure: ClockPressure) -> Font.Weight {
        switch pressure {
        case .none: .medium
        case .low: .semibold
        case .critical: .heavy
        }
    }

    private func foreground(for pressure: ClockPressure) -> Color {
        // Amber, never red. Red is spoken for by the eval segment two inches to
        // the left, and a colour that means two things means neither.
        if pressure == .critical { return .orange }
        return state.isActive ? .primary : .secondary
    }
}

#Preview("Status pill") {
    VStack(spacing: 16) {
        PlayStatusPill(
            eval: .material(3),
            opponentClock: .init(
                chargedMs: 600_000,
                startedAt: .now,
                isRunning: false,
                isActive: false,
                widthSample: PlayClock.widthSample(baseSeconds: 600),
                accessibilityName: "Opponent clock"
            ),
            userClock: .init(
                chargedMs: 8_400,
                startedAt: .now,
                isRunning: true,
                isActive: true,
                widthSample: PlayClock.widthSample(baseSeconds: 600),
                accessibilityName: "Your clock"
            )
        )
        PlayStatusPill(
            eval: .material(0),
            opponentClock: .init(
                chargedMs: 42_000,
                startedAt: .now,
                isRunning: true,
                isActive: true,
                widthSample: PlayClock.widthSample(baseSeconds: 600),
                accessibilityName: "Opponent clock"
            ),
            userClock: .init(
                chargedMs: 121_000,
                startedAt: .now,
                isRunning: false,
                isActive: false,
                widthSample: PlayClock.widthSample(baseSeconds: 600),
                accessibilityName: "Your clock"
            )
        )
        PlayStatusPill(
            eval: .material(-2),
            opponentClock: .init(
                chargedMs: 25_000,
                startedAt: .now,
                isRunning: false,
                isActive: false,
                widthSample: PlayClock.widthSample(baseSeconds: 600),
                accessibilityName: "Opponent clock"
            ),
            userClock: .init(
                chargedMs: 310_000,
                startedAt: .now,
                isRunning: true,
                isActive: true,
                widthSample: PlayClock.widthSample(baseSeconds: 600),
                accessibilityName: "Your clock"
            ),
            clocksDimmed: true
        )
    }
    .padding()
}
