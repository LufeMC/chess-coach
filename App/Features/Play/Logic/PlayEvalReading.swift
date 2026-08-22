import ChessKit
import Foundation

/// The eval segment's pure layer.
///
/// ## Why this shows material and not the engine's win percentage
///
/// `GameSession.currentEvaluation` exists and is a perfectly good number, but it
/// is the *engine's* judgement, and its own doc comment says it is meant to be
/// shown after the game unless guided mode is on. Putting it on screen during a
/// sparring game does three things this app has deliberately built machinery to
/// avoid:
///
/// 1. It answers the question second-try exists to make the user ask. A bar that
///    drops the instant a blunder lands means the coach never gets to interrupt
///    with "take another look" — the screen already said so.
/// 2. It updates only after the opponent replies (it is read off the opponent's
///    search), so during the user's own move it is stale by one ply. A number
///    that moves only when the *opponent* moves reads as though the opponent
///    caused every evaluation swing.
/// 3. It teaches dependence on a readout that will not be there in a real game.
///
/// Material is the opposite on all three counts: it is derived from the board
/// the user is already looking at, it is exact, it changes only on captures, and
/// counting it is a habit worth building at the rating this app targets. It
/// makes something invisible continuously visible — the pedagogical point —
/// without leaking anything the user could not have worked out themselves.
///
/// Guided mode is the exception the session already carves out, and
/// ``winPercent(_:)`` renders the engine number as a coarse bucket for it.
///
/// ## Why the pill only carries the engine reading
///
/// All of the above is why material belongs on screen; none of it argues that
/// it belongs *twice*. `CapturedTray` already prints the same signed number
/// under the player who is ahead, beside the pieces that explain it, which is
/// the better of the two places for it — the working is next to the answer. So
/// the status pill's first segment is the guided-only engine reading and the
/// tray carries material. ``material(_:)`` stays because the balance it renders
/// is still the honest reading of the board, and the tray is one refactor away
/// from wanting it.
///
/// ## Why the engine reading is a word and not a number
///
/// Because a number would claim more than its source can support. That reading
/// is rank one of the *opponent's* search — depth-capped to model a player of
/// its own rating, sampled at MultiPV width, and run on the position before its
/// own move, so it is one ply behind the board the user is looking at and it
/// changes only when the opponent moves. `↑ +12%` states two significant
/// figures of a 1200-strength opinion in the same typography as an exact
/// material count, and the reader has no way to tell which they are holding.
///
/// `BETTER` / `EVEN` / `WORSE` is everything that source can honestly carry: the
/// direction survives being one ply stale far better than the magnitude does,
/// and it is the vocabulary a club player would use out loud anyway. The
/// magnitude is not thrown away — it decides whether the segment is coloured at
/// all, and the spoken label says it in full, framed as the estimate it is.
struct PlayEvalReading: Equatable, Sendable {

    /// Which way the position leans, from the user's side. Drawn as an arrow so
    /// the reading survives colour blindness — colour never carries it alone.
    enum Direction: Sendable {
        case ahead, level, behind
    }

    /// How far it leans. Only used for the spoken label and for deciding whether
    /// the segment is coloured at all.
    enum Magnitude: Sendable {
        case level, slight, clear, decisive
    }

    var direction: Direction
    var magnitude: Magnitude
    /// `+3`, `−2` (a real minus sign, not a hyphen), `EVEN`, or — for the engine
    /// reading — one of `BETTER` / `EVEN` / `WORSE`.
    var text: String
    var symbolName: String
    var accessibilityText: String

    // MARK: - Sources

    /// Signed material from the user's perspective, in pawns.
    static func material(_ balance: Int) -> PlayEvalReading {
        let magnitude: Magnitude =
            switch abs(balance) {
            case 0: .level
            case 1...2: .slight
            case 3...5: .clear
            default: .decisive
            }
        return make(
            signedValue: balance,
            magnitude: magnitude,
            spoken: spokenMaterial(balance)
        )
    }

    /// The engine's win percentage from the user's perspective, as a word.
    ///
    /// The buckets are kept — they decide the colour and the spoken label — but
    /// nothing numeric reaches the screen. See the type's own note for why: this
    /// number is the opponent's depth-capped search, one ply behind the board,
    /// and printing `+12%` of it beside an exact material count claims a
    /// precision it does not have.
    static func winPercent(_ percent: Double) -> PlayEvalReading {
        let delta = Int((percent - 50).rounded())
        let magnitude: Magnitude =
            switch abs(delta) {
            case 0..<5: .level
            case 5..<15: .slight
            case 15..<30: .clear
            default: .decisive
            }
        let direction: Direction = magnitude == .level ? .level : (delta > 0 ? .ahead : .behind)
        return make(
            signedValue: magnitude == .level ? 0 : delta,
            magnitude: magnitude,
            text: word(for: direction),
            spoken: spokenWinPercent(delta: delta, magnitude: magnitude)
        )
    }

    /// The engine reading's whole vocabulary.
    ///
    /// Three words, because three is what the source supports and because they
    /// are the words a club player says out loud. Deliberately not "winning" or
    /// "losing" at the decisive end: a 1200 told they are winning stops looking
    /// for counterplay, which is the opposite of what guided mode is for, and
    /// the reading is an estimate rather than a verdict either way.
    private static func word(for direction: Direction) -> String {
        switch direction {
        case .ahead: "BETTER"
        case .level: "EVEN"
        case .behind: "WORSE"
        }
    }

    /// Material on the board, in pawns, from `color`'s point of view.
    static func materialBalance(in position: Position, for color: Piece.Color) -> Int {
        position.pieces.reduce(into: 0) { total, piece in
            let value = value(of: piece.kind)
            total += piece.color == color ? value : -value
        }
    }

    static func value(of kind: Piece.Kind) -> Int {
        switch kind {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }

    // MARK: - Construction

    private static func make(
        signedValue: Int,
        magnitude: Magnitude,
        text overrideText: String? = nil,
        spoken: String
    ) -> PlayEvalReading {
        let direction: Direction =
            if magnitude == .level {
                .level
            } else {
                signedValue > 0 ? .ahead : .behind
            }

        let counted: String =
            switch direction {
            // A word, not `0`: "EVEN" reads at a glance in the same tracked
            // uppercase as the rest of the label vocabulary, and a lone zero
            // beside an arrow looks like a broken number.
            case .level: "EVEN"
            case .ahead: "+\(signedValue)"
            case .behind: "\u{2212}\(abs(signedValue))"
            }
        // The override exists for the one reading that is not a count. Material
        // is exact and prints its number; the engine's estimate prints a word.
        let text = overrideText ?? counted

        let symbol: String =
            switch direction {
            case .ahead: "arrowtriangle.up.fill"
            case .level: "equal"
            case .behind: "arrowtriangle.down.fill"
            }

        return PlayEvalReading(
            direction: direction,
            magnitude: magnitude,
            text: text,
            symbolName: symbol,
            accessibilityText: spoken
        )
    }

    private static func spokenMaterial(_ balance: Int) -> String {
        switch balance {
        case 0: "Material is even"
        case 1: "You are a pawn up"
        case -1: "You are a pawn down"
        case let value where value > 0: "You are \(value) points of material up"
        default: "You are \(abs(balance)) points of material down"
        }
    }

    /// The magnitude the pill drops, said in full — and named as an estimate.
    ///
    /// VoiceOver has room for the qualifier the pill does not, and the qualifier
    /// is the honest part: this is the opponent's own depth-capped reading of
    /// the previous position, not a verdict on the one in front of the user.
    private static func spokenWinPercent(delta: Int, magnitude: Magnitude) -> String {
        let reading: String =
            switch magnitude {
            case .level: "the position is level"
            case .slight: delta > 0 ? "you are slightly better" : "you are slightly worse"
            case .clear: delta > 0 ? "you are clearly better" : "you are clearly worse"
            case .decisive: delta > 0 ? "you are much better" : "you are much worse"
            }
        return "Estimate: \(reading)"
    }
}
