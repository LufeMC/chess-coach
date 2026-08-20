//
//  TodayBoardRow.swift
//  ChessCoach
//

import BoardUI
import SwiftUI

/// Today's three steps, drawn as three squares off a chessboard.
///
/// ## Why this replaced the winding path
///
/// The path — circular nodes swaying left and right down the screen, a floating
/// START bubble over the live one, a character standing beside it — was lifted
/// from Duolingo almost line for line, and the old source comments said so.
/// Changing the colour did not change that: the silhouette is the recognisable
/// part.
///
/// But the stronger objection is that the metaphor was never true here. A path
/// works for a language course because the content is sequential and endless —
/// you never meet the same node twice, so a winding trail genuinely describes
/// the shape of the product. Rookly's three steps are the *same three steps
/// every single day*. Drawing them as a journey promises progression through
/// new ground, and the user finds out it was a lie on day two, when the trail
/// they thought they walked has reset to the start.
///
/// Three squares in a row is the honest shape: a set of things to do today,
/// finished or not, that will be here again tomorrow. It is also the shape this
/// app is actually about. Squares are what chess is played on, and a square is
/// the one silhouette a language app can never take from us.
///
/// ## Why they are not buttons first
///
/// They are tappable when startable, exactly as the nodes were — but the single
/// filled CTA at the bottom of the screen is still what names the next step.
/// The row reports; the button instructs. That division is what lets the row
/// stay quiet enough to be read at a glance.
struct TodayBoardRow: View {

    let steps: [StepRowState]
    /// Who today's game is against — drawn *inside* the game square rather than
    /// standing beside the row. The opponent is not scenery decorating a
    /// journey; they are the content of that one square.
    let opponentName: String?
    let onTap: (TodayStep) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                TodayBoardSquare(
                    state: step,
                    // The checker runs across the row the way it runs across a
                    // rank: alternating, starting light.
                    isDarkSquare: !index.isMultiple(of: 2),
                    opponentName: step.step == .game ? opponentName : nil,
                    onTap: onTap
                )
                .transition(.opacity.animation(Motion.staggered(index: index)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One square: the step's glyph, its name, and its tally.
private struct TodayBoardSquare: View {

    let state: StepRowState
    let isDarkSquare: Bool
    let opponentName: String?
    let onTap: (TodayStep) -> Void

    private var isTappable: Bool {
        state.status == .current || state.status == .available
    }

    private var shape: RoundedRectangle {
        // Softened, not circular. A square with a 14pt radius still reads as a
        // board square; a capsule or a circle does not.
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        Group {
            if isTappable {
                Button { onTap(state.step) } label: { face }
                    .buttonStyle(BoardSquareStyle(shape: shape, fill: fill, edge: edge))
            } else {
                face
                    .background(shape.fill(fill.dynamic))
                    .background(shape.fill(edge.dynamic).offset(y: EdgeDepth.control))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(state.status == .locked ? (state.lockedReason ?? "") : "")
    }

    private var face: some View {
        VStack(spacing: 10) {
            icon
                .frame(height: 46)

            VStack(spacing: 2) {
                Text(shortTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(labelTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(subtitle)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(labelTint.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .padding(.horizontal, 6)
    }

    /// The step's own name, not its status sentence.
    ///
    /// The status sentence — "No moments to review" — belongs in a checklist
    /// row where there is a full line to hold it. In a square it truncates to
    /// "No moments to re…", which manages to be both shouting and unreadable.
    /// The square says what the step *is*; its second line says where it stands.
    private var shortTitle: String {
        switch state.step {
        case .game: "Game"
        case .moments: "Moments"
        case .puzzles: "Puzzles"
        }
    }

    @ViewBuilder
    private var icon: some View {
        // On the game square the opponent's face *is* the icon. A clock beside
        // a small portrait was two symbols competing inside 44 points, and the
        // honest answer to "what is this square" is the person you are playing.
        if let opponentName, state.status != .done, state.status != .locked {
            OpponentAvatar(name: opponentName, size: 46)
        } else {
            glyph
        }
    }

    private var subtitle: String {
        if state.status == .done { return "done" }
        if state.lockedReason != nil { return "locked" }
        guard let tally = state.tally else { return "" }
        return "\(tally.value) \(tally.denominator)"
    }

    private var glyph: some View {
        Image(systemName: glyphName)
            .font(.system(size: 27, weight: .heavy))
            .foregroundStyle(glyphTint)
    }

    private var glyphName: String {
        switch state.status {
        case .done: "checkmark"
        case .locked: "lock.fill"
        default:
            switch state.step {
            // Chess glyphs where one exists: the game is a clock, because a
            // game is the thing on this list that costs real time.
            case .game: "clock.fill"
            case .moments: "magnifyingglass"
            case .puzzles: "puzzlepiece.fill"
            }
        }
    }

    // MARK: Tones

    /// Done squares go gold, live squares take the brand, and the rest sit in
    /// the two board tones — which is what makes the row read as a rank rather
    /// than as three unrelated tiles.
    private var fill: DualColor {
        switch state.status {
        case .done: Palette.gold
        case .locked: isDarkSquare ? Palette.surfaceSunken : Palette.lockedFill
        default: Palette.accent
        }
    }

    private var edge: DualColor {
        switch state.status {
        case .done: Palette.goldEdge
        case .locked: Palette.lockedEdge
        default: Palette.accentEdge
        }
    }

    private var glyphTint: Color {
        state.status == .locked
            ? DualColor(light: 0xA9A4B5, dark: 0x6B6280).dynamic
            : .white
    }

    private var labelTint: Color {
        state.status == .locked
            ? DualColor(light: 0xA9A4B5, dark: 0x6B6280).dynamic
            : .white
    }

    private var accessibilityLabel: String {
        var parts = [state.title]
        if state.status == .done {
            parts.append("done")
        } else if let reason = state.lockedReason {
            parts.append(reason)
        } else if let tally = state.tally {
            parts.append(tally.accessibilityText)
        }
        if let opponentName { parts.append("against \(opponentName)") }
        return parts.joined(separator: ", ")
    }
}

/// The square's press: the face drops onto its lip, no scaling.
///
/// Scaling a square makes it look like a photo being pinched. Dropping it onto
/// its own hard edge is the same physical story the buttons tell, and it is the
/// one piece of the old node worth keeping.
private struct BoardSquareStyle: ButtonStyle {
    let shape: RoundedRectangle
    /// Passed in rather than assumed: today only the live tones reach this
    /// style, but a style that hard-codes them silently paints the wrong colour
    /// the first time a new status becomes tappable.
    let fill: DualColor
    let edge: DualColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? EdgeDepth.control : 0)
            .background(shape.fill(fill.dynamic))
            .background(shape.fill(edge.dynamic).offset(y: EdgeDepth.control))
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
