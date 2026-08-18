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
    /// `+3`, `−2` (a real minus sign, not a hyphen), or `EVEN`.
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

    /// The engine's win percentage from the user's perspective, bucketed.
    ///
    /// Rendered as points above or below even rather than as a raw percentage:
    /// `62%` invites reading it as a probability the engine is not claiming,
    /// while `↑ +12` sits in the same grammar as the material reading beside it.
    static func winPercent(_ percent: Double) -> PlayEvalReading {
        let delta = Int((percent - 50).rounded())
        let magnitude: Magnitude =
            switch abs(delta) {
            case 0..<5: .level
            case 5..<15: .slight
            case 15..<30: .clear
            default: .decisive
            }
        return make(
            signedValue: magnitude == .level ? 0 : delta,
            magnitude: magnitude,
            spoken: spokenWinPercent(delta: delta, magnitude: magnitude)
        )
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

    private static func make(signedValue: Int, magnitude: Magnitude, spoken: String) -> PlayEvalReading {
        let direction: Direction =
            if magnitude == .level {
                .level
            } else {
                signedValue > 0 ? .ahead : .behind
            }

        let text: String =
            switch direction {
            // A word, not `0`: "EVEN" reads at a glance in the same tracked
            // uppercase as the rest of the label vocabulary, and a lone zero
            // beside an arrow looks like a broken number.
            case .level: "EVEN"
            case .ahead: "+\(signedValue)"
            case .behind: "\u{2212}\(abs(signedValue))"
            }

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

    private static func spokenWinPercent(delta: Int, magnitude: Magnitude) -> String {
        switch magnitude {
        case .level: "The position is level"
        case .slight: delta > 0 ? "You are slightly better" : "You are slightly worse"
        case .clear: delta > 0 ? "You are clearly better" : "You are clearly worse"
        case .decisive: delta > 0 ? "You are winning" : "You are losing"
        }
    }
}
