//
//  DiagnosisTable.swift
//  AnalysisKit
//

import ChessKit

/// One row of the detector → diagnosis table.
///
/// The cause tag, the thinking step and the sentence the student reads all come
/// out of the same row. Keeping them together is the point: a note that says
/// "you moved the piece onto a square it could be taken on" beside a cause tag
/// that says `hungLeftPiece` is worse than no note at all, and the only way two
/// tables can never disagree is for there to be one table.
struct DiagnosisRow: Sendable {
    let detector: DetectorID
    /// `nil` matches every subtype the detector emits, and is only used where
    /// the detector's subtypes genuinely collapse to one diagnosis.
    let subtype: FindingSubtype?
    let cause: CauseTag
    let step: StepTag
    /// Alternate wordings of the "what happened" clause. One is chosen per
    /// moment by ``MomentExplainer/variant(seed:salt:count:)``, so a review with
    /// three moments of the same shape does not read as three copies of one
    /// sentence — while the same moment always produces the same sentence.
    let phrasings: [@Sendable (MomentFacts) -> String]
}

/// The published detector → cause/step table, plus the copy that goes with it.
enum DiagnosisTable {

    /// The row for a finding: an exact `(detector, subtype)` match, falling back
    /// to the detector's wildcard row.
    ///
    /// The wildcard rows exist so a subtype added to `FindingSubtype` ahead of
    /// its own row still maps somewhere rather than silently dropping out of the
    /// tagger.
    static func row(for finding: Finding) -> DiagnosisRow? {
        rows.first { $0.detector == finding.detector && $0.subtype == finding.subtype }
            ?? rows.first { $0.detector == finding.detector && $0.subtype == nil }
    }

    static let rows: [DiagnosisRow] = [

        // MARK: Hanging pieces

        DiagnosisRow(
            detector: .hangingPiece,
            subtype: .moved,
            cause: .hungMovedPiece,
            step: .s5BlunderCheck,
            phrasings: [
                { "\($0.playedSAN) put your \($0.targetPiece) on \($0.targetSquareName), where it can just be taken." },
                { "You moved your \($0.targetPiece) to \($0.targetSquareName) and left it hanging there." }
            ]
        ),
        DiagnosisRow(
            detector: .hangingPiece,
            subtype: .left,
            cause: .hungLeftPiece,
            step: .s5BlunderCheck,
            phrasings: [
                { "\($0.playedSAN) left your \($0.targetPiece) on \($0.targetSquareName) loose." },
                { "Your \($0.targetPiece) on \($0.targetSquareName) was hanging, and \($0.playedSAN) attended to something else." }
            ]
        ),

        // MARK: Threats

        DiagnosisRow(
            detector: .ignoredThreat,
            subtype: .newThreat,
            cause: .missedNewThreat,
            step: .s1WhatChanged,
            phrasings: [
                { "Their previous move created a threat against \($0.targetSquareName), and \($0.playedSAN) did nothing about it." },
                { "Something new arrived on \($0.targetSquareName) with their last move; \($0.playedSAN) carried on regardless." }
            ]
        ),
        DiagnosisRow(
            detector: .ignoredThreat,
            subtype: .standingThreat,
            cause: .ignoredStandingThreat,
            step: .s2ChecksCapturesThreats,
            phrasings: [
                { "The threat against \($0.targetSquareName) had been on the board for a move already, and \($0.playedSAN) still walked past it." },
                { "You let the same threat against \($0.targetSquareName) stand twice, and \($0.playedSAN) was the second time." }
            ]
        ),

        // MARK: Tactics allowed

        DiagnosisRow(
            detector: .allowedTactic,
            subtype: .shallow,
            cause: .allowedShallowTactic,
            step: .s5BlunderCheck,
            phrasings: [
                { "\($0.playedSAN) walked straight into \($0.refutationSAN)." },
                { "\($0.refutationSAN) was available the moment you let go of \($0.playedSAN)." }
            ]
        ),
        DiagnosisRow(
            detector: .allowedTactic,
            subtype: .deep,
            cause: .allowedDeepTactic,
            step: .s4Calculate,
            phrasings: [
                { "\($0.playedSAN) allowed a combination that opens with \($0.refutationSAN)." },
                { "The refutation of \($0.playedSAN) is a sequence rather than a single blow, starting with \($0.refutationSAN)." }
            ]
        ),

        // MARK: Tactics missed

        DiagnosisRow(
            detector: .missedTactic,
            subtype: .playedForcing,
            cause: .miscalculatedTactic,
            step: .s4Calculate,
            phrasings: [
                { "You went looking for something forcing and found \($0.playedSAN); the one that worked was \($0.bestSAN)." },
                { "\($0.playedSAN) forced matters in the wrong place — the tactic was \($0.bestSAN)." }
            ]
        ),
        DiagnosisRow(
            detector: .missedTactic,
            subtype: .playedQuiet,
            cause: .missedForcingIdea,
            step: .s2ChecksCapturesThreats,
            phrasings: [
                { "\($0.bestSAN) won material here, and \($0.playedSAN) went quietly past it." },
                { "There was something concrete in this position — \($0.bestSAN) — and \($0.playedSAN) was not it." }
            ]
        ),

        // MARK: Quiet moves missed

        DiagnosisRow(
            detector: .missedQuietMove,
            subtype: .retreat,
            cause: .forcingBias,
            step: .s3Candidates,
            phrasings: [
                { "The move was the retreat \($0.bestSAN); \($0.playedSAN) went forward instead." },
                { "Stepping back with \($0.bestSAN) was right, and \($0.playedSAN) reached for the forcing move." }
            ]
        ),
        DiagnosisRow(
            detector: .missedQuietMove,
            subtype: .prophylactic,
            cause: .forcingBias,
            step: .s3Candidates,
            phrasings: [
                { "\($0.bestSAN) would have taken their idea off the board; \($0.playedSAN) forced matters instead." },
                { "This position asked for the prophylactic \($0.bestSAN), not for \($0.playedSAN)." }
            ]
        ),
        DiagnosisRow(
            detector: .missedQuietMove,
            subtype: .improvement,
            cause: .forcingBias,
            step: .s3Candidates,
            phrasings: [
                { "\($0.bestSAN) simply improved a piece; \($0.playedSAN) reached for a check or a capture." },
                { "Nothing needed forcing here: \($0.bestSAN) was the quiet improvement and \($0.playedSAN) was not." }
            ]
        ),
        DiagnosisRow(
            detector: .missedQuietMove,
            subtype: nil,
            cause: .forcingBias,
            step: .s3Candidates,
            phrasings: [
                { "The engine wanted the quiet \($0.bestSAN); \($0.playedSAN) forced matters instead." }
            ]
        ),

        // MARK: Trades

        DiagnosisRow(
            detector: .wrongTrade,
            subtype: .losesMaterial,
            cause: .miscountedExchange,
            step: .s4Calculate,
            phrasings: [
                { "\($0.playedSAN) entered an exchange on \($0.targetSquareName) that does not come out even." },
                { "The trade \($0.playedSAN) started on \($0.targetSquareName) loses material once it plays out." }
            ]
        ),
        DiagnosisRow(
            detector: .wrongTrade,
            subtype: .badSimplification,
            cause: .planlessTrade,
            step: .s3Candidates,
            phrasings: [
                { "\($0.playedSAN) traded on \($0.targetSquareName) from a position that was already worse." },
                { "Swapping on \($0.targetSquareName) helped the side who was better, and that was not you." }
            ]
        ),

        // MARK: King safety

        DiagnosisRow(
            detector: .kingWeakeningPawnMove,
            subtype: .tacticalPunish,
            cause: .kingExposure,
            step: .s2ChecksCapturesThreats,
            phrasings: [
                { "\($0.playedSAN) loosened your own king and was punished at once." },
                { "The pawn move \($0.playedSAN) opened your king, and the punishment did not wait." }
            ]
        ),
        DiagnosisRow(
            detector: .kingWeakeningPawnMove,
            subtype: .positional,
            cause: .kingExposure,
            step: .s3Candidates,
            phrasings: [
                { "\($0.playedSAN) gave up squares around your own king for nothing in return." },
                { "The shelter in front of your king thinned out with \($0.playedSAN)." }
            ]
        ),

        // MARK: Endgames

        DiagnosisRow(
            detector: .endgameTechnique,
            subtype: .kpk,
            cause: .endgameTechnique,
            step: .kKnowledge,
            phrasings: [
                { "This is king and pawn against king, and \($0.playedSAN) changed its result." },
                { "\($0.playedSAN) is a king-and-pawn ending decided by technique rather than by calculation." }
            ]
        ),
        DiagnosisRow(
            detector: .endgameTechnique,
            subtype: .basicMate,
            cause: .endgameTechnique,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) mishandled a mate that has a method." },
                { "This is one of the basic mates, and \($0.playedSAN) drifted out of the method." }
            ]
        ),
        DiagnosisRow(
            detector: .endgameTechnique,
            subtype: .pawnEndgame,
            cause: .endgameTechnique,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) went wrong in a pure pawn ending, where a single tempo settles the result." },
                { "Pawn endings are counted, not felt, and \($0.playedSAN) got the count wrong." }
            ]
        ),
        DiagnosisRow(
            detector: .endgameTechnique,
            subtype: .rookEndgame,
            cause: .endgameTechnique,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) went wrong in a rook ending." },
                { "This is a rook ending, and \($0.playedSAN) left the known method." }
            ]
        ),
        DiagnosisRow(
            detector: .endgameTechnique,
            subtype: .otherEndgame,
            cause: .endgameTechnique,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) cost ground in the endgame." },
                { "The endgame turned with \($0.playedSAN)." }
            ]
        ),
        DiagnosisRow(
            detector: .endgameTechnique,
            subtype: nil,
            cause: .endgameTechnique,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) cost ground in the endgame." }
            ]
        ),

        // MARK: Opening principles

        DiagnosisRow(
            detector: .openingPrinciple,
            subtype: .earlyQueen,
            cause: .openingPrinciple,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) brought the queen out before the pieces behind her." },
                { "The queen went to work on her own with \($0.playedSAN)." }
            ]
        ),
        DiagnosisRow(
            detector: .openingPrinciple,
            subtype: .repeatedPieceMove,
            cause: .openingPrinciple,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) moved a piece that had already moved, while others sat at home." },
                { "One piece did all the travelling in this opening, and \($0.playedSAN) sent it out again." }
            ]
        ),
        DiagnosisRow(
            detector: .openingPrinciple,
            subtype: .delayedCastling,
            cause: .openingPrinciple,
            step: .kKnowledge,
            phrasings: [
                { "The king was still in the middle, and \($0.playedSAN) did nothing about it." },
                { "\($0.playedSAN) spent a move elsewhere with the king still uncastled." }
            ]
        ),
        DiagnosisRow(
            detector: .openingPrinciple,
            subtype: .centreNeglect,
            cause: .openingPrinciple,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) pushed a pawn on the edge while the centre was still empty." },
                { "The middle of the board was there for the taking, and \($0.playedSAN) went sideways." }
            ]
        ),
        DiagnosisRow(
            detector: .openingPrinciple,
            subtype: .disconnectedRooks,
            cause: .openingPrinciple,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) came before the back rank was cleared between the rooks." },
                { "The rooks still could not see each other when \($0.playedSAN) was played." }
            ]
        ),
        DiagnosisRow(
            detector: .openingPrinciple,
            subtype: nil,
            cause: .openingPrinciple,
            step: .kKnowledge,
            phrasings: [
                { "\($0.playedSAN) broke an opening principle." }
            ]
        )
    ]
}
