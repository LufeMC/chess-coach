import SwiftUI

/// The opponent, given real space on the screen.
///
/// ## Why space, and not a character
///
/// Giving the opponent real height on the screen is right; giving it to an
/// expressive cartoon is not. This app is a training tool for an adult working
/// towards a real rating, and the thing being built is the feeling of sitting
/// across from a strong player and being dangerous. A mascot undercuts that
/// every time it appears. A named opponent with a recognisable style supports
/// it. So the presence comes from size, from the name in headline weight, and
/// from one line of writing.
///
/// ## Why the line lives in a constant slot
///
/// It is the same slot in both states. If the trait were loose text and the
/// thinking line got its own container, the block would change shape eighty
/// times a game and take the board with it. Instead the slot is constant, two
/// lines tall whatever it holds, and only the text inside it crossfades: a
/// third-person trait when it is not their move, a first-person line in quotes
/// while they think. The rule beside it is the only thing that changes colour,
/// and it is doing the job the old caret did — marking whose voice this is —
/// without drawing a cartoon tail to do it.
struct OpponentPresenceView: View {

    let opponent: OpponentRoster.Opponent
    let line: OpponentLine

    @State private var pulse = false

    private var isSpeaking: Bool { line.kind == .speech }
    /// The coach's verdict shares the slot but not the voice: no quotes, no
    /// breathing, and the standing text weight rather than the opponent's.
    private var isCoach: Bool { line.kind == .coach }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            monogram

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(opponent.name)
                        .typeRole(.headline)
                    // Verbatim: a rating is an identifier, not a quantity, and
                    // localised grouping would print "1,150".
                    Text(verbatim: "\(opponent.rating)")
                        .typeRole(.caption, monospacedDigits: true)
                }

                bubble
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var monogram: some View {
        OpponentAvatar(name: opponent.name, size: 56)
    }

    private var bubble: some View {
        ZStack(alignment: .leading) {
            // A two-line box, always, with the line centred in it. Reserving the
            // space is what stops the block — and therefore the board — from
            // moving when a short line replaces a long one; centring is what
            // stops the reserved space from reading as a hole.
            Text(verbatim: "A\nA")
                .typeRole(.body)
                .lineSpacing(2)
                .hidden()
                .accessibilityHidden(true)

            Text(displayText)
                .typeRole(.body, appliesForeground: false)
                .foregroundStyle(isSpeaking || isCoach ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentTransition(.opacity)
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        // An annotator's pull-quote, not a speech bubble.
        //
        // This was a rounded box with a caret aimed at a circular portrait —
        // the cartoon-character-talks-to-you block, and the second most
        // recognisable borrowed component in the app. A leading rule with the
        // line set beside it says the same thing in chess's own register:
        // annotation is how commentary has been attached to a game for two
        // hundred years, and it needs no fill, no border and no tail.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(isSpeaking || isCoach ? Palette.accent.dynamic : Palette.hairline.dynamic)
                .frame(width: 3)
                .animation(Motion.crossfade, value: line.kind == .trait)
        }
        // A slow breath on the line while they think, and nothing else on the
        // screen moving. Not a spinner, not a shimmer, not a loop the eye can
        // lock on to.
        .opacity(isSpeaking && pulse ? 0.68 : 1)
        .animation(
            isSpeaking
                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                : Motion.crossfade,
            value: pulse
        )
        .animation(Motion.crossfade, value: line.text)
        .onChange(of: isSpeaking) { _, speaking in pulse = speaking }
        .onAppear { pulse = isSpeaking }
    }

    private var displayText: String {
        // Quotes are the marker for "these are their words". The coach's verdict
        // is the app's own voice and takes none.
        isSpeaking ? "\u{201C}\(line.text)\u{201D}" : line.text
    }
}

/// The opponent's face: a generated character portrait on a bordered square,
/// with the monogram kept as the fallback for a name that has no artwork.
///
/// The portrait earns its place because the opponent is a *someone* — their
/// face is what the player recognises across the Today row, the Play screen and
/// the game summary, and a rating alone recognises nobody.
///
/// ## Why a square and not a circle
///
/// It was a circle, and a circle-cropped illustrated character is the mascot
/// convention this app spent a redesign getting out from under. The square is
/// the unit chess is played on, it matches the day's step tiles it now sits
/// inside, and it reads as the photograph on a tournament name card rather than
/// as a cartoon avatar — which is exactly the register these opponents are
/// written in.
struct OpponentAvatar: View {
    let name: String
    var size: CGFloat = 56

    private var assetName: String { "opponent-\(name.lowercased())" }

    /// Softened in proportion, so a 30pt portrait in a step tile and a 88pt one
    /// on the Play screen read as the same shape rather than as two decisions.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    }

    var body: some View {
        Group {
            #if canImport(UIKit)
                if UIImage(named: assetName) != nil {
                    Image(assetName)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    initial
                }
            #else
                initial
            #endif
        }
        .frame(width: size, height: size)
        .background(shape.fill(Palette.surfaceSunken.dynamic))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline.dynamic, lineWidth: 2))
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(name.prefix(1))
            .font(.system(.title2, design: .rounded, weight: .bold))
            .foregroundStyle(.secondary)
    }
}

/// Named opponents with traits instead of numbered difficulty levels.
///
/// A level integer invites grinding; a personality invites playing. The traits
/// are also the standing content of the opponent's line, so they have to read as
/// a description of a player rather than as a difficulty setting in prose.
///
/// ## Why every trait is about horizon and error rate
///
/// Because that is all `Humanizer` implements, and the trait is the only
/// scouting the user gets. These lines used to describe playing *styles* —
/// material greed, king neglect, early trades, sharp openings, endgame squeezes
/// — and not one of them was true: the profiles differ only in search depth,
/// softmax temperature, blunder probability, opening randomness and MultiPV
/// width. A 1200 who prepared to punish Mira's king or to avoid Oscar's trades
/// was preparing against a player who did not exist, and the post-game review
/// could never corroborate the claim, because there was nothing there to find.
///
/// Depth is the one lever with a plain-English translation, and `Humanizer`'s
/// own argument for it supplies the wording: a weak player misses a three-move
/// tactic because they did not look three moves ahead. So each line names the
/// horizon the profile is capped at and what its blunder rate means for the
/// person on the other side — both properties the model actually has, both
/// things the user can act on, and both visible in the game afterwards.
enum OpponentRoster {
    struct Opponent: Sendable, Hashable {
        var name: String
        var trait: String
        var rating: Int
    }

    private static let roster: [Opponent] = [
        Opponent(name: "Mira", trait: "looks two moves ahead; hands you something most games", rating: 850),
        Opponent(name: "Oscar", trait: "looks three moves ahead; still misses short tactics", rating: 1050),
        Opponent(name: "Petra", trait: "four moves ahead; the free pieces are mostly gone", rating: 1250),
        Opponent(name: "Dane", trait: "finds the short tactics; the long ones get past him", rating: 1450),
        Opponent(name: "Ines", trait: "five moves ahead, and seldom in a hurry", rating: 1650),
        Opponent(name: "Kolya", trait: "six moves ahead; almost nothing is free", rating: 1900),
        Opponent(name: "Vera", trait: "calculates past your horizon; leave nothing loose", rating: 2150),
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
            line: OpponentLine(text: "looks three moves ahead; still misses short tactics", kind: .trait)
        )
        OpponentPresenceView(
            opponent: OpponentRoster.opponent(forRating: 1050),
            line: OpponentLine(text: "So we're trading, then.", kind: .speech)
        )
    }
    .padding()
}
