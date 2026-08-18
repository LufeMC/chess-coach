//
//  Motion.swift
//  ChessCoach
//
//  Design system — Motion.
//

import SwiftUI

/// The app's entire motion vocabulary: three springs and three durations.
///
/// ## Why a namespace rather than `extension Animation`
///
/// SwiftUI already ships `Animation.snappy`, `.smooth` and `.bouncy` with its
/// own tuning. Adding a same-named static member in an extension does not
/// replace them — it makes every call site ambiguous, and worse, a call that
/// *does* resolve might silently pick Apple's curve instead of ours. `Motion.`
/// is one extra token and it is greppable, which is what makes a shared
/// vocabulary auditable: `rg 'withAnimation\(' | rg -v Motion` finds every
/// screen that invented its own curve.
///
/// The rule these encode, from the craft standards: *motion communicates where
/// something came from or what changed*. A card that fades in from nowhere
/// teaches nothing, so none of these are offered as a bare fade.
enum Motion {

    // MARK: Springs

    /// Selection, toggles, button press states. Fast enough to feel like a
    /// direct consequence of the finger.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// Sheets, transitions, card entry. The default for anything that arrives.
    static let standard = Animation.spring(response: 0.42, dampingFraction: 0.82)

    /// Large-surface moves and board reflow. Slower because the eye has further
    /// to travel, and a big surface moving at `snappy` reads as a glitch.
    static let gentle = Animation.spring(response: 0.60, dampingFraction: 0.90)

    // MARK: Non-spring durations

    /// Opacity-only crossfades. Springs overshoot, which is meaningless for
    /// alpha, so these three are eased.
    static let crossfade = Animation.easeInOut(duration: crossfadeDuration)

    /// Colour and border changes.
    static let colorShift = Animation.easeInOut(duration: colorShiftDuration)

    /// Replacing the content of a container that keeps its frame.
    static let contentSwap = Animation.easeInOut(duration: contentSwapDuration)

    static let crossfadeDuration: Double = 0.15
    static let colorShiftDuration: Double = 0.25
    static let contentSwapDuration: Double = 0.35

    // MARK: Stagger

    /// Rows past this index all share the last delay.
    ///
    /// Uncapped stagger means the eighth row of a list arrives a third of a
    /// second after the first, and the twentieth arrives after the user has
    /// already started scrolling. The cap keeps the effect as texture rather
    /// than a queue the user waits in.
    static let staggerCap = 6

    /// Seconds added per row.
    static let staggerStep: Double = 0.040

    /// The delay for a given row index, capped at ``staggerCap`` rows.
    ///
    /// Exposed separately from ``staggered(index:)`` so tests can assert the
    /// curve without reaching into an opaque `Animation`.
    static func staggerDelay(index: Int) -> Double {
        Double(min(max(index, 0), staggerCap)) * staggerStep
    }

    /// ``standard``, delayed by 40ms per row and capped at six rows.
    ///
    /// Skip this entirely on re-entry to a screen the user has already seen —
    /// a stagger is an explanation of where content came from, and repeating
    /// the explanation on every tab switch is just latency.
    static func staggered(index: Int, base: Animation = Motion.standard) -> Animation {
        base.delay(staggerDelay(index: index))
    }
}
