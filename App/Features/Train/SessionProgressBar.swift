//
//  SessionProgressBar.swift
//  ChessCoach
//

import SwiftUI

/// `3 / 10` with a hairline track directly beneath it.
///
/// Quizlet's study-set model. Three decisions worth keeping:
///
/// * **The counter is the primary reading**, not the bar. `3 / 10` answers "how
///   much is left" exactly; the bar only has to answer it approximately, which
///   is why it can be a hairline.
/// * **Hairline, not a pill.** A 10pt rounded bar at the top of a board screen
///   competes with the board. Two points of track and a two-point fill sit under
///   the counter as punctuation.
/// * **No segments.** Dashed or gapped segments say "this flow has named
///   phases" — see ``SectionedProgressBar``, which uses them because calibration
///   genuinely does. A queue of ten interchangeable puzzles has no phases, and
///   segmenting it would invent a structure the user then goes looking for.
struct SessionProgressBar: View {

    let progress: SessionProgress

    /// Shown instead of the counter for a step that is not one of the numbered
    /// puzzles. The set's concept is the last thing in the session but it is not
    /// puzzle six of five, and a counter that reads `5 / 5` under a board the
    /// user is still playing says the session is over when it is not.
    var label: String?

    var body: some View {
        VStack(spacing: 5) {
            Text(label ?? progress.counterLabel)
                .typeRole(.headline, monospacedDigits: true)
                .contentTransition(.numericText())

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceSunken.dynamic)
                    Capsule()
                        .fill(Palette.accent.dynamic)
                        .frame(width: max(0, proxy.size.width * progress.fraction))
                }
            }
            .frame(width: 132, height: 2)
        }
        .animation(Motion.snappy, value: progress.fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Puzzle \(progress.counterLabel)")
    }
}

#Preview {
    SessionProgressBar(progress: SessionProgress(index: 2, completed: 2, total: 10))
}
