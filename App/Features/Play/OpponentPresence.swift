import SwiftUI

/// The opponent, given real space on the screen.
///
/// ## Why a monogram and not a character
///
/// The reference for this block is a screen that hands ~170pt of height to an
/// expressive cartoon with a speech bubble. The *space* is right and the
/// *bubble* is right; the cartoon is not. This app is a training tool for an
/// adult working towards a real rating, and the thing being built is the feeling
/// of sitting across from a strong player and being dangerous. An illustrated
/// mascot undercuts that every time it appears. A named opponent with a
/// recognisable style supports it. So the presence comes from size, from the
/// name in headline weight, and from one line of writing — the restraint is a
/// product decision, not an art budget.
///
/// ## Why the line lives in a bubble even when it is a trait
///
/// The bubble is the opponent's slot, and it is the same slot in both states.
/// If the trait were loose text and the thinking line were a bubble, the block
/// would change shape eighty times a game. Instead the container is constant,
/// two lines tall whatever it holds, and only the text inside it crossfades:
/// a third-person trait when it is not their move, a first-person line in quotes
/// while they think.
struct OpponentPresenceView: View {

    let opponent: OpponentRoster.Opponent
    let line: OpponentLine

    @State private var pulse = false

    private var isSpeaking: Bool { line.kind == .speech }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            monogram

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(opponent.name)
                        .font(.headline)
                    Text("\(opponent.rating)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                bubble
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var monogram: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.quaternary)
            .frame(width: 52, height: 52)
            .overlay {
                Text(opponent.name.prefix(1))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }

    private var bubble: some View {
        Text(displayText)
            .font(.callout)
            .foregroundStyle(isSpeaking ? .primary : .secondary)
            .contentTransition(.opacity)
            // Two lines of room, always: a long line and a short one must not
            // change the height of anything above the board.
            .lineLimit(2, reservesSpace: true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(SpeechBubbleShape().fill(.quaternary))
            .overlay(SpeechBubbleShape().stroke(Color.primary.opacity(0.09), lineWidth: 1))
            // A slow breath on the line while they think, and nothing else on
            // the screen moving. Not a spinner, not a shimmer, not a loop the
            // eye can lock on to.
            .opacity(isSpeaking && pulse ? 0.68 : 1)
            .animation(
                isSpeaking
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.2),
                value: pulse
            )
            .animation(.easeInOut(duration: 0.15), value: line.text)
            .onChange(of: isSpeaking) { _, speaking in pulse = speaking }
            .onAppear { pulse = isSpeaking }
    }

    private var displayText: String {
        isSpeaking ? "\u{201C}\(line.text)\u{201D}" : line.text
    }
}

/// A rounded rectangle with a caret on its leading edge, pointing at the
/// monogram beside it.
private struct SpeechBubbleShape: Shape {

    var caretWidth: CGFloat = 7
    var caretCentre: CGFloat = 20
    var cornerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path(
            roundedRect: CGRect(
                x: rect.minX + caretWidth,
                y: rect.minY,
                width: max(0, rect.width - caretWidth),
                height: rect.height
            ),
            cornerRadius: cornerRadius,
            style: .continuous
        )

        let centre = min(max(caretCentre, cornerRadius + caretWidth), rect.height - cornerRadius)
        var caret = Path()
        caret.move(to: CGPoint(x: rect.minX, y: centre))
        caret.addLine(to: CGPoint(x: rect.minX + caretWidth + 0.5, y: centre - caretWidth))
        caret.addLine(to: CGPoint(x: rect.minX + caretWidth + 0.5, y: centre + caretWidth))
        caret.closeSubpath()
        path.addPath(caret)

        return path
    }
}

/// Named opponents with traits instead of numbered difficulty levels.
///
/// A level integer invites grinding; a personality invites playing. The traits
/// are also the standing content of the opponent's line, so they have to read as
/// a description of a player rather than as a difficulty setting in prose.
enum OpponentRoster {
    struct Opponent: Sendable, Hashable {
        var name: String
        var trait: String
        var rating: Int
    }

    private static let roster: [Opponent] = [
        Opponent(name: "Mira", trait: "grabs material, forgets her king", rating: 850),
        Opponent(name: "Oscar", trait: "trades early, hates pressure", rating: 1050),
        Opponent(name: "Petra", trait: "solid, punishes loose pieces", rating: 1250),
        Opponent(name: "Dane", trait: "sharp openings, drifts later", rating: 1450),
        Opponent(name: "Ines", trait: "positional, squeezes endgames", rating: 1650),
        Opponent(name: "Kolya", trait: "tactical, rarely misses a shot", rating: 1900),
        Opponent(name: "Vera", trait: "no weaknesses to speak of", rating: 2150),
    ]

    static func opponent(forRating rating: Int) -> Opponent {
        let nearest = roster.min { abs($0.rating - rating) < abs($1.rating - rating) }
        var result = nearest ?? roster[1]
        result.rating = rating
        return result
    }
}

#Preview("Opponent presence") {
    VStack(alignment: .leading, spacing: 28) {
        OpponentPresenceView(
            opponent: OpponentRoster.opponent(forRating: 1050),
            line: OpponentLine(text: "trades early, hates pressure", kind: .trait)
        )
        OpponentPresenceView(
            opponent: OpponentRoster.opponent(forRating: 1050),
            line: OpponentLine(text: "So we're trading, then.", kind: .speech)
        )
    }
    .padding()
}
