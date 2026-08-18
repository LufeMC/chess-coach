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
/// crossfaded over ``Motion/colorShift``, and every glyph keeps its position.
/// The widest string the clock can ever print is reserved up front so `10:00`
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
        .frame(height: 36)
        // Level 1: solid fill and a hairline. Never a shadow — on chrome this
        // small a shadow is the clearest tell there is.
        .elevation(.raised, cornerRadius: CornerRadius.chip)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous))
        .animation(Motion.colorShift, value: clocksDimmed)
    }

    private var rule: some View {
        Rectangle()
            .fill(Palette.hairline.dynamic)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Eval segment

/// Arrow, then a number, both in the semantic colour at full strength.
///
/// The arrow is not decoration: colour alone would leave the reading invisible
/// to a red/green colourblind player, and this is the one number on the screen
/// that has to be readable in a glance. Weight is heavier than the surrounding
/// chrome on purpose — a timid eval reads as a footnote, and this is the
/// highest-value number the screen shows.
private struct EvalSegment: View {
    let reading: PlayEvalReading

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reading.symbolName)
                .font(.caption2.weight(.bold))
            Text(reading.text)
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .fontWeight(.heavy)
                .tracking(0.6)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 11)
        .contentTransition(.opacity)
        .animation(Motion.crossfade, value: reading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(reading.accessibilityText))
    }

    private var tint: Color {
        switch reading.direction {
        case .ahead: Palette.evalPositive.dynamic
        // Red here and nowhere else on this screen: it means "advantage lost",
        // full stop. Time pressure goes through amber instead.
        case .behind: Palette.evalNegative.dynamic
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
            .font(.caption2.weight(.semibold))

            Text(state.widthSample)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(reading.text)
                }
                .typeRole(.caption, monospacedDigits: true, appliesForeground: false)
                .fontWeight(weight(for: reading.pressure))
        }
        .foregroundStyle(foreground(for: reading.pressure))
        .padding(.horizontal, 11)
        .animation(Motion.colorShift, value: state.isActive)
        .animation(Motion.colorShift, value: reading.pressure)
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
        if pressure == .critical { return Palette.caution.dynamic }
        return state.isActive ? .primary : .secondary
    }
}

#Preview("Status pill") {
    let sample = PlayClock.widthSample(baseSeconds: 600)

    return VStack(spacing: 16) {
        PlayStatusPill(
            eval: .material(3),
            opponentClock: .init(
                chargedMs: 600_000,
                startedAt: .now,
                isRunning: false,
                isActive: false,
                widthSample: sample,
                accessibilityName: "Their clock"
            ),
            userClock: .init(
                chargedMs: 8_400,
                startedAt: .now,
                isRunning: true,
                isActive: true,
                widthSample: sample,
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
                widthSample: sample,
                accessibilityName: "Their clock"
            ),
            userClock: .init(
                chargedMs: 121_000,
                startedAt: .now,
                isRunning: false,
                isActive: false,
                widthSample: sample,
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
                widthSample: sample,
                accessibilityName: "Their clock"
            ),
            userClock: .init(
                chargedMs: 310_000,
                startedAt: .now,
                isRunning: false,
                isActive: false,
                widthSample: sample,
                accessibilityName: "Your clock"
            ),
            clocksDimmed: true
        )
    }
    .padding()
}
