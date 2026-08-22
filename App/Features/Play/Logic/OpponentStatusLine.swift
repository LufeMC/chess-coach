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
        /// The coach's verdict on the move that answered a guided prompt.
        ///
        /// Not the opponent's voice, so it is never quoted. It borrows this slot
        /// because the slot is a fixed two lines — so nothing on the screen
        /// moves when it arrives — and because it is where the user is already
        /// looking the instant their move lands.
        case coach
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
        /// Whether the opponent can take back on the square the user's last
        /// capture landed on.
        ///
        /// The one thing that separates a trade from a gift, and the only way to
        /// know it is to look at the board — which is why it is computed by the
        /// caller from the live position rather than guessed at from the SAN.
        var canAnswerLastCapture: Bool
        /// Whether the move that answered a guided prompt was the one the
        /// position asked for, while that verdict is still worth showing. Nil
        /// at every other moment, which is almost all of them.
        var guidedVerdict: Bool?

        init(
            trait: String,
            isThinking: Bool,
            ply: Int = 0,
            lastUserSAN: String? = nil,
            materialBalance: Int = 0,
            canAnswerLastCapture: Bool = false,
            guidedVerdict: Bool? = nil
        ) {
            self.trait = trait
            self.isThinking = isThinking
            self.ply = ply
            self.lastUserSAN = lastUserSAN
            self.materialBalance = materialBalance
            self.canAnswerLastCapture = canAnswerLastCapture
            self.guidedVerdict = guidedVerdict
        }
    }

    static func line(for input: Input) -> OpponentLine {
        // The verdict outranks the opponent's small talk, including while they
        // think: a guided pause asks a question and the answering move is the
        // answer, so a game that never says whether it landed is asking for
        // nothing. The opponent's running clock still says they are thinking.
        if let hit = input.guidedVerdict {
            return OpponentLine(text: verdict(hit: hit), kind: .coach)
        }

        guard input.isThinking else {
            return OpponentLine(text: input.trait, kind: .trait)
        }

        if let san = input.lastUserSAN {
            if san.contains("+") || san.contains("#") {
                return OpponentLine(text: "All right, all right. The check.", kind: .speech)
            }
            if san.contains("x") {
                // A capture is only a trade if it can be answered. This line
                // used to fire on every capture, so winning a hanging knight
                // was greeted with "so we're trading, then" — the opponent
                // describing, in their own voice, a board that is not there.
                // Small, but the status line is the one place the app claims to
                // be looking at the position, and a claim the user can check
                // and disprove costs more than the personality earns.
                return OpponentLine(
                    text: input.canAnswerLastCapture ? "So we're trading, then." : "You took that one.",
                    kind: .speech
                )
            }
        }

        // Book moves are not thought about, and pretending otherwise on move
        // three is the kind of small dishonesty that makes an opponent feel
        // scripted.
        if input.ply <= 8 {
            // "Book" is the word a club player would use and half this app's
            // readers would not, and every other line in this file is plain
            // English. The slang buys nothing the plain word does not.
            return OpponentLine(text: "Still the opening, I think.", kind: .speech)
        }

        if input.materialBalance >= 3 {
            return OpponentLine(text: "I need something here.", kind: .speech)
        }
        if input.materialBalance <= -3 {
            return OpponentLine(text: "Let's keep this simple.", kind: .speech)
        }

        return OpponentLine(text: "Give me a second.", kind: .speech)
    }

    /// The verdict, stated and then pointed somewhere.
    ///
    /// No praise and no consolation: a hit says what the move was, a miss says
    /// a better one existed and where the user will see it. Naming the better
    /// move here would answer the position the user is still playing, and the
    /// grade knows only that one was stronger — not by how much, and not what
    /// it won.
    private static func verdict(hit: Bool) -> String {
        hit
            ? "Found it \u{2014} that was the move the position asked for."
            : "Missed \u{2014} a stronger move was there. The review will show it."
    }
}
