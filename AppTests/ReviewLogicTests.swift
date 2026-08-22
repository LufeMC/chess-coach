import AnalysisKit
import BoardUI
import ChessKit
import Database
import Foundation
import Testing

@testable import ChessCoach

// The Review screen's pure layer. Everything here is reachable without a
// database, an engine or a running app, which is the whole reason it was
// factored out — the perspective conversions in particular are impossible to
// eyeball from a screenshot and trivial to assert.

private let gameID = UUID()

private func move(
    ply: Int,
    san: String = "e4",
    uci: String = "e2e4",
    classification: String? = nil,
    before: Double? = nil,
    after: Double? = nil
) -> GameMove {
    GameMove(
        gameID: gameID,
        ply: ply,
        san: san,
        uci: uci,
        classification: classification,
        winPctBefore: before,
        winPctAfter: after
    )
}

// MARK: - Perspective

@Suite("Eval track perspective")
struct EvalTrackPerspectiveTests {

    @Test("Engine scores are side-to-move relative and get flipped on Black's turn")
    func enginePerspective() {
        // ply 1 is the starting position (White to move); ply 2 is after 1.e4
        // (Black to move). A +80 there means *Black* is better by 0.8.
        let track = ReviewEvalTrack.build(
            evals: [
                PlyEval(gameID: gameID, ply: 1, pv1Cp: 30),
                PlyEval(gameID: gameID, ply: 2, pv1Cp: 80),
            ],
            moveRows: [],
            positionCount: 2
        )

        #expect(track.points.count == 2)
        #expect(track.points[0].winPercent == EvalMath.winPercent(cp: 30))
        #expect(track.points[1].winPercent == EvalMath.winPercent(cp: -80))
        // The bug this guards: without the flip the curve would rise for both
        // sides and zig-zag once per half-move.
        #expect(track.points[1].winPercent < 50)
    }

    @Test("Stored win percentages are mover-relative and get complemented for Black")
    func moverPerspective() {
        let track = ReviewEvalTrack.build(
            evals: [],
            moveRows: [
                move(ply: 1, before: 50, after: 55),  // White moved
                move(ply: 2, before: 45, after: 70),  // Black moved, now much better
            ],
            positionCount: 3
        )

        #expect(track.points.count == 3)
        #expect(track.points[0].winPercent == 50)
        #expect(track.points[1].winPercent == 55)
        // 70% for Black is 30% for White. Complement, not negation.
        #expect(track.points[2].winPercent == 30)
    }

    @Test("Engine rows win where both sources cover a position")
    func enginePreferred() {
        let track = ReviewEvalTrack.build(
            evals: [PlyEval(gameID: gameID, ply: 2, pv1Cp: 0)],
            moveRows: [move(ply: 1, before: 50, after: 90)],
            positionCount: 2
        )

        #expect(track.points[1].winPercent == EvalMath.winPercent(cp: 0))
    }

    @Test("Mate is White-relative and saturates")
    func mate() {
        let track = ReviewEvalTrack.build(
            evals: [
                PlyEval(gameID: gameID, ply: 1, pv1Cp: 0),
                // Position after one move: Black to move, mate in 3 for the side
                // to move — so mate in 3 for Black.
                PlyEval(gameID: gameID, ply: 2, pv1Mate: 3),
            ],
            moveRows: [],
            positionCount: 2
        )

        #expect(track.whiteMate[1] == -3)
        #expect(track.points[1].winPercent == 0)
    }

    @Test("Only the contiguous prefix is plotted")
    func contiguousPrefix() {
        let track = ReviewEvalTrack.build(
            evals: [
                PlyEval(gameID: gameID, ply: 1, pv1Cp: 0),
                PlyEval(gameID: gameID, ply: 2, pv1Cp: 10),
                // ply 3 (position index 2) missing — analysis was interrupted.
                PlyEval(gameID: gameID, ply: 4, pv1Cp: 20),
            ],
            moveRows: [],
            positionCount: 4
        )

        #expect(track.points.map(\.ply) == [0, 1])
        // The value is still available to the move table; it is only the *curve*
        // that stops, because interpolating across a hole would invent data.
        #expect(track.whiteWinPercent[3] != nil)
    }

    @Test("Rows past the end of the game are ignored")
    func boundsRespected() {
        let track = ReviewEvalTrack.build(
            evals: [PlyEval(gameID: gameID, ply: 9, pv1Cp: 500)],
            moveRows: [],
            positionCount: 3
        )

        #expect(track.points.isEmpty)
        #expect(track.whiteWinPercent[8] == nil)
    }

    @Test("Empty analysis produces an empty curve rather than a flat lie")
    func empty() {
        let track = ReviewEvalTrack.build(evals: [], moveRows: [move(ply: 1)], positionCount: 2)
        #expect(track.points.isEmpty)
    }
}

// MARK: - Formatting

@Suite("Eval formatting")
struct EvalFormatTests {

    @Test("Win percent → centipawns inverts EvalMath's sigmoid", arguments: [-450, -120, -50, 0, 50, 120, 450])
    func inverseRoundTrip(cp: Int) {
        let percent = EvalMath.winPercent(cp: cp)
        let recovered = ReviewEvalFormat.centipawns(fromWhiteWinPercent: percent)
        #expect(abs(recovered - Double(cp)) < 0.5)
    }

    @Test("Saturated percentages are clamped instead of returning infinity")
    func clamping() {
        #expect(ReviewEvalFormat.centipawns(fromWhiteWinPercent: 100).isFinite)
        #expect(ReviewEvalFormat.centipawns(fromWhiteWinPercent: 0).isFinite)
    }

    @Test("Pawn labels are always signed, one decimal, real minus sign")
    func pawnLabels() {
        #expect(ReviewEvalFormat.pawns(124) == "+1.2")
        #expect(ReviewEvalFormat.pawns(-240) == "\u{2212}2.4")
        #expect(ReviewEvalFormat.pawns(2) == "0.0")
    }

    /// The column already mixes a White-relative eval with a mover-relative
    /// cost; "M4" against "−M3" was a third notation to decode, and its sign was
    /// the part a player of Black reads backwards.
    @Test("Mate beats centipawns in the eval column, and names the side")
    func evalLabel() {
        #expect(ReviewEvalFormat.evalLabel(winPercent: 60, mate: 4) == "#4 W")
        #expect(ReviewEvalFormat.evalLabel(winPercent: 60, mate: -2) == "#2 B")
        #expect(ReviewEvalFormat.evalLabel(winPercent: nil, mate: nil) == nil)
    }

    @Test("Loss is mover-relative and only losses are printed")
    func loss() {
        // Mover-relative: 62% down to 20% is a real drop for whoever moved.
        let dropped = ReviewEvalFormat.moverLoss(winPctBefore: 62, winPctAfter: 20)
        #expect(dropped! < 0)
        #expect(ReviewEvalFormat.lossLabel(dropped)?.hasPrefix("\u{2212}") == true)

        // A "gain" is search noise; printing it would invite reading the column
        // as a score rather than a cost.
        #expect(ReviewEvalFormat.lossLabel(ReviewEvalFormat.moverLoss(winPctBefore: 40, winPctAfter: 60)) == nil)
        #expect(ReviewEvalFormat.lossLabel(nil) == nil)
        #expect(ReviewEvalFormat.lossLabel(-0.01) == nil)
    }

    @Test("The equal band is half a pawn wide, derived from EvalMath")
    func equalBand() {
        let expected = EvalMath.winPercent(cp: 50) - 50
        #expect(ReviewEvalFormat.equalBandWinPercent == expected)
        #expect(ReviewEvalFormat.equalBandWinPercent > 0)
    }

    /// A mate is stored as 0/100, and inverting the sigmoid there returns the
    /// clamp — about fourteen pawns. The cost column printed "−14.4" on exactly
    /// the most dramatic move of the game, which reads as a bug rather than as
    /// "this allowed mate".
    @Test("A move that changes a forced mate is named, not priced")
    func mateCost() {
        #expect(ReviewEvalFormat.cost(winPctBefore: 62, winPctAfter: 0) == .allowedMate)
        #expect(ReviewEvalFormat.cost(winPctBefore: 100, winPctAfter: 55) == .missedMate)
        // Ordinary moves are unaffected.
        #expect(ReviewEvalFormat.cost(winPctBefore: 62, winPctAfter: 20) == .pawns("\u{2212}5.1"))
        #expect(ReviewEvalFormat.cost(winPctBefore: 40, winPctAfter: 60) == nil)
        #expect(ReviewEvalFormat.cost(winPctBefore: nil, winPctAfter: 20) == nil)
    }

    /// Only a *change* counts. Keeping a mate you already had, or staying mated,
    /// cost nothing new and must not print "mate" every ply to the end.
    @Test("A mate that was already there is not charged again")
    func standingMateIsNotACost() {
        #expect(ReviewEvalFormat.cost(winPctBefore: 100, winPctAfter: 100) == nil)
        #expect(ReviewEvalFormat.cost(winPctBefore: 0, winPctAfter: 0) == nil)
    }

    @Test("The cost is short in the column and a phrase in the caption")
    func costPhrasing() {
        #expect(ReviewMoveCost.allowedMate.label == "mate")
        #expect(ReviewMoveCost.allowedMate.phrase(playedSAN: "Kf6") == "Kf6 allowed mate")
        #expect(ReviewMoveCost.missedMate.phrase(playedSAN: "Kf6") == "Kf6 gave up a forced mate")
        #expect(ReviewMoveCost.pawns("\u{2212}2.4").phrase(playedSAN: "Nxe5") == "\u{2212}2.4 after Nxe5")
    }
}

// MARK: - Reading the curve

/// The curve is drawn White-at-top and never flipped, so the words under the
/// board are the only thing that answers "am I winning?" for a player of Black.
@Suite("Eval reading")
struct EvalReadingTests {

    private func reading(cp: Int, side: Piece.Color) -> String? {
        ReviewEvalReading.phrase(
            whiteWinPercent: EvalMath.winPercent(cp: cp),
            whiteMate: nil,
            playedSide: side
        )
    }

    @Test("The same position reads opposite ways to the two players")
    func perspective() {
        #expect(reading(cp: 400, side: .white) == "You are winning")
        #expect(reading(cp: 400, side: .black) == "You are losing")
        #expect(reading(cp: -400, side: .black) == "You are winning")
    }

    /// Four bands, not three. "You are winning" at six-tenths of a pawn is an
    /// overclaim, and a reader who checks it against the position and finds it
    /// wrong stops believing the ones that are right.
    @Test("The words are graded, so a small edge is not called a win")
    func bands() {
        #expect(reading(cp: 20, side: .white) == "Level")
        #expect(reading(cp: -20, side: .white) == "Level")
        #expect(reading(cp: 90, side: .white) == "You are slightly better")
        #expect(reading(cp: 90, side: .black) == "You are slightly worse")
        #expect(reading(cp: 220, side: .white) == "You are better")
        #expect(reading(cp: 900, side: .white) == "You are winning")
    }

    @Test("Mate is named in moves and given a side")
    func mate() {
        #expect(
            ReviewEvalReading.phrase(whiteWinPercent: 100, whiteMate: 4, playedSide: .white)
                == "Mate in 4 for you"
        )
        #expect(
            ReviewEvalReading.phrase(whiteWinPercent: 100, whiteMate: 4, playedSide: .black)
                == "Mate in 4 for them"
        )
        #expect(
            ReviewEvalReading.phrase(whiteWinPercent: 0, whiteMate: -2, playedSide: .black)
                == "Mate in 2 for you"
        )
    }

    /// Nothing evaluated yet is an empty slot, never "Level" — a flat claim
    /// about a position nobody has looked at.
    @Test("An unevaluated position says nothing at all")
    func silence() {
        #expect(ReviewEvalReading.phrase(whiteWinPercent: nil, whiteMate: nil, playedSide: .white) == nil)
    }
}

// MARK: - Move rows

@Suite("Move rows")
struct MoveRowTests {

    @Test("Only judged moves earn a chip")
    func chips() {
        #expect(ReviewMoveRows.chip(for: "blunder", momentGrade: nil) == .blunder)
        #expect(ReviewMoveRows.chip(for: "mistake", momentGrade: nil) == .mistake)
        #expect(ReviewMoveRows.chip(for: "inaccuracy", momentGrade: nil) == .inaccuracy)
        // The majority of a real game: no chip at all.
        #expect(ReviewMoveRows.chip(for: "good", momentGrade: nil) == nil)
        #expect(ReviewMoveRows.chip(for: nil, momentGrade: nil) == nil)
        #expect(ReviewMoveRows.chip(for: "sensational", momentGrade: nil) == nil)
    }

    @Test("A best move is badged only where analysis also called it a moment")
    func bestNeedsAMoment() {
        #expect(ReviewMoveRows.chip(for: "best", momentGrade: nil) == nil)
        #expect(ReviewMoveRows.chip(for: "best", momentGrade: .great) == .great)
    }

    /// A proven result flip — a won ending that became a draw — is written
    /// `"good"` on the move row because its expected-points loss is tiny, while
    /// the slate grades it a mistake. The table used to show nothing at all on
    /// the one move the filmstrip was shouting about.
    @Test("A moment the row calls unremarkable still takes the slate's grade")
    func momentGradeWinsOverAnUnremarkableRow() {
        #expect(ReviewMoveRows.chip(for: "good", momentGrade: .mistake) == .mistake)
        #expect(ReviewMoveRows.chip(for: nil, momentGrade: .mistake) == .mistake)
        // The row's own verdict still wins where it made one: the two agree
        // there anyway, and the row is the per-ply source.
        #expect(ReviewMoveRows.chip(for: "blunder", momentGrade: .mistake) == .blunder)
    }

    @Test("Labels use move numbers, with the ellipsis for Black")
    func labels() {
        var track = ReviewEvalTrack()
        track.whiteWinPercent = [45: 60, 46: 20]

        let rows = ReviewMoveRows.rows(
            moveRows: [
                move(ply: 45, san: "Nf3", classification: "good", before: 55, after: 60),
                move(ply: 46, san: "Nxe5", classification: "blunder", before: 40, after: 8),
            ],
            track: track,
            momentGrades: [46: .blunder]
        )

        #expect(rows[0].label == "23. Nf3")
        #expect(rows[0].moveNumber == 23)
        #expect(rows[0].isWhite)
        #expect(rows[1].label == "23\u{2026} Nxe5")
        #expect(rows[1].moveNumber == 23)
        #expect(rows[1].isWhite == false)
    }

    @Test("Columns come from the White-relative track and the mover-relative pair")
    func columns() {
        var track = ReviewEvalTrack()
        track.whiteWinPercent = [46: EvalMath.winPercent(cp: 280)]

        let rows = ReviewMoveRows.rows(
            moveRows: [move(ply: 46, san: "Nxe5", classification: "blunder", before: 47, after: 12)],
            track: track,
            momentGrades: [46: .blunder]
        )

        #expect(rows[0].evalAfter == "+2.8")
        #expect(rows[0].loss?.hasPrefix("\u{2212}") == true)
        #expect(rows[0].chip == .blunder)
        #expect(rows[0].isMoment)
        // Tapping the row shows the position *after* the move.
        #expect(rows[0].positionIndex == 46)
    }

    @Test("An unanalysed game still produces rows, with no numbers")
    func unanalysed() {
        let rows = ReviewMoveRows.rows(
            moveRows: [move(ply: 1, san: "e4")],
            track: ReviewEvalTrack(),
            momentGrades: [:]
        )

        #expect(rows.count == 1)
        #expect(rows[0].chip == nil)
        #expect(rows[0].evalAfter == nil)
        #expect(rows[0].loss == nil)
    }

    @Test("Rows come out in board order regardless of how they arrived")
    func ordering() {
        let rows = ReviewMoveRows.rows(
            moveRows: [move(ply: 3), move(ply: 1), move(ply: 2)],
            track: ReviewEvalTrack(),
            momentGrades: [:]
        )
        #expect(rows.map(\.ply) == [1, 2, 3])
    }
}

// MARK: - Moments

@Suite("Moment cards")
struct MomentCardTests {

    private func moment(
        ply: Int,
        score: Double,
        kind: String = "mistake",
        deltaEP: Double = 0.4,
        coachText: String? = nil
    ) -> Database.Moment {
        Database.Moment(
            gameID: gameID,
            ply: ply,
            fen: "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
            kind: kind,
            causeTag: "hungMovedPiece",
            stepTag: "S5",
            playedSAN: "Nxe5",
            playedUCI: "f3e5",
            bestSAN: "O-O",
            bestUCI: "e1g1",
            deltaEP: deltaEP,
            score: score,
            coachText: coachText
        )
    }

    @Test("Three at most, chosen by score but shown in board order")
    func selection() {
        let cards = ReviewMomentCards.cards(
            moments: [
                moment(ply: 10, score: 0.2),
                moment(ply: 20, score: 0.9),
                moment(ply: 30, score: 0.5),
                moment(ply: 40, score: 0.8),
            ],
            orientation: .white,
            moveRows: []
        )

        #expect(cards.count == 3)
        #expect(cards.map(\.ply) == [20, 30, 40])
    }

    @Test("A card points the board at the position before the move")
    func positionIndex() {
        let cards = ReviewMomentCards.cards(moments: [moment(ply: 23, score: 1)], orientation: .black, moveRows: [])

        // The choice was still open at index 22; index 23 is the wreckage.
        #expect(cards[0].positionIndex == 22)
        #expect(cards[0].moveNumber == 12)
        #expect(cards[0].thumbnail.orientation == .black)
    }

    @Test("Caption carries move, grade and cost when the cost is known")
    func caption() {
        let cards = ReviewMomentCards.cards(
            moments: [moment(ply: 45, score: 1, deltaEP: 0.42)],
            orientation: .white,
            moveRows: [move(ply: 45, classification: "blunder", before: 62, after: 20)]
        )

        #expect(cards[0].caption.hasPrefix("Move 23 · Blunder · \u{2212}"))
        #expect(cards[0].classification == .blunder)
    }

    @Test("With no analysed win percentages the caption drops the cost rather than inventing one")
    func captionWithoutCost() {
        // deltaEP 0.42 is a blunder by EvalMath's thresholds; the point of the
        // test is the missing third component, not the grade.
        let cards = ReviewMomentCards.cards(moments: [moment(ply: 45, score: 1, deltaEP: 0.42)], orientation: .white, moveRows: [])
        #expect(cards[0].caption == "Move 23 · Blunder")
    }

    @Test("Reinforcement moments are Great, not Best")
    func reinforcement() {
        let cards = ReviewMomentCards.cards(
            moments: [moment(ply: 12, score: 1, kind: "reinforcement", deltaEP: 0)],
            orientation: .white,
            moveRows: []
        )
        #expect(cards[0].classification == .great)
    }

    @Test("Severity follows the same thresholds as the rest of analysis")
    func severity() {
        #expect(ReviewMomentCards.classification(for: moment(ply: 1, score: 1, deltaEP: 0.35)) == .blunder)
        #expect(ReviewMomentCards.classification(for: moment(ply: 1, score: 1, deltaEP: 0.22)) == .mistake)
        #expect(ReviewMomentCards.classification(for: moment(ply: 1, score: 1, deltaEP: 0.12)) == .inaccuracy)
    }

    /// The only way a moment is stored as a mistake with a loss this small is
    /// `AnalysisPipeline.provesResultChange`: a detector proved the result class
    /// flipped — a won king-and-pawn ending that became a draw — while the
    /// centipawn score barely moved. Grading it off the loss alone badged the one
    /// endgame error the pipeline goes out of its way to surface as "Best", in
    /// the accent colour, above a note saying the win had been thrown away.
    @Test("A mistake is never graded as praise, however small its loss")
    func provenResultFlipIsNotPraise() {
        let flip = moment(ply: 1, score: 1, deltaEP: 0.01)
        #expect(ReviewMomentCards.classification(for: flip) == .mistake)
        #expect(ReviewMomentCards.classification(for: flip) != .best)

        // The praise path is untouched: it is the *kind*, not the delta, that
        // earns it.
        let praised = moment(ply: 1, score: 1, kind: "reinforcement", deltaEP: 0.01)
        #expect(ReviewMomentCards.classification(for: praised) == .great)
    }

    @Test("The played move is marked on the thumbnail")
    func highlights() {
        let marks = ReviewMomentCards.highlights(forUCI: "f3e5")
        #expect(marks.contains { $0.square == .f3 })
        #expect(marks.contains { $0.square == .e5 })
        #expect(ReviewMomentCards.highlights(forUCI: "??").isEmpty)
    }

    @Test("A persisted coach note rides along; its absence is not an error")
    func coachText() {
        let withNote = ReviewMomentCards.cards(
            moments: [moment(ply: 5, score: 1, coachText: "You left the knight loose.")],
            orientation: .white,
            moveRows: []
        )
        #expect(withNote[0].coachText == "You left the knight loose.")

        let without = ReviewMomentCards.cards(moments: [moment(ply: 5, score: 1)], orientation: .white, moveRows: [])
        #expect(without[0].coachText == nil)
    }
}

// MARK: - Timeline

@Suite("Ply ↔ position mapping")
struct TimelineTests {

    private let opening = ["e2e4", "e7e5", "g1f3", "b8c6"]

    @Test("A game of n moves has n + 1 positions")
    func positionCount() {
        let timeline = ReviewTimeline(uci: opening)
        #expect(timeline.positionCount == 5)
        #expect(timeline.lastIndex == 4)
        #expect(timeline.positions[0].fen == Position.standard.fen)
    }

    @Test("Index k is the position with k half-moves applied")
    func indexing() {
        let timeline = ReviewTimeline(uci: opening)

        #expect(timeline.position(at: 0).sideToMove == .white)
        #expect(timeline.position(at: 1).sideToMove == .black)
        #expect(timeline.position(at: 1).piece(at: .e4)?.kind == .pawn)
        #expect(timeline.position(at: 0).piece(at: .e4) == nil)
    }

    @Test("Scrubbing past either end is clamped, not crashed")
    func clamping() {
        let timeline = ReviewTimeline(uci: opening)
        #expect(timeline.clamp(-5) == 0)
        #expect(timeline.clamp(99) == 4)
        #expect(timeline.position(at: 99).fen == timeline.positions[4].fen)
    }

    @Test("Highlights mark the move that produced the position")
    func highlights() {
        let timeline = ReviewTimeline(uci: opening)

        #expect(timeline.highlights(at: 0).isEmpty)
        let marks = timeline.highlights(at: 1)
        #expect(marks.contains { $0.square == .e2 })
        #expect(marks.contains { $0.square == .e4 })
    }

    @Test("Replay stops at the first move that will not apply, keeping the prefix")
    func truncatedReplay() {
        let timeline = ReviewTimeline(uci: ["e2e4", "e7e5", "h1h8", "g1f3"])
        #expect(timeline.positionCount == 3)
        #expect(timeline.moves.count == 2)
    }

    @Test("White moves on odd plies")
    func moverColours() {
        #expect(moverColor(forPly: 1) == .white)
        #expect(moverColor(forPly: 2) == .black)
        #expect(sideToMoveColor(atPositionIndex: 0) == .white)
        #expect(sideToMoveColor(atPositionIndex: 1) == .black)
    }

    @Test("SAN is kept as it was stored")
    func san() {
        let timeline = ReviewTimeline(
            moveRows: [move(ply: 1, san: "e4", uci: "e2e4"), move(ply: 2, san: "e5", uci: "e7e5")]
        )
        #expect(timeline.sanByPly[2] == "e5")
    }
}

// MARK: - Phases

@Suite("Phase segments")
struct PhaseSegmentTests {

    @Test("Segments are contiguous and cover every position exactly once")
    func coverage() {
        let uci = [
            "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6",
            "d2d4", "e5d4", "c3d4", "c5b4", "b1c3", "f6e4", "e1g1", "b4c3",
            "d4d5", "c3f6", "d5c6", "b7c6", "f1e1", "d7d5", "c4d5", "c6d5",
        ]
        let segments = ReviewPhases.segments(timeline: ReviewTimeline(uci: uci))

        #expect(segments.first?.range.lowerBound == 0)
        #expect(segments.last?.range.upperBound == 24)
        for (previous, next) in zip(segments, segments.dropFirst()) {
            #expect(next.range.lowerBound == previous.range.upperBound + 1)
        }
        #expect(segments.map(\.phase).first == .opening)
    }

    @Test("A game with no moves has no segments to draw")
    func empty() {
        #expect(ReviewPhases.segments(timeline: ReviewTimeline(uci: [])).isEmpty)
    }

    @Test("Titles are the words the chip shows")
    func titles() {
        #expect(ReviewPhaseSegment(phase: .opening, range: 0...1).title == "Opening")
        #expect(ReviewPhaseSegment(phase: .middlegame, range: 0...1).title == "Middlegame")
        #expect(ReviewPhaseSegment(phase: .endgame, range: 0...1).title == "Endgame")
    }
}

// MARK: - Games list rows

@Suite("Games list rows")
struct GameSummaryRowTests {

    private func game(
        result: String?,
        color: PlayerColor,
        accuracy: Double? = nil,
        analysis: AnalysisState = .complete
    ) -> Database.Game {
        Database.Game(
            mode: .sparring,
            userColor: color,
            opponentRating: 1200,
            result: result,
            userAccuracy: accuracy,
            analysisState: analysis
        )
    }

    @Test("The result is read from the user's side, not White's")
    func resultPerspective() {
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .white), opponentName: "Oscar").resultSymbol == "W")
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .black), opponentName: "Oscar").resultSymbol == "L")
        #expect(GameSummaryRow.make(game: game(result: "1/2-1/2", color: .black), opponentName: "Oscar").resultSymbol == "=")
        // Still in progress.
        #expect(GameSummaryRow.make(game: game(result: nil, color: .white), opponentName: "Oscar").resultSymbol == "·")
    }

    @Test("Accuracy is a whole percent, or a dash when there is none")
    func accuracy() {
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .white, accuracy: 82.4), opponentName: "O").accuracyText == "82%")
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .white), opponentName: "O").accuracyText == "—")
    }

    /// Thirty near-identical rows is what a month of play looks like, and the
    /// one thing the reader is hunting for — the game they never finished
    /// reviewing — was the one thing the row did not say.
    @Test("A row says how much of the game is still unreviewed, and stays quiet otherwise")
    func toReviewCaption() {
        #expect(
            GameSummaryRow.make(game: game(result: "1-0", color: .white), opponentName: "O")
                .toReviewText == nil
        )
        #expect(
            GameSummaryRow.make(game: game(result: "1-0", color: .white), opponentName: "O", toReviewCount: 2)
                .toReviewText == "2 to review"
        )
    }

    @Test("The analysis indicator shows only while something is outstanding")
    func indicator() {
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .white), opponentName: "O").analysisIndicator == nil)
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .white, analysis: .pending), opponentName: "O").analysisIndicator != nil)
        #expect(GameSummaryRow.make(game: game(result: "1-0", color: .white, analysis: .failed), opponentName: "O").analysisIndicator != nil)
    }
}
