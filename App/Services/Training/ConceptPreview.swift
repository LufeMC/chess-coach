//
//  ConceptPreview.swift
//  ChessCoach
//

import ChessKit

extension TrainingConcept {

    /// The board a lesson draws, and which way up to draw it.
    ///
    /// ## Why this is derived rather than authored
    ///
    /// A lesson used to be prose and notation only. The London card named d4,
    /// Bf4 and e3 — and then the exercise asked for eight moves including two
    /// knights the card never mentioned, so the first thing the reader met was
    /// a move nobody had told them about.
    ///
    /// Writing the missing pieces into the prose would have fixed that one
    /// concept and left the next one free to drift the same way. This is read
    /// off the exercise instead: for an opening it is the position the moves
    /// actually reach, so the picture and the practice cannot disagree.
    ///
    /// Nil for a positional idea, whose position is searched for in the corpus
    /// at run time and so has nothing fixed to draw.
    var preview: (position: Position, orientation: Piece.Color)? {
        switch exercise {
        case let .line(fen, moves, opponentMovesFirst):
            guard let start = Position(fen: fen) else { return nil }

            var board = Board(position: start)
            for uci in moves {
                guard PuzzleSolveMachine.move(uci: uci, on: &board) != nil else { return nil }
            }
            // Shown from the side doing the learning, which is the opponent's
            // side of the first move when they move first.
            let solver = opponentMovesFirst ? start.sideToMove.opposite : start.sideToMove
            return (board.position, solver)

        case let .drill(kind):
            guard let drill = EndgameDrill.drills(kind: kind).first,
                let position = Position(fen: drill.fen)
            else { return nil }
            return (position, position.sideToMove)

        case .corpusFeature:
            return nil
        }
    }

    /// What the drawn position *is*, since it means something different in each
    /// family: an opening shows a destination, an endgame a starting point.
    var previewCaption: String? {
        switch exercise {
        case .line: "Where these moves take you."
        case .drill: "You start here."
        case .corpusFeature: nil
        }
    }
}
