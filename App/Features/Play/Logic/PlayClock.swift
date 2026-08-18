import Foundation

/// The clock's pure layer: what a remaining time reads as, and how much trouble
/// it means.
///
/// Split out of the view because both halves are easy to get subtly wrong and
/// impossible to eyeball: a countdown that floors instead of rounding shows
/// `0:00` for a whole second before the flag, and a threshold that fires on `<`
/// instead of `<=` never warns a player whose clock lands exactly on ten.

/// How much time pressure a clock is under.
///
/// Three tiers, and **none of them is red**. Red means "advantage lost" in the
/// eval segment, and a colour that means two things means neither — so time
/// pressure escalates through weight first and amber second, which is what
/// `Docs/craft-standards.md` asks for.
enum ClockPressure: Int, Comparable, Sendable {
    /// Plenty of time.
    case none
    /// Under 30s: the numerals get heavier, nothing else changes.
    case low
    /// Under 10s: amber, heaviest weight, and tenths of a second.
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One clock, formatted.
struct ClockReading: Equatable, Sendable {
    var text: String
    var pressure: ClockPressure
    /// True once the display has switched to `S.t`, which is also the point at
    /// which the display needs to tick faster than once a second.
    var showsTenths: Bool
    var accessibilityText: String
}

enum PlayClock {

    /// Numerals get heavier here.
    static let lowThresholdMs = 30_000
    /// Amber, tenths, and one soft haptic on the way past.
    static let criticalThresholdMs = 10_000

    /// Remaining time including the move currently being thought about.
    ///
    /// `GameSession` charges a move's time when the move *completes*, so a view
    /// that reads `userClockMs` directly draws a frozen clock — the one thing
    /// this screen cannot afford, because the running clock is what stands in
    /// for the "opponent is thinking" spinner we refuse to draw.
    static func remainingMs(chargedMs: Int, startedAt: Date, now: Date, isRunning: Bool) -> Int {
        guard isRunning else { return max(0, chargedMs) }
        let elapsedMs = Int(now.timeIntervalSince(startedAt) * 1000)
        return max(0, chargedMs - max(0, elapsedMs))
    }

    static func pressure(milliseconds: Int) -> ClockPressure {
        let clamped = max(0, milliseconds)
        if clamped <= criticalThresholdMs { return .critical }
        if clamped <= lowThresholdMs { return .low }
        return .none
    }

    static func reading(milliseconds: Int) -> ClockReading {
        let clamped = max(0, milliseconds)
        let pressure = pressure(milliseconds: clamped)
        let totalSeconds = clamped / 1000

        if pressure == .critical {
            // Tenths under ten seconds is the one place a chess clock earns a
            // faster tick: at this point the number is the game.
            let tenths = (clamped % 1000) / 100
            return ClockReading(
                text: "\(totalSeconds).\(tenths)",
                pressure: pressure,
                showsTenths: true,
                accessibilityText: "\(totalSeconds) point \(tenths) seconds remaining"
            )
        }

        return ClockReading(
            text: String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60),
            pressure: pressure,
            showsTenths: false,
            accessibilityText: "\(spokenTime(totalSeconds)) remaining"
        )
    }

    /// True exactly once as a clock falls past ten seconds — the single soft
    /// haptic the budget in `Docs/craft-standards.md` allows for time trouble.
    static func crossedCritical(previousMs: Int, currentMs: Int) -> Bool {
        previousMs > criticalThresholdMs && currentMs <= criticalThresholdMs
    }

    /// The widest string this clock can ever show, used to reserve width.
    ///
    /// Monospaced digits stop `1` and `8` from having different widths; they do
    /// nothing about `10:00` becoming `9:59`, which drops a whole glyph and
    /// shifts everything beside it. The segment reserves the wide string and
    /// draws the real one trailing-aligned inside it, so the layout is fixed for
    /// the whole game.
    static func widthSample(baseSeconds: Int) -> String {
        // One minute of headroom covers increments pushing the clock above its
        // starting time.
        let minutes = max(1, baseSeconds / 60 + 1)
        return String(repeating: "0", count: String(minutes).count) + ":00"
    }

    private static func spokenTime(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        return parts.joined(separator: " ")
    }
}
