//
//  PositionalFeatureTests.swift
//  ChessCoachTests
//

import ChessKit
import Testing

@testable import ChessCoach

/// Fixtures are real corpus puzzles, classified first by an independent
/// implementation and then pinned here — so the Swift detector is checked
/// against something other than itself.
///
/// Strictness is the point. A position filed under the wrong idea teaches the
/// pattern with an example that does not contain it, and the reader has no way
/// to tell. False negatives cost one exercise; false positives cost the lesson.
@Suite("Positional features")
struct PositionalFeatureTests {

    private func position(_ fen: String) -> Position {
        guard let position = Position(fen: fen) else {
            Issue.record("bad fixture FEN: \(fen)")
            return .standard
        }
        return position
    }

    @Test("An outpost is a square no enemy pawn can ever reach")
    func findsOutposts() {
        #expect(
            PositionalFeatureDetector.matches(
                .outpost, uci: "g5f6",
                in: position("r3r1k1/1b3p1p/pb4p1/1ppqP1B1/2pP4/2P1QN2/P4PPP/R4RK1 w - - 2 21")
            )
        )
    }

    @Test("A square an enemy pawn can still attack is not an outpost")
    func rejectsChasableSquares() {
        // Nd5 with a black c- and e-pawn still home: c6 or e6 chases it off.
        #expect(
            PositionalFeatureDetector.matches(
                .outpost, uci: "c3d5",
                in: position("r1bqkb1r/pppppppp/2n2n2/8/3P4/2N2N2/PPP1PPPP/R1BQKB1R w KQkq - 0 1")
            ) == false
        )
    }

    @Test("The open file is one with no pawns left on it")
    func findsOpenFiles() {
        #expect(
            PositionalFeatureDetector.matches(
                .openFile, uci: "a8g8",
                in: position("r7/pp5k/2p1R2p/2P2p2/5r2/2P5/PP3P2/5R1K b - - 0 25")
            )
        )
        // A file with a pawn still on it is half-open at best.
        #expect(
            PositionalFeatureDetector.matches(
                .openFile, uci: "a1b1",
                in: position("8/1p6/8/8/8/8/1P6/R6K w - - 0 1")
            ) == false
        )
    }

    @Test("A blockade sits in front of a pawn with no neighbours")
    func findsBlockades() {
        #expect(
            PositionalFeatureDetector.matches(
                .blockade, uci: "d6e6",
                in: position("8/5p2/3k2p1/4P1P1/4K3/8/8/8 b - - 0 45")
            )
        )
        #expect(
            PositionalFeatureDetector.matches(
                .blockade, uci: "c4a3",
                in: position("8/N2k4/1p6/6K1/2n5/8/P7/8 b - - 0 51")
            )
        )
    }

    @Test("The worst piece is the one with nowhere to go")
    func findsTheWorstPiece() {
        #expect(
            PositionalFeatureDetector.matches(
                .worstPiece, uci: "d8c7",
                in: position("1b1qr1k1/p2n1ppp/1rp2n2/3p1P2/2PP4/1P1Q1B1P/PB1N2P1/R4RK1 b - - 0 19")
            )
        )
    }

    /// Every concept that promises a corpus feature must have a detector that
    /// can actually find one, or the set has a slot it can never fill.
    @Test("Every positional concept maps to a detectable feature")
    func everyConceptIsServable() {
        for concept in TrainingConcept.positional {
            guard case .corpusFeature(let feature) = concept.exercise else {
                Issue.record("\(concept.id) is positional but serves no corpus feature")
                continue
            }
            #expect(PositionalFeature.allCases.contains(feature))
        }
    }
}
