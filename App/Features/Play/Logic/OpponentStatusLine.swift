import Foundation

/// What the opponent's one line of text says right now.
///
/// The opponent block has exactly one line that ever changes: the trait when it
/// is not their move, a short spoken line while they think. Same slot, same type
/// style, crossfaded — nothing moves, one line changes. That is the whole
/// "opponent is thinking" indicator, and it is why there is no spinner: the
/// running clock already says time is passing, and a spinner would say it again
/// while adding a rotating object to a screen whose whole job is stillness.
///
/// Every spoken line is grounded in something the app actually knows — the
/// user's last move gave check, or was a capture, or the opponent is down
/// material. None of them claim a plan the engine did not report. A line that
/// invents "eyeing your queenside" is a lie the user can check against the
/// board, and getting caught in one costs more than the personality gains.
struct OpponentLine: Equatable, Sendable {

    enum Kind: Sendable {
        /// The standing description of how this opponent plays.
        case trait
        /// A first-person line, shown in quotes in a speech bubble.
        case speech
    }

    var text: String
    var kind: Kind
}

enum OpponentStatusLine {

    struct Input: Equatable, Sendable {
        var trait: String
        var isThinking: Bool
        /// Half-moves played so far.
        var ply: Int
        /// SAN of the move the user just played, if any.
        var lastUserSAN: String?
        /// Material from the *user's* perspective, so a positive number means
        /// the opponent is the one who is behind.
        var materialBalance: Int

        init(
            trait: String,
            isThinking: Bool,
            ply: Int = 0,
            lastUserSAN: String? = nil,
            materialBalance: Int = 0
        ) {
            self.trait = trait
            self.isThinking = isThinking
            self.ply = ply
            self.lastUserSAN = lastUserSAN
            self.materialBalance = materialBalance
        }
    }

    static func line(for input: Input) -> OpponentLine {
        guard input.isThinking else {
            return OpponentLine(text: input.trait, kind: .trait)
        }

        if let san = input.lastUserSAN {
            if san.contains("+") || san.contains("#") {
                return OpponentLine(text: "All right, all right. The check.", kind: .speech)
            }
            if san.contains("x") {
                return OpponentLine(text: "So we're trading, then.", kind: .speech)
            }
        }

        // Book moves are not thought about, and pretending otherwise on move
        // three is the kind of small dishonesty that makes an opponent feel
        // scripted.
        if input.ply <= 8 {
            return OpponentLine(text: "Still book, I think.", kind: .speech)
        }

        if input.materialBalance >= 3 {
            return OpponentLine(text: "I need something here.", kind: .speech)
        }
        if input.materialBalance <= -3 {
            return OpponentLine(text: "Let's keep this simple.", kind: .speech)
        }

        return OpponentLine(text: "Give me a second.", kind: .speech)
    }
}
