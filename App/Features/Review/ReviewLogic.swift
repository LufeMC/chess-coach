import AnalysisKit
import BoardUI
import ChessKit
import Database
import EngineKit
import Foundation
import TrainingCore

// Everything in this file is pure: value in, value out, no database, no engine,
// no main actor. That is deliberate — the Review screen's genuinely error-prone
// parts (perspective conversion, ply↔position mapping, which rows earn a chip)
// are exactly the parts worth testing, and they can only be tested if they are
// reachable without a game on disk.

// MARK: - Timeline

/// The game replayed onto real positions, indexed by **position index**.
///
/// Two numbering schemes meet on this screen and confusing them is the classic
/// off-by-one here:
///
/// * `GameMove.ply` / `Moment.ply` are **1-based half-move numbers** — White's
///   first move is ply 1.
/// * A *position index* `k` is the position with the first `k` half-moves
///   applied, so index 0 is the starting position and index `n` is the final
///   one. `EvalPoint.ply` uses this scheme, and so does the scrubber.
///
/// The conversion is therefore: the position *after* move `p` is index `p`, and
/// the position *before* it (the one a moment asks you to look at) is `p - 1`.
struct ReviewTimeline: Sendable {

    /// `positions[k]` has the first `k` half-moves applied.
    let positions: [Position]
    /// `moves[k]` is the move that turns `positions[k]` into `positions[k + 1]`.
    let moves: [Move]
    /// SAN exactly as it was stored, keyed by 1-based ply. Preferred over
    /// re-deriving it: the stored text is what the rest of the app shows.
    let sanByPly: [Int: String]

    init(moveRows: [GameMove]) {
        var positions: [Position] = [.standard]
        var replayed: [Move] = []
        var sans: [Int: String] = [:]

        for row in moveRows.sorted(by: { $0.ply < $1.ply }) {
            guard
                let current = positions.last,
                let applied = LineReplay.apply(uci: row.uci, to: current)
            else {
                // Stop rather than throw. A game whose 40th move fails to parse is
                // still worth reviewing up to move 39, and refusing to open it
                // would hide the only evidence of what went wrong.
                break
            }
            replayed.append(applied.move)
            positions.append(applied.position)
            sans[row.ply] = row.san
        }

        self.positions = positions
        self.moves = replayed
        self.sanByPly = sans
    }

    /// Test seam: build a timeline straight from UCI strings.
    init(uci: [String]) {
        self.init(
            moveRows: uci.enumerated().map { index, text in
                GameMove(gameID: UUID(), ply: index + 1, san: text, uci: text)
            }
        )
    }

    /// Number of positions, i.e. `moves.count + 1`.
    var positionCount: Int { positions.count }
    /// Highest valid position index.
    var lastIndex: Int { positions.count - 1 }

    func clamp(_ index: Int) -> Int { min(max(index, 0), lastIndex) }

    func position(at index: Int) -> Position { positions[clamp(index)] }

    /// The move that produced position `index`, if any.
    func move(into index: Int) -> Move? {
        let clamped = clamp(index)
        guard clamped > 0, clamped - 1 < moves.count else { return nil }
        return moves[clamped - 1]
    }

    /// Last-move marks for the board at `index`.
    func highlights(at index: Int) -> [SquareHighlight] {
        guard let move = move(into: index) else { return [] }
        return SquareHighlight.lastMove(from: move.start, to: move.end)
    }

    /// Whose move it is in `positions[index]`.
    func sideToMove(at index: Int) -> Piece.Color { position(at: index).sideToMove }
}

// MARK: - Perspective

/// Which colour moved on a given 1-based ply. White moves on the odd ones.
///
/// One line, but it is the hinge every sign in this file turns on, so it gets a
/// name instead of being re-derived at each call site.
func moverColor(forPly ply: Int) -> Piece.Color {
    ply.isMultiple(of: 2) ? .black : .white
}

/// Whose move it is in the position at `index` half-moves.
func sideToMoveColor(atPositionIndex index: Int) -> Piece.Color {
    index.isMultiple(of: 2) ? .white : .black
}

// MARK: - Eval track

/// The evaluation curve and the numbers that hang off it, all in a **fixed
/// White-relative perspective**.
///
/// Both stored sources are relative to somebody who changes every ply — engine
/// scores are side-to-move relative, `GameMove.winPct*` are mover-relative — so
/// plotting either one raw produces a curve that zig-zags once per half-move.
/// Everything is converted here, once, and every consumer downstream (graph,
/// eval column, eval bar) reads the same White-relative numbers.
struct ReviewEvalTrack: Sendable, Equatable {

    /// Win percentage for White, 0…100, keyed by position index.
    var whiteWinPercent: [Int: Double] = [:]
    /// Mate distance in moves, positive when *White* is mating, keyed by
    /// position index. Only present where the engine reported a mate.
    var whiteMate: [Int: Int] = [:]
    /// The contiguous prefix of `whiteWinPercent`, as the graph wants it.
    var points: [EvalPoint] = []

    var isEmpty: Bool { points.isEmpty }

    /// Builds the track from whatever analysis left behind.
    ///
    /// - parameter evals: `plyEvals` rows. `PlyEval.ply` is 1-based over
    ///   *positions* (`ply: 1` is the starting position), matching
    ///   `AnalysisPipeline.PositionEval`, so the position index is `ply - 1`.
    /// - parameter moveRows: `gameMoves` rows, whose `winPctBefore`/`winPctAfter`
    ///   are **mover-relative** (see `AnalyzedMove`).
    /// - parameter positionCount: `moves + 1`; anything beyond it is ignored, so
    ///   a stale eval row from a longer previous analysis cannot extend the curve
    ///   past the end of the game.
    static func build(
        evals: [PlyEval],
        moveRows: [GameMove],
        positionCount: Int
    ) -> ReviewEvalTrack {
        var track = ReviewEvalTrack()
        guard positionCount > 0 else { return track }

        // Move rows first: they are the coarse source, present as soon as the
        // write-back phase runs. Engine rows overwrite them below because they
        // also cover positions no move produced (the final one) and carry mate
        // distances the win percentage has already saturated away.
        for row in moveRows {
            let mover = moverColor(forPly: row.ply)
            if let before = row.winPctBefore {
                let index = row.ply - 1
                if index >= 0, index < positionCount {
                    track.whiteWinPercent[index] = whiteRelative(winPercent: before, mover: mover)
                }
            }
            if let after = row.winPctAfter {
                let index = row.ply
                if index >= 0, index < positionCount {
                    track.whiteWinPercent[index] = whiteRelative(winPercent: after, mover: mover)
                }
            }
        }

        for row in evals {
            let index = row.ply - 1
            guard index >= 0, index < positionCount else { continue }
            guard let score = storedScore(cp: row.pv1Cp, mate: row.pv1Mate) else { continue }

            let white = Perspective.whiteRelative(score, sideToMove: sideToMoveColor(atPositionIndex: index))
            track.whiteWinPercent[index] = EvalMath.winPercent(score: white)
            if case .mate(let moves) = white {
                track.whiteMate[index] = moves
            }
        }

        // Only the contiguous prefix is plotted. A half-analysed game leaves a
        // hole in the middle of the map, and interpolating across it would draw a
        // straight line through positions nobody evaluated — a claim the data
        // does not support.
        var points: [EvalPoint] = []
        for index in 0..<positionCount {
            guard let percent = track.whiteWinPercent[index] else { break }
            points.append(EvalPoint(ply: index, winPercent: min(100, max(0, percent))))
        }
        track.points = points

        return track
    }

    /// Converts a mover-relative win percentage into a White-relative one.
    ///
    /// Complementary rather than negated, because the win% curve is symmetric
    /// about 50 — the identity `winPercent(cp) + winPercent(-cp) == 100` that
    /// `EvalMath` documents.
    static func whiteRelative(winPercent: Double, mover: Piece.Color) -> Double {
        mover == .white ? winPercent : 100 - winPercent
    }

    private static func storedScore(cp: Int?, mate: Int?) -> UCIScore? {
        if let mate { return .mate(mate) }
        if let cp { return .centipawns(cp) }
        return nil
    }
}

// MARK: - Formatting

/// Turns win percentages back into the pawn units chess players read.
enum ReviewEvalFormat {

    /// Half a pawn, the width of the "effectively equal" band on the graph.
    static let equalBandCentipawns = 50

    /// The equal band expressed as a distance from 50% win, which is the unit the
    /// graph plots. Derived rather than hard-coded so it tracks `EvalMath`'s
    /// sigmoid if the fit is ever retuned.
    static var equalBandWinPercent: Double {
        EvalMath.winPercent(cp: equalBandCentipawns) - 50
    }

    /// Inverse of `EvalMath.winPercent(cp:)`.
    ///
    /// `winPercent(cp) = 100 / (1 + exp(-k·cp))`, so `cp = -ln(100/w - 1) / k`.
    /// The input is clamped away from the asymptotes: 0% and 100% are reached by
    /// mate scores, which carry no centipawn meaning at all, and an unclamped
    /// logarithm there returns infinity.
    static func centipawns(fromWhiteWinPercent percent: Double) -> Double {
        let clamped = min(max(percent, 0.5), 99.5)
        return -log(100 / clamped - 1) / EvalMath.winPercentK
    }

    /// `"+1.2"`, `"−0.4"`, `"0.0"` — always signed, always one decimal.
    static func pawns(_ centipawns: Double) -> String {
        let pawns = (centipawns / 100 * 10).rounded() / 10
        if pawns > 0.049 { return "+\(oneDecimal(pawns))" }
        if pawns < -0.049 { return "\(minus)\(oneDecimal(abs(pawns)))" }
        return "0.0"
    }

    /// The eval column for a position: a mate distance when there is one, a pawn
    /// count otherwise. White-relative in both cases.
    static func evalLabel(winPercent: Double?, mate: Int?) -> String? {
        if let mate {
            // Spelled out rather than `M4`. The column already mixes two frames
            // of reference — White-relative evals beside mover-relative costs —
            // and "M4"/"−M3" is a third thing to decode, unexplained anywhere on
            // the screen. The side is named because the sign alone is what a
            // Black player reads backwards.
            return "#\(abs(mate)) \(mate >= 0 ? "W" : "B")"
        }
        guard let winPercent else { return nil }
        return pawns(centipawns(fromWhiteWinPercent: winPercent))
    }

    /// What a move cost the player who made it, in pawns, always ≤ 0.
    ///
    /// Both inputs are mover-relative, which is the only pairing that means
    /// anything: the same move is a loss for one side and a gain for the other,
    /// and the move list is a list of decisions, not of positions.
    static func moverLoss(winPctBefore: Double?, winPctAfter: Double?) -> Double? {
        guard let winPctBefore, let winPctAfter else { return nil }
        let before = centipawns(fromWhiteWinPercent: winPctBefore)
        let after = centipawns(fromWhiteWinPercent: winPctAfter)
        return (after - before) / 100
    }

    /// `"−2.4"`, or `nil` when the move lost nothing worth printing.
    ///
    /// Gains are not shown. A move cannot improve on the best move, so a positive
    /// delta is search noise, and printing it would invite reading the column as
    /// a score rather than as a cost.
    static func lossLabel(_ pawns: Double?) -> String? {
        guard let pawns, pawns <= -0.05 else { return nil }
        return "\(minus)\(oneDecimal(abs(pawns)))"
    }

    /// The win percentage at which the stored curve has saturated.
    ///
    /// The same bound ``centipawns(fromWhiteWinPercent:)`` clamps to, and for the
    /// same reason: 0% and 100% are written by *mate* scores, which carry no
    /// centipawn meaning at all, so inverting the sigmoid there returns the
    /// clamp's own value rather than anything about the position.
    static let saturatedWinPercent = 99.5

    /// Which end of the curve a stored win percentage has saturated at.
    enum MateEnd: Equatable, Sendable {
        /// The side this percentage belongs to is mating.
        case mating
        /// The side this percentage belongs to is being mated.
        case mated
    }

    static func mateEnd(_ winPercent: Double) -> MateEnd? {
        if winPercent >= saturatedWinPercent { return .mating }
        if winPercent <= 100 - saturatedWinPercent { return .mated }
        return nil
    }

    /// What a move cost its mover.
    ///
    /// Mate is answered before the pawn arithmetic, because the arithmetic is
    /// meaningless across a saturated end. A move that allows mate stores 0% for
    /// its mover afterwards, and 0% inverts to the clamp — about fourteen pawns —
    /// so the cost column used to print `−14.4` on precisely the most dramatic
    /// move of the game. "−14.4" is not a smaller version of "you allowed mate";
    /// it is a number a 1200 player reads as a bug.
    ///
    /// Only losses are named, which is why each mate case is gated both ways: a
    /// move that keeps a mate it already had, or stays mated, cost nothing new
    /// and falls through to the pawn figure (zero, and therefore nothing).
    static func cost(winPctBefore: Double?, winPctAfter: Double?) -> ReviewMoveCost? {
        guard let winPctBefore, let winPctAfter else { return nil }
        if mateEnd(winPctAfter) == .mated, mateEnd(winPctBefore) != .mated { return .allowedMate }
        if mateEnd(winPctBefore) == .mating, mateEnd(winPctAfter) != .mating { return .missedMate }
        return lossLabel(moverLoss(winPctBefore: winPctBefore, winPctAfter: winPctAfter))
            .map(ReviewMoveCost.pawns)
    }

    /// U+2212, not a hyphen: hyphens are too short to read as a sign next to
    /// monospaced digits.
    static let minus = "\u{2212}"

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Reading the curve

/// "Am I winning here?", answered in words for the position the board is
/// standing on.
///
/// The scrubber is drawn White-at-top and never flipped, for a good reason —
/// two games with the same shape have to look like the same object — but that
/// leaves a player of Black watching the curve *rise* as they lose, and on the
/// phone there was no number, no word and no eval bar to check it against. The
/// axis names their end; this says which way it is going in the reader's own
/// terms, so the graph can stay a shape rather than a puzzle.
///
/// The bands are deliberately not three. "You are winning" at six-tenths of a
/// pawn is an overclaim, and a reader who checks it against the position and
/// finds it wrong stops believing the ones that are right.
enum ReviewEvalReading {

    /// Half a pawn, the same band the graph greys out as effectively equal.
    static let levelCentipawns = Double(ReviewEvalFormat.equalBandCentipawns)
    /// A pawn and a half: an edge worth playing for, not a won game.
    static let slightCentipawns = 150.0
    /// Three pawns — a piece — past which "winning" is a fair word.
    static let winningCentipawns = 300.0

    /// - parameter whiteWinPercent: White-relative win percentage at the
    ///   position, from ``ReviewEvalTrack``.
    /// - parameter whiteMate: Mate distance, positive when White is mating.
    /// - parameter playedSide: The colour the reader played, *not* the board
    ///   orientation — flipping the board must not change who "you" is.
    /// - returns: `nil` when nothing has been evaluated there yet, which reads
    ///   as an empty slot rather than as "Level".
    static func phrase(
        whiteWinPercent: Double?,
        whiteMate: Int?,
        playedSide: Piece.Color
    ) -> String? {
        let sign: Double = playedSide == .white ? 1 : -1

        if let whiteMate {
            let moves = abs(whiteMate)
            // A mate distance of zero is mate already on the board; there is no
            // "in 0 moves" to print.
            let distance = moves == 0 ? "Mate" : "Mate in \(moves)"
            return Double(whiteMate) * sign >= 0 ? "\(distance) for you" : "\(distance) for them"
        }

        guard let whiteWinPercent else { return nil }
        let centipawns = ReviewEvalFormat.centipawns(fromWhiteWinPercent: whiteWinPercent) * sign

        switch abs(centipawns) {
        case ..<levelCentipawns: return "Level"
        case ..<slightCentipawns: return centipawns > 0 ? "You are slightly better" : "You are slightly worse"
        case ..<winningCentipawns: return centipawns > 0 ? "You are better" : "You are worse"
        default: return centipawns > 0 ? "You are winning" : "You are losing"
        }
    }
}

// MARK: - Move rows

/// What one move cost the player who made it.
///
/// A value rather than a formatted string because the same cost is phrased three
/// different ways on this screen — a 44pt table cell, a filmstrip caption, and a
/// line under a thumbnail — and only the first of those has room for the short
/// form. Handing every call site a pre-formatted `"mate"` produced the caption
/// `"mate after Nxe5"`, which reads as gibberish.
enum ReviewMoveCost: Equatable, Sendable {

    /// A pawn figure, e.g. `"−2.4"`. Always a loss; see ``ReviewEvalFormat/lossLabel(_:)``.
    case pawns(String)
    /// The move let a forced mate happen.
    case allowedMate
    /// The move gave up a forced mate the mover already had.
    case missedMate

    /// The move table's Cost cell, which is a narrow monospaced column.
    var label: String {
        switch self {
        case .pawns(let text): text
        case .allowedMate, .missedMate: "mate"
        }
    }

    /// The same cost written out, for the one caption with room for a phrase.
    ///
    /// Both mate cases are claims the engine actually made — the stored win
    /// percentage for the mover is a mate score at one end of this move and not
    /// at the other — so naming them is reporting, not inference.
    func phrase(playedSAN: String) -> String {
        switch self {
        case .pawns(let text): "\(text) after \(playedSAN)"
        case .allowedMate: "\(playedSAN) allowed mate"
        case .missedMate: "\(playedSAN) gave up a forced mate"
        }
    }
}

/// One row of the move table.
struct ReviewMoveRow: Identifiable, Sendable, Equatable {
    var id: UUID
    /// 1-based half-move number.
    var ply: Int
    var moveNumber: Int
    var isWhite: Bool
    /// `"23. Nf3"` or `"23… Nf6"`.
    var label: String
    var san: String
    /// Set only for moves the analysis actually judged — see `chip(for:isMoment:)`.
    var chip: BoardUI.MoveClassification?
    /// White-relative eval after the move, e.g. `"+1.2"`. `nil` before analysis.
    var evalAfter: String?
    /// What the move cost its mover, e.g. `"−2.4"`. `nil` when it cost nothing.
    var loss: String?
    /// True when this ply is one of the game's selected moments.
    var isMoment: Bool

    /// The position index the board jumps to when this row is tapped: after the
    /// move, so the row and the board agree about what happened.
    var positionIndex: Int { ply }
}

enum ReviewMoveRows {

    /// Which stored classification strings earn a chip.
    ///
    /// Three of the five never do. `nil` and `"good"` are the unremarkable
    /// majority of any game, and `"best"` is unremarkable *too* — a club player
    /// finds the engine move constantly, and badging all of those turns the table
    /// into a heat map, which the design conventions call out by name.
    ///
    /// What earns a badge on top of the stored string is the *slate*: a ply the
    /// analysis picked out as a moment, badged with the grade the slate gave it.
    /// That covers the reinforcement case ("best" somewhere it was genuinely
    /// hard) which is the one kind of good move worth pointing at, and it also
    /// settles a disagreement the two views used to have. A proven result flip —
    /// a win that became a draw, admitted by `AnalysisPipeline.provesResultChange`
    /// — is written `"good"` on the move row while the card grades it a mistake,
    /// so the table showed nothing at all on the one move the filmstrip was
    /// shouting about.
    static func chip(
        for classification: String?,
        momentGrade: BoardUI.MoveClassification?
    ) -> BoardUI.MoveClassification? {
        switch classification {
        case "blunder": .blunder
        case "mistake": .mistake
        case "inaccuracy": .inaccuracy
        default: momentGrade
        }
    }

    /// - parameter momentGrades: Grade by ply for the plies the analysis kept as
    ///   moments, from ``ReviewMomentCards/classification(for:)``. A ply absent
    ///   from it is not a moment.
    static func rows(
        moveRows: [GameMove],
        track: ReviewEvalTrack,
        momentGrades: [Int: BoardUI.MoveClassification]
    ) -> [ReviewMoveRow] {
        moveRows.sorted { $0.ply < $1.ply }.map { row in
            let momentGrade = momentGrades[row.ply]
            let isWhite = moverColor(forPly: row.ply) == .white
            let moveNumber = (row.ply + 1) / 2

            return ReviewMoveRow(
                id: row.id,
                ply: row.ply,
                moveNumber: moveNumber,
                isWhite: isWhite,
                // The ellipsis for Black is the standard notation for "the move
                // number was already spent on White's move".
                label: isWhite ? "\(moveNumber). \(row.san)" : "\(moveNumber)… \(row.san)",
                san: row.san,
                chip: chip(for: row.classification, momentGrade: momentGrade),
                evalAfter: ReviewEvalFormat.evalLabel(
                    winPercent: track.whiteWinPercent[row.ply],
                    mate: track.whiteMate[row.ply]
                ),
                loss: ReviewEvalFormat.cost(
                    winPctBefore: row.winPctBefore,
                    winPctAfter: row.winPctAfter
                )?.label,
                isMoment: momentGrade != nil
            )
        }
    }
}

// MARK: - Moments

/// One card in the filmstrip, plus everything the coach panel needs about it.
struct ReviewMomentCard: Identifiable, Sendable {
    var id: UUID
    /// 1-based ply of the move that created the moment.
    var ply: Int
    var moveNumber: Int
    /// `"Move 23 · Blunder · −2.4"`.
    var caption: String
    var classification: BoardUI.MoveClassification
    var thumbnail: MomentThumbnail
    var coachText: String?
    var diagnosis: ReviewDiagnosis
    /// The Socratic lead-in for this cause. Nil for a reinforcement, which is
    /// never asked what it allowed in return.
    var question: String?
    var playedSAN: String
    var bestSAN: String

    /// The board jumps *before* the move: the point of a moment is the choice
    /// that was still open, not the wreckage after it.
    var positionIndex: Int { ply - 1 }
}

/// What the analysis concluded about a moment, in words.
///
/// Both halves are already on the stored row and both were previously legible
/// only inside the note's prose — which is the one place a reader scanning a
/// screen does not look. A moment is the app's diagnosis, and a diagnosis that
/// has to be read out of a paragraph is a paragraph.
struct ReviewDiagnosis: Sendable, Equatable {
    /// The cause in the leak table's words. Deliberately the *same* words: a
    /// mistake that reads "Hanging pieces" here and something else on the
    /// Profile leak it feeds is two diagnoses, not one.
    var title: String
    /// The step of the move routine that broke down, when the row names one.
    var step: String?
}

enum ReviewDiagnoses {

    /// A reinforcement's label.
    ///
    /// It gets no cause and no step because it is not a diagnosis of anything:
    /// `MomentBuilder` hands a praised move the `generic` tag precisely because
    /// every value in the taxonomy names something that went wrong, and the
    /// filmstrip captions the same card as praise two views away.
    static let praiseTitle = "Well played"

    /// The label for a move no detector explained.
    ///
    /// AnalysisKit's own wording for the tag. "Generic" would print an
    /// implementation detail, and anything more specific would invent the
    /// finding the detectors did not make.
    static let unexplainedTitle = "A move that cost something"

    /// The label above a moment's note.
    static func diagnosis(for moment: Database.Moment) -> ReviewDiagnosis {
        guard MomentKind(rawValue: moment.kind) != .reinforcement else {
            return ReviewDiagnosis(title: praiseTitle, step: nil)
        }

        let step = AnalysisKit.StepTag(rawValue: moment.stepTag).map(stepTitle)
        guard moment.causeTag != AnalysisKit.CauseTag.generic.rawValue else {
            return ReviewDiagnosis(title: unexplainedTitle, step: step)
        }
        return ReviewDiagnosis(
            title: LeakTable.title(for: TrainingCore.CauseTag(moment.causeTag)),
            step: step
        )
    }

    /// The Socratic question this moment opens with, or `nil` where asking one
    /// would be wrong.
    static func question(for moment: Database.Moment) -> String? {
        guard MomentKind(rawValue: moment.kind) != .reinforcement else { return nil }
        guard let cause = AnalysisKit.CauseTag(rawValue: moment.causeTag) else { return nil }
        return CoachingQuestions.question(forCauseTag: cause)
    }

    /// The step of the move routine, by name.
    ///
    /// Named rather than numbered. A number is a pointer, and there is nothing
    /// for it to point at: no lesson, onboarding card or Train concept presents
    /// the five steps as a sequence, so "Step 5 · Blunder check" on a first-time
    /// reviewer's first card promises a curriculum the product does not have and
    /// leaves them wondering what steps 1 to 4 were. The names carry the meaning
    /// on their own; the numbers come back the day the routine is taught.
    static func stepTitle(_ step: AnalysisKit.StepTag) -> String {
        switch step {
        case .s1WhatChanged: "What changed"
        case .s2ChecksCapturesThreats: "Checks and threats"
        case .s3Candidates: "Candidates"
        case .s4Calculate: "Calculation"
        case .s5BlunderCheck: "Blunder check"
        case .kKnowledge: "Knowledge, not process"
        }
    }
}

enum ReviewMomentCards {

    /// Three, never more.
    ///
    /// A ceiling, not a quota. The number is a product decision rather than a
    /// layout constraint: the daily loop is built around a review that stays
    /// short enough to finish, and a filmstrip that sometimes shows seven turns
    /// a five-minute step into an open-ended one. Fewer than three is the normal
    /// case for a clean game and is left alone — the screens that count moments
    /// take their number from what the game produced, never from this constant.
    static let limit = 3

    static func cards(
        moments: [Database.Moment],
        orientation: Piece.Color,
        moveRows: [GameMove],
        limit: Int = limit
    ) -> [ReviewMomentCard] {
        let costByPly: [Int: ReviewMoveCost] = moveRows.reduce(into: [:]) { result, row in
            result[row.ply] = ReviewEvalFormat.cost(
                winPctBefore: row.winPctBefore,
                winPctAfter: row.winPctAfter
            )
        }

        return
            moments
            // Ranked by score to choose, then re-sorted by ply to show: the strip
            // is read left to right as the game, not as a leaderboard.
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .sorted { $0.ply < $1.ply }
            .compactMap { moment in
                guard let position = Position(fen: moment.fen) else { return nil }

                let classification = classification(for: moment)
                let moveNumber = (moment.ply + 1) / 2
                let cost = costByPly[moment.ply]

                var caption = "Move \(moveNumber) · \(classification.title)"
                if let cost { caption += " · \(cost.label)" }

                return ReviewMomentCard(
                    id: moment.id,
                    ply: moment.ply,
                    moveNumber: moveNumber,
                    caption: caption,
                    classification: classification,
                    thumbnail: MomentThumbnail(
                        id: moment.id,
                        position: position,
                        orientation: orientation,
                        moveNumber: moveNumber,
                        san: moment.playedSAN,
                        classification: classification,
                        // The filmstrip's own caption slot carries the line the
                        // brief specifies; the card already shows the move number
                        // on the thumbnail and the grade in its badge.
                        stake: cost?.phrase(playedSAN: moment.playedSAN),
                        highlights: highlights(forUCI: moment.playedUCI)
                    ),
                    coachText: moment.coachText,
                    diagnosis: ReviewDiagnoses.diagnosis(for: moment),
                    question: ReviewDiagnoses.question(for: moment),
                    playedSAN: moment.playedSAN,
                    bestSAN: moment.bestSAN
                )
            }
    }

    /// Grade for a moment.
    ///
    /// Reinforcement moments are `.great` rather than `.best`: they were picked
    /// *because* the position could have gone wrong, which is a different claim
    /// from "this matched the engine".
    ///
    /// A moment stored as a *mistake* is never graded as praise, even when its
    /// expected-points loss is below the inaccuracy threshold. There is exactly
    /// one way for that combination to reach the database:
    /// `MomentBuilder.isMistakeCandidate` gates on the loss, so anything under
    /// the threshold got in through `AnalysisPipeline.provesResultChange` — a
    /// detector proved the *result class* changed (a won king-and-pawn ending
    /// that became a draw) while the centipawn score barely moved, which is the
    /// whole reason the bitbase exists. Grading off the loss alone returned
    /// `.best`, so the one endgame error the pipeline goes out of its way to
    /// surface arrived wearing an accent-coloured "Best" badge directly above a
    /// note explaining that the win had been thrown away.
    static func classification(for moment: Database.Moment) -> BoardUI.MoveClassification {
        if MomentKind(rawValue: moment.kind) == .reinforcement { return .great }
        switch EvalMath.judgment(deltaEP: moment.deltaEP) {
        case .blunder: return .blunder
        case .mistake: return .mistake
        case .inaccuracy: return .inaccuracy
        case .ok: return .mistake
        }
    }

    /// Marks the squares the played move used, so the thumbnail shows *which*
    /// move is under discussion without a caption saying so.
    static func highlights(forUCI uci: String) -> [SquareHighlight] {
        guard uci.count >= 4 else { return [] }
        let characters = Array(uci)
        let from = Square(String(characters[0...1]))
        let to = Square(String(characters[2...3]))
        return SquareHighlight.lastMove(from: from, to: to) + [SquareHighlight(to, .momentSquare)]
    }
}

// MARK: - Suggested questions

/// A question the card offers, and the answer the app can prove.
///
/// The pair is the whole point: a question the screen cannot answer from stored
/// data would be a prompt, and a prompt with nothing behind it is worse than
/// silence on a screen whose job is to be believed. Both answers here come from
/// rows the analysis already wrote — the engine's move, and the curriculum's own
/// mapping from the moment's cause tag — so they are instant and they are
/// checkable.
struct ReviewSuggestedQuestion: Identifiable, Equatable, Sendable {
    var id: String
    var question: String
    var answer: String
    /// The habit this answer belongs to, when there is one. Carried so the card
    /// can offer the drill rather than just naming it: the review → train step
    /// of the loop otherwise exists only as Today's generic puzzle CTA, which
    /// does not know which habit the user just watched themselves break.
    var habit: Habit? = nil
    /// A move to draw on the board while this answer is uncovered, in UCI.
    ///
    /// The board is already showing the position the answer is about, one tap
    /// away from the chip, so an answer that names a move in prose and leaves the
    /// reader to find e1 and e8 for themselves is doing half the job. Carried as
    /// UCI because that is what the row stores; the arrow layer wants squares and
    /// the sentence wants SAN, and converting once at the edge keeps the two
    /// from disagreeing about which move is being discussed.
    var arrowUCI: String? = nil
}

enum ReviewSuggestedQuestions {

    /// Builds the chips each moment offers.
    ///
    /// A reinforcement is offered none. Both questions are written about a
    /// mistake — what to play instead, how to catch it next time — and put under
    /// the one card in a review that exists to say *well played* they read as an
    /// accusation.
    static func byMoment(
        moments: [Database.Moment],
        cards: [ReviewMomentCard],
        rung: Int
    ) -> [UUID: [ReviewSuggestedQuestion]] {
        let storedByID = Dictionary(moments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return cards.reduce(into: [:]) { result, card in
            guard
                let stored = storedByID[card.id],
                MomentKind(rawValue: stored.kind) != .reinforcement
            else {
                result[card.id] = []
                return
            }

            var questions: [ReviewSuggestedQuestion] = []

            if let answer = bestMoveAnswer(for: stored) {
                questions.append(
                    ReviewSuggestedQuestion(
                        id: "\(card.id)-best",
                        question: "What should I have played?",
                        answer: answer,
                        arrowUCI: stored.bestUCI.isEmpty ? nil : stored.bestUCI
                    )
                )
            }

            if let habit = TrainingCore.CauseTag(stored.causeTag).habit(rung: rung) {
                questions.append(
                    ReviewSuggestedQuestion(
                        id: "\(card.id)-habit",
                        question: "How do I catch this next time?",
                        answer: habitInstruction(habit),
                        habit: habit
                    )
                )
            }

            result[card.id] = questions
        }
    }

    /// The engine's move, with enough of its line to be reproducible on a board.
    ///
    /// A bare `"Re8 — the engine's move in this position."` is the "wins a
    /// knight" announcement in a different costume: it names the outcome and
    /// teaches nothing about how the move was found. The stored lines are what
    /// make it checkable — the variation the engine is counting on, and the
    /// reply that punishes what was actually played.
    ///
    /// `nil` when neither line survived the round trip. Silence is better than a
    /// move with no reason behind it, and the chip is simply not offered.
    static func bestMoveAnswer(for moment: Database.Moment) -> String? {
        guard
            let decoded = AnalysisPipeline.moment(from: moment),
            let best = decoded.bestSAN,
            let before = Position(fen: decoded.fenBefore)
        else { return nil }

        let bestLine = LineReplay.replay(uci: decoded.pvBest, from: before, maxPlies: 4)
            .map(\.move.san)

        var refutation: [String] = []
        if let played = LineReplay.apply(uci: decoded.playedUCI, to: before) {
            refutation = LineReplay.replay(uci: decoded.pvRefutation, from: played.position, maxPlies: 3)
                .map(\.move.san)
        }

        guard bestLine.count >= 2 || !refutation.isEmpty else { return nil }

        var clauses: [String] = []
        if bestLine.count >= 2 {
            clauses.append("\(best) — the line runs \(bestLine.joined(separator: " ")).")
        } else {
            clauses.append("\(best) was the move here.")
        }
        if !refutation.isEmpty {
            clauses.append(
                "Set the position up and play \(decoded.playedSAN) instead: "
                    + "the answer is \(refutation.joined(separator: " "))."
            )
        }
        return clauses.joined(separator: " ")
    }

    /// The move that punished what was actually played, in SAN.
    ///
    /// The first ply of the stored refutation line, replayed from the position
    /// *after* the played move. Shared with ``ReviewSelfCheck`` rather than
    /// re-derived there: the check's threat question and this card's answer are
    /// two views of the same stored line, and two decoders would eventually name
    /// two different moves.
    ///
    /// `nil` for a row written before the payload column existed, or one whose
    /// line does not replay — silence rather than a guess at what the reply was.
    static func refutationSAN(for moment: Database.Moment) -> String? {
        guard
            let decoded = AnalysisPipeline.moment(from: moment),
            let before = Position(fen: decoded.fenBefore),
            let played = LineReplay.apply(uci: decoded.playedUCI, to: before)
        else { return nil }
        return LineReplay.replay(uci: decoded.pvRefutation, from: played.position, maxPlies: 1)
            .first?
            .move
            .san
    }

    /// What a habit asks for at the board, in one sentence.
    ///
    /// ``Habit/microGoalTitle`` is a chip label — "Use the known technique" —
    /// which names the habit without saying what to do with it. A user reading
    /// this after watching themselves break the habit needs the instruction, not
    /// the slogan; the slogan stays where it belongs, on the Focus chip.
    static func habitInstruction(_ habit: Habit) -> String {
        switch habit {
        case .whatChanged:
            "Before you pick a move, say what their last move changed: what it attacks now, what it stopped defending, where that piece goes next."
        case .scanThreats:
            "Every move, list their checks, captures and threats before you look at any idea of your own."
        case .candidatesFirst:
            "Name a second and a third candidate before you calculate any of them. The first move you see is rarely the move."
        case .calcToQuiet:
            "Calculate until the position is quiet — no captures, no checks left — and judge the position you land in rather than the move that got you there."
        case .blunderCheck:
            "With the move chosen and the piece not yet released, ask what attacks the square you are putting it on, and what it stops defending behind it."
        case .kingSafety:
            "Castle before the centre opens, and count what still guards the squares in front of your king before you push one of those pawns."
        case .endgameTechnique:
            "Stop and name the position — Lucena, Philidor, opposition — then follow the method instead of calculating it out from scratch."
        case .convertCleanly:
            "Ahead on material, trade pieces rather than pawns and leave them nothing to play for."
        case .clockDiscipline:
            "Spend the time where the position genuinely branches, and move quickly where only one move makes sense."
        }
    }
}

// MARK: - Verdict

enum ReviewVerdicts {

    /// The shortest game the summariser is allowed an opinion about, in
    /// half-moves.
    ///
    /// A game resigned on move one is marked complete with no evaluations at
    /// all, and the verdict then reads "A loss with no single moment behind it
    /// … The game ran 0 moves. Nothing in this game crossed the threshold for
    /// review." — a considered assessment of a game that never happened. Three
    /// moves each is the floor at which there is anything to be wrong about.
    static let minimumPlies = 6

    /// The game's one-line verdict and the paragraph under it.
    ///
    /// `nil` rather than a hedge wherever writing one would claim more than the
    /// data supports. An unfinished or unanalysed game has nothing to sum up;
    /// and a slate whose payloads this build cannot decode would be summarised
    /// as a game with no moments in it while the filmstrip directly below it
    /// shows three, which is a contradiction on one screen.
    static func verdict(
        game: Database.Game,
        moves: [GameMove],
        moments: [Database.Moment],
        cards: [ReviewMomentCard]
    ) -> GameSummary? {
        guard
            game.analysis == .complete,
            moves.count >= minimumPlies,
            let result = game.result.flatMap(GameResult.init(rawValue:)),
            let color = game.color
        else { return nil }

        // The verdict is written about the positions the reader is looking at,
        // not about every moment the pass recorded: its closing line points at
        // them.
        let shown = Set(cards.map(\.id))
        let displayed = moments.filter { shown.contains($0.id) }.sorted { $0.ply < $1.ply }
        let decoded = displayed.compactMap(AnalysisPipeline.moment(from:))
        guard decoded.count == displayed.count else { return nil }

        return GameSummarizer.summary(
            outcome: outcome(result: result, color: color),
            accuracy: game.userAccuracy,
            // Full moves, which is how a player counts them: "43 moves" means
            // forty-three of yours and forty-three of theirs.
            moveCount: (moves.count + 1) / 2,
            moments: decoded
        )
    }

    /// The result from the reviewing player's side, which is the only side a
    /// personal history is read from.
    static func outcome(result: GameResult, color: PlayerColor) -> AnalysisKit.GameOutcome {
        if result == .draw { return .draw }
        return result.isWin(for: color) ? .win : .loss
    }
}

// MARK: - Phases

/// A run of plies belonging to one phase of the game.
struct ReviewPhaseSegment: Identifiable, Sendable, Equatable {
    var phase: Phase
    /// Position indices covered, inclusive.
    var range: ClosedRange<Int>

    var id: Int { range.lowerBound }

    var title: String {
        switch phase {
        case .opening: "Opening"
        case .middlegame: "Middlegame"
        case .endgame: "Endgame"
        }
    }
}

enum ReviewPhases {

    /// Splits the game into contiguous phase runs.
    ///
    /// `Phase.classify` is called per position with the ply of the move *about to
    /// be played* there, which is `index + 1` — the same convention
    /// `AnalysisPipeline` uses, so the segments on the graph line up with the
    /// phase every detector saw.
    static func segments(timeline: ReviewTimeline) -> [ReviewPhaseSegment] {
        guard timeline.positionCount > 1 else { return [] }

        var segments: [ReviewPhaseSegment] = []
        for index in 0..<timeline.positionCount {
            let phase = Phase.classify(position: timeline.positions[index], ply: index + 1)
            if var last = segments.last, last.phase == phase {
                last.range = last.range.lowerBound...index
                segments[segments.count - 1] = last
            } else {
                segments.append(ReviewPhaseSegment(phase: phase, range: index...index))
            }
        }
        return segments
    }
}
