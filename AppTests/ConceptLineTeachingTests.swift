//
//  ConceptLineTeachingTests.swift
//  ChessCoachTests
//

import ChessKit
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The lesson has to contain the answers to the exercise that follows it.
///
/// `ConceptLessonView`'s own doc comment sets the standard: an opening "is
/// knowledge", and a reader "had either been told or they had not". The London
/// lesson described three moves and the exercise then asked for eight in order,
/// so the only way to pass moves four to eight was to already know the opening —
/// which is what the lesson was supposed to supply. These tests pin the line
/// down to the moves the exercise actually grades against, so a future concept
/// cannot be added that tests something it never taught.
@Suite("Concept lines are taught before they are tested")
struct ConceptLineTeachingTests {

    static var lineConcepts: [TrainingConcept] {
        TrainingConcept.catalogue.filter {
            if case .line = $0.exercise { return true }
            return false
        }
    }

    @Test("Every taught line replays from its own starting position")
    func linesReplay() throws {
        for concept in Self.lineConcepts {
            guard case let .line(fen, moves, _) = concept.exercise else { continue }
            let start = try #require(Position(fen: fen), "\(concept.id) has an unparseable FEN")
            var board = Board(position: start)
            for uci in moves {
                let origin = try #require(PuzzleConcept.origin(ofUCI: uci))
                let destination = try #require(PuzzleConcept.destination(ofUCI: uci))
                #expect(
                    board.move(pieceAt: origin, to: destination) != nil,
                    "\(concept.id): \(uci) is not legal in the line's own position"
                )
            }
        }
    }

    /// The bug this suite exists for.
    @Test("The lesson writes out every move the exercise will ask for")
    func lessonNamesEveryMove() throws {
        for concept in Self.lineConcepts {
            guard case let .line(_, moves, opponentMovesFirst) = concept.exercise else { continue }
            let listed = PuzzleConcept.lineMoves(for: concept)

            let userMoveCount = opponentMovesFirst ? moves.count / 2 : (moves.count + 1) / 2
            #expect(
                listed.count == userMoveCount,
                """
                \(concept.id) "\(concept.title)" asks the user for \(userMoveCount) moves but the \
                lesson writes out \(listed.count). Everything the exercise grades has to appear in \
                the lesson — see ConceptLessonView's doc comment.
                """
            )
            #expect(listed.allSatisfy { !$0.user.isEmpty })
            #expect(listed.map(\.number) == Array(1...listed.count))
        }
    }

    /// The move the report was actually about: the seventh London move is the
    /// c-pawn, and nothing in the prose ever said so.
    @Test("The London line names the pawn move that used to be unguessable")
    func londonNamesTheCPawn() throws {
        let london = try #require(TrainingConcept.catalogue.first { $0.id == "opening.london" })
        let listed = PuzzleConcept.lineMoves(for: london)

        #expect(listed.count == 8, "the London asks for eight moves")
        #expect(listed.map(\.user) == ["d4", "Bf4", "e3", "Nf3", "Bd3", "O-O", "c3", "Nbd2"])

        // The cue only ever covered the first three. The rest have to come from
        // the written line, so the written line is what this pins.
        let cue = london.teaching.lookFor + " " + london.teaching.idea
        #expect(
            !cue.contains("c3"),
            "if the prose ever names c3 this test is no longer the guard it was written to be"
        )
        #expect(listed[6].user == "c3", "move seven is the c-pawn, not the knight")
    }

    @Test("A concept with no line writes out nothing rather than guessing")
    func nonLineConceptsListNothing() {
        for concept in TrainingConcept.catalogue {
            if case .line = concept.exercise { continue }
            #expect(PuzzleConcept.lineMoves(for: concept).isEmpty)
        }
    }
}
