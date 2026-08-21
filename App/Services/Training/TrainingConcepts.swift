//
//  TrainingConcepts.swift
//  ChessCoach
//

import ChessKit
import Foundation

/// One idea the app teaches before it tests.
///
/// ## Why teaching is a first-class thing here
///
/// A tactics corpus can be handed to a user cold, because a tactic is a search:
/// the position contains everything needed to find the move, and failing teaches
/// you to look harder. An opening, an endgame technique and a positional idea
/// are not searches — they are *knowledge*. Showing someone the Lucena position
/// and marking them wrong teaches nothing at all, because there was nothing in
/// the position to work it out from. They had either been told or they had not.
///
/// So every concept carries the lesson with it, and the first time it comes up
/// in a set the lesson is what the user gets. From then on it is an exercise,
/// with the lesson one tap away. This is the difference between an app that
/// tests you on what you already know and one that can actually add something.
///
/// ## Rating tiers
///
/// A concept has a rating at which it is worth teaching, so a 1000-rated player
/// meets the Italian and basic mates, and Philidor and the outpost wait until
/// they would land. The point is not to hide things: it is that a technique
/// taught before its position ever appears in your games is a technique you
/// will have forgotten by the time it does.
struct TrainingConcept: Sendable, Hashable, Identifiable {

    enum Family: String, Sendable, Hashable, Codable, CaseIterable {
        case opening
        case endgame
        case positional

        /// What the set calls this slot.
        var label: String {
            switch self {
            case .opening: "Opening"
            case .endgame: "Endgame"
            case .positional: "Position"
            }
        }
    }

    /// The lesson, in three short parts.
    ///
    /// Three rather than a paragraph, because they answer three different
    /// questions and a reader skimming for one should not have to read the
    /// other two: *what is it*, *why do I care*, and — the one that actually
    /// transfers — *what do I look for at the board*.
    struct Teaching: Sendable, Hashable {
        var idea: String
        var why: String
        var lookFor: String

        /// The first sentence of ``lookFor``, for the result banner.
        ///
        /// The full cue is written for the lesson card, where there is a whole
        /// screen for it — it runs to about 130 characters, which is more than
        /// the banner can show without cutting the end off. The first sentence
        /// is the instruction; everything after it is the justification, and
        /// the reader has already had that on the card.
        var cue: String {
            guard let end = lookFor.firstIndex(of: ".") else { return lookFor }
            return String(lookFor[...end])
        }
    }

    /// What the user does after being taught.
    enum Exercise: Sendable, Hashable {
        /// Play a stored line. The user plays their side; the opponent's
        /// replies are auto-played, exactly as in a multi-move puzzle.
        case line(fen: String, moves: [String], opponentMovesFirst: Bool)
        /// A corpus position selected by a positional feature, answered with
        /// one move.
        case corpusFeature(PositionalFeature)
        /// One of the endgame drills, played out against the engine.
        case drill(EndgameDrillKind)
    }

    var id: String
    var family: Family
    var title: String
    var teaching: Teaching
    /// The rating from which this concept is worth teaching.
    var fromRating: Int
    var exercise: Exercise
}

// MARK: - Positional features

/// A positional idea that can be *detected* in a position rather than authored.
///
/// ## Why these four
///
/// Hand-built positional exercises do not survive contact with an engine: in a
/// constructed position the engine finds a tactic, and the "positional" answer
/// is second best. Every candidate written by hand failed that check.
///
/// So the positions come from the corpus instead — from puzzles Lichess already
/// tagged as quiet moves, classified by what the answer *does*. The idea is
/// taught by this file; the position is one the engine has already vouched for.
/// That constrains the set to ideas a detector can recognise, which is why the
/// list is short and concrete rather than the whole of positional chess.
enum PositionalFeature: String, Sendable, Hashable, Codable, CaseIterable {
    case outpost
    case openFile
    case blockade
    case worstPiece
}

// MARK: - The catalogue

extension TrainingConcept {

    static let catalogue: [TrainingConcept] = openings + endgames + positional

    // MARK: Openings

    /// A deliberately small repertoire: one opening as White, one answer to
    /// 1.e4, one to 1.d4.
    ///
    /// All three are chosen for *low theory* — the London is a setup rather
    /// than a line, and the Italian and the Queen's Gambit Declined are the
    /// principles played move by move. A repertoire that has to be remembered
    /// is a repertoire that fails the first time the opponent deviates, which
    /// at this level is roughly always.
    static let openings: [TrainingConcept] = [
        TrainingConcept(
            id: "opening.london",
            family: .opening,
            title: "The London System",
            teaching: Teaching(
                idea: "Play d4, then get the dark-squared bishop out to f4 — and only then play e3.",
                why: "It is a setup, not a line: the same eight moves work against almost anything "
                    + "Black tries, so your opening time goes on understanding the position instead "
                    + "of remembering it.",
                lookFor: "Bishop to f4 before e3. That move order is the entire opening — play e3 "
                    + "first and the bishop is stuck behind its own pawns for the rest of the game."
            ),
            fromRating: 0,
            exercise: .line(
                fen: Position.standard.fen,
                moves: [
                    "d2d4", "d7d5", "c1f4", "g8f6", "e2e3", "e7e6", "g1f3", "f8e7",
                    "f1d3", "e8g8", "e1g1", "c7c5", "c2c3", "b8c6", "b1d2"
                ],
                opponentMovesFirst: false
            )
        ),
        TrainingConcept(
            id: "opening.italian",
            family: .opening,
            title: "Answering 1.e4",
            teaching: Teaching(
                idea: "Meet 1.e4 with 1…e5, develop both knights and the bishop, and castle.",
                why: "It claims an equal share of the centre and points every piece at it. There is "
                    + "nothing here to memorise — it is the opening principles, played one move at "
                    + "a time.",
                lookFor: "Knights before bishops, and castled by move six. Do not chase their "
                    + "pieces with pawns while your own king is still in the middle."
            ),
            fromRating: 0,
            exercise: .line(
                fen: Position.standard.fen,
                moves: [
                    "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6",
                    "d2d3", "d7d6", "e1g1", "e8g8"
                ],
                opponentMovesFirst: true
            )
        ),
        TrainingConcept(
            id: "opening.qgd",
            family: .opening,
            title: "Answering 1.d4",
            teaching: Teaching(
                idea: "Hold the centre with d5 and e6, develop, castle.",
                why: "The most solid answer to 1.d4 there is. You concede a little space and get a "
                    + "position with no weaknesses — which is exactly the trade you want while your "
                    + "opponents are still losing pieces.",
                lookFor: "Support d5 with e6 rather than c6, and get castled before anything opens up."
            ),
            fromRating: 0,
            exercise: .line(
                fen: Position.standard.fen,
                moves: ["d2d4", "d7d5", "c2c4", "e7e6", "b1c3", "g8f6", "c1g5", "f8e7", "e2e3", "e8g8"],
                opponentMovesFirst: true
            )
        ),
        TrainingConcept(
            id: "opening.f7attack",
            family: .opening,
            title: "When they come for f7",
            teaching: Teaching(
                idea: "Their queen comes out early to hit f7. Answer it with moves that develop and "
                    + "gain time: …g6 asks the queen to move, then …Nf6 gets a piece out behind it.",
                why: "Below about 1400 this is the most common way to lose a game in ten moves — and "
                    + "the most common way to win one, because every move you spend chasing the "
                    + "queen is a move you were going to make anyway.",
                lookFor: "Never defend f7 with …Nh6 or …Qe7. Kick the queen with a pawn, develop "
                    + "behind it, and let them spend three moves putting the queen back."
            ),
            fromRating: 1000,
            exercise: .line(
                fen: Position.standard.fen,
                moves: ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g7g6", "h5f3", "g8f6"],
                opponentMovesFirst: true
            )
        ),
        TrainingConcept(
            id: "opening.ruyLopez",
            family: .opening,
            title: "When they play Bb5",
            teaching: Teaching(
                idea: "Against the bishop on b5, play …a6 and ask it what it intends. Then develop "
                    + "exactly as you would have anyway.",
                why: "This is the most-played opening in chess above 1200, and it is where your "
                    + "answer to 1.e4 stops working if you have only ever met the bishop on c4. The "
                    + "pin looks worse than it is.",
                lookFor: "…a6 first, every time. If they take the knight, recapture toward the "
                    + "centre with the d-pawn — you get the two bishops and an open file for it."
            ),
            fromRating: 1200,
            exercise: .line(
                fen: Position.standard.fen,
                moves: [
                    "e2e4", "e7e5", "g1f3", "b8c6", "f1b5", "a7a6", "b5a4", "g8f6",
                    "e1g1", "f8e7", "f1e1", "b7b5", "a4b3", "d7d6"
                ],
                opponentMovesFirst: true
            )
        ),
        TrainingConcept(
            id: "opening.flank",
            family: .opening,
            title: "When they avoid the main lines",
            teaching: Teaching(
                idea: "Against 1.Nf3, 1.c4 and most of the rest: …d5, …Nf6, …e6, …Be7, castle. The "
                    + "same five moves, whatever they do.",
                why: "You will meet these often enough to be caught out by them and not often enough "
                    + "to justify learning a line for each. A setup you can play without thinking is "
                    + "worth more than three lines you half-remember.",
                lookFor: "…d5 first, to claim a share of the centre before they take all of it. You "
                    + "do not have to copy their fianchetto to answer it."
            ),
            fromRating: 1300,
            exercise: .line(
                fen: Position.standard.fen,
                moves: [
                    "g1f3", "d7d5", "g2g3", "g8f6", "f1g2", "e7e6",
                    "e1g1", "f8e7", "d2d4", "e8g8"
                ],
                opponentMovesFirst: true
            )
        ),
        TrainingConcept(
            id: "opening.queensGambit",
            family: .opening,
            title: "The Queen's Gambit",
            teaching: Teaching(
                idea: "Play d4 and then c4, hitting their centre pawn from the side before you "
                    + "finish developing.",
                why: "The natural step up from the London, and you already know the position from "
                    + "the other side. Same pawn on d4 — but c4 fights for the centre instead of "
                    + "just holding it, which is what you need once opponents stop hanging pieces.",
                lookFor: "c4 on move two, and do not hurry to take on d5. The pawn is there to ask "
                    + "a question, not to make a trade."
            ),
            fromRating: 1500,
            exercise: .line(
                fen: Position.standard.fen,
                moves: [
                    "d2d4", "d7d5", "c2c4", "e7e6", "b1c3", "g8f6",
                    "c1g5", "f8e7", "e2e3", "e8g8", "g1f3"
                ],
                opponentMovesFirst: false
            )
        ),
        TrainingConcept(
            id: "opening.londonVsFianchetto",
            family: .opening,
            title: "The London against a fianchetto",
            teaching: Teaching(
                idea: "When they play …g6 and …Bg7, put a pawn on h3 before developing your "
                    + "light-squared bishop.",
                why: "It is the one common setup where the London goes wrong. Their knight comes to "
                    + "h5, attacks your bishop on f4, and the bishop has no square worth having — "
                    + "so the piece the whole opening is built around gets traded for a knight.",
                lookFor: "…g6 on the board means h3 next. One quiet move, played before you need it, "
                    + "that keeps h2 free for the bishop to step back to."
            ),
            fromRating: 1600,
            exercise: .line(
                fen: Position.standard.fen,
                moves: [
                    "d2d4", "g8f6", "c1f4", "g7g6", "e2e3", "f8g7",
                    "g1f3", "e8g8", "h2h3", "d7d6", "f1e2"
                ],
                opponentMovesFirst: false
            )
        )
    ]

    // MARK: Endgames

    /// The techniques, wrapped around the drills that already existed.
    ///
    /// The drills were on the Train tab as a second thing to choose, which
    /// meant they were practised by whoever already knew they mattered. Here
    /// they arrive in the set with the method attached.
    static let endgames: [TrainingConcept] = [
        TrainingConcept(
            id: "endgame.kqk",
            family: .endgame,
            title: "Queen against king",
            teaching: Teaching(
                idea: "Use the queen to shrink the box the enemy king lives in, then bring your own "
                    + "king up to deliver mate on the edge.",
                why: "It is the first mate you must never fumble. Failing to convert queen against "
                    + "king does not lose you half a point — it loses the whole game you had already won.",
                lookFor: "Keep the queen a knight's move from their king. It shrinks the box every "
                    + "time and it is the one pattern that cannot stalemate."
            ),
            fromRating: 0,
            exercise: .drill(.kqk)
        ),
        TrainingConcept(
            id: "endgame.krk",
            family: .endgame,
            title: "Rook against king",
            teaching: Teaching(
                idea: "Cut the king off along a rank or file, then use your king to squeeze it "
                    + "toward the edge.",
                why: "Harder than the queen because the rook cannot do it alone — this is the first "
                    + "endgame where the king is a piece you have to use.",
                lookFor: "The rook draws a line the enemy king cannot cross. Every move should make "
                    + "the box smaller or bring your king closer; if it does neither, it is a wasted move."
            ),
            fromRating: 0,
            exercise: .drill(.krk)
        ),
        TrainingConcept(
            id: "endgame.kpk",
            family: .endgame,
            title: "King and pawn: the opposition",
            teaching: Teaching(
                idea: "With kings facing each other on the same file with one square between them, "
                    + "whoever is *not* to move is winning the argument.",
                why: "It is the whole of king and pawn endings. Knowing which side has the "
                    + "opposition tells you whether a position is a win or a draw before you "
                    + "calculate anything.",
                lookFor: "Kings facing, one square apart, and ask whose turn it is. Get your king in "
                    + "front of your pawn — in front, not beside it."
            ),
            fromRating: 0,
            exercise: .drill(.kpk)
        ),
        TrainingConcept(
            id: "endgame.kbbk",
            family: .endgame,
            title: "Two bishops against king",
            teaching: Teaching(
                idea: "The bishops work as a wall on two adjacent diagonals, driving the king to a "
                    + "corner while your own king cuts off the escape.",
                why: "Rare, but it is on the clock when it happens, and nobody works it out at the "
                    + "board without having seen it once.",
                lookFor: "Bishops side by side on adjacent diagonals. The king has to be driven to a "
                    + "corner — any corner will do, unlike with a knight and bishop."
            ),
            fromRating: 1200,
            exercise: .drill(.kbbk)
        ),
        TrainingConcept(
            id: "endgame.lucena",
            family: .endgame,
            title: "Lucena: building the bridge",
            teaching: Teaching(
                idea: "With a rook and pawn on the seventh against a rook, your rook steps to the "
                    + "fourth rank to shelter your king from checks.",
                why: "This is the single most common winning rook ending there is. Rook endings are "
                    + "most of all endings, and this is the position they funnel into.",
                lookFor: "Pawn on the seventh, your king in front of it. Their rook checks from "
                    + "the side, and building the bridge is what stops the checks."
            ),
            fromRating: 1400,
            exercise: .drill(.lucena)
        ),
        TrainingConcept(
            id: "endgame.philidor",
            family: .endgame,
            title: "Philidor: the third-rank defence",
            teaching: Teaching(
                idea: "Defending a rook ending a pawn down: sit your rook on your third rank until "
                    + "their pawn advances, then drop behind and check from the back.",
                why: "The other half of rook endings. Knowing this turns a lost-looking game into a "
                    + "draw, and it comes up far more often than the wins do.",
                lookFor: "Their pawn not yet on the sixth. Hold the third rank and wait — the moment "
                    + "the pawn steps up, go to the back rank and check from behind."
            ),
            fromRating: 1400,
            exercise: .drill(.philidor)
        )
    ]

    // MARK: Positional

    static let positional: [TrainingConcept] = [
        TrainingConcept(
            id: "positional.outpost",
            family: .positional,
            title: "The outpost",
            teaching: Teaching(
                idea: "A square in their half that no pawn of theirs can ever attack, defended by a "
                    + "pawn of yours.",
                why: "A knight there cannot be chased away, so it stays strong for the rest of the "
                    + "game. It is the clearest case of a move that wins nothing today and decides "
                    + "the game anyway.",
                lookFor: "A square on their side with no enemy pawn left on either neighbouring "
                    + "file. Then ask which of your knights can reach it."
            ),
            fromRating: 1200,
            exercise: .corpusFeature(.outpost)
        ),
        TrainingConcept(
            id: "positional.openFile",
            family: .positional,
            title: "The open file",
            teaching: Teaching(
                idea: "A file with no pawns on it at all is the one road your rook can travel.",
                why: "Rooks do nothing for most of a game and then decide it. The side that puts a "
                    + "rook on the open file first usually keeps it, because the other rook now has "
                    + "to trade or stay home.",
                lookFor: "A file where both sides' pawns have gone. Put a rook there before they do "
                    + "— even when nothing happens immediately."
            ),
            fromRating: 1200,
            exercise: .corpusFeature(.openFile)
        ),
        TrainingConcept(
            id: "positional.blockade",
            family: .positional,
            title: "Blockading a passed pawn",
            teaching: Teaching(
                idea: "Put a piece directly in front of a passed pawn — the one square that pawn can "
                    + "never attack.",
                why: "A pawn that cannot move stops being a threat and becomes a weakness you can "
                    + "attack at leisure, while your blockading piece sits somewhere completely safe.",
                lookFor: "An enemy pawn with no friendly pawn on either side of it. The square "
                    + "immediately in front is where your knight wants to be."
            ),
            fromRating: 1200,
            exercise: .corpusFeature(.blockade)
        ),
        TrainingConcept(
            id: "positional.worstPiece",
            family: .positional,
            title: "Improve your worst piece",
            teaching: Teaching(
                idea: "Find the piece doing the least, and spend a move giving it something to do.",
                why: "When there is no tactic, this is almost always the strongest move on the "
                    + "board — and it is the question that turns 'I have no idea what to play' into "
                    + "a plan.",
                lookFor: "The piece that has barely moved, or has nowhere to go. Ask where it would "
                    + "*like* to stand, then spend the move putting it there."
            ),
            fromRating: 1300,
            exercise: .corpusFeature(.worstPiece)
        )
    ]

    /// The concepts worth teaching at a rating, in catalogue order.
    static func available(atRating rating: Int) -> [TrainingConcept] {
        catalogue.filter { $0.fromRating <= rating }
    }

    static func concept(id: String) -> TrainingConcept? {
        catalogue.first { $0.id == id }
    }
}
