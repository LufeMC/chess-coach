//
//  MomentExplainer.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Writes the coaching note for one moment.
///
/// The note is built from the detector's own finding, not from a summary of it,
/// which is what lets it name the move that actually punished the mistake, the
/// square the piece was hanging on and the two pieces a knight forked. All of
/// that is already computed by the time a moment exists; the only thing that was
/// ever missing was a grammar to put it in.
///
/// Three clauses, in a fixed order:
///
/// 1. **What happened**, taken from ``DiagnosisTable`` so the sentence and the
///    cause tag are two projections of one row and cannot contradict each other.
/// 2. **The proof** — the refuting move in SAN, who attacks and who defends,
///    what the exchange is worth, which pieces were forked, what the bitbase
///    says. This is the clause that decides whether the note is worth reading.
/// 3. **Which thinking step broke**, from the step tag and the time modifiers.
///
/// Wording varies between two or three alternates chosen by a stable hash of the
/// position, so three moments of the same shape in one review do not read as one
/// sentence printed three times. There is no randomness and no clock anywhere in
/// it: the same moment always produces the same note.
public enum MomentExplainer {

    /// The note has to fit the review card's copy block.
    public static let characterBudget = 400

    /// The coaching note for one move.
    ///
    /// - parameter findings: Everything the detectors saw about this move.
    /// - parameter context: The move itself, with the engine's lines.
    /// - parameter diagnosis: The cause, step and modifiers already tagged for
    ///   this move — passed in rather than re-derived so the note cannot disagree
    ///   with the label the review screen prints above it.
    /// - parameter kind: Praise reads differently from a diagnosis, and the two
    ///   must never borrow each other's copy.
    public static func note(
        findings: [Finding],
        context: MoveContext,
        diagnosis: Mistake,
        kind: MomentKind = .mistake
    ) -> String {
        let facts = MomentFacts(
            context: context,
            diagnosis: diagnosis,
            kind: kind,
            evidence: kind == .mistake ? CauseTagger.primary(of: findings).map(MomentEvidence.init) : nil
        )
        return note(facts: facts)
    }

    static func note(facts: MomentFacts) -> String {
        if facts.kind == .reinforcement { return budgeted([praise(facts)]) }

        guard let evidence = facts.evidence, let row = row(for: evidence) else {
            return budgeted([unexplained(facts)])
        }

        let happened = facts.choose(row.phrasings.map { $0(facts) }, salt: "what")
        let step = stepClause(facts)

        guard let proof = proof(facts, evidence: evidence) else {
            return budgeted([happened, step])
        }

        // The step clause is the only part a player can act on tomorrow, so when
        // all three will not fit it is the proof that gives way — truncating the
        // note from the right would drop precisely the actionable half.
        let full = [happened, proof, step]
        return budgeted(full.joined(separator: " ").count <= characterBudget ? full : [happened, step])
    }

    static func row(for evidence: MomentEvidence) -> DiagnosisRow? {
        DiagnosisTable.row(for: Finding(detector: evidence.detector, subtype: evidence.subtype))
    }

    // MARK: - Clause 2: the proof

    /// The clause that names what the app actually computed.
    ///
    /// `nil` when the finding has nothing concrete behind it — an unproven claim
    /// dressed in specific-sounding language is the one failure mode worth
    /// avoiding at any cost here.
    static func proof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        switch evidence.detector {
        case .hangingPiece: hangingProof(facts, evidence: evidence)
        case .ignoredThreat: threatProof(facts, evidence: evidence)
        case .allowedTactic: allowedTacticProof(facts, evidence: evidence)
        case .missedTactic: missedTacticProof(facts, evidence: evidence)
        case .missedQuietMove: quietMoveProof(facts)
        case .wrongTrade: tradeProof(facts, evidence: evidence)
        case .kingWeakeningPawnMove: kingProof(facts, evidence: evidence)
        case .endgameTechnique: endgameProof(facts, evidence: evidence)
        case .openingPrinciple: openingProof(facts, evidence: evidence)
        case .timeError: nil
        }
    }

    private static func hangingProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard let square = evidence.squares.first else { return nil }
        let attackers = facts.occupancyAfter.attackers(of: square, by: facts.opponent).count
        let defenders = facts.occupancyAfter.attackers(of: square, by: facts.mover).count
        let balance = "\(facts.plural(attackers, "attacker")) to \(facts.plural(defenders, "defender"))"
        let worth = "\(Int(evidence.magnitude))cp"

        if facts.hasRefutation, evidence.flags.contains(.refutationCapturesTarget) {
            return "\(facts.refutationSAN) takes it — \(balance) on \(square.notation), \(worth)."
        }
        return "On \(square.notation) it is \(balance), and the exchange there wins \(worth)."
    }

    private static func threatProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard facts.hasRefutation else { return nil }
        return "They played \(facts.refutationSAN), the move the position was already threatening, "
            + "and it was worth \(facts.points(evidence.magnitude)) in expected points."
    }

    private static func allowedTacticProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard facts.hasRefutation else { return nil }
        let steps = Array(facts.context.refutationSteps.prefix(TacticThemeClassifier.defaultHorizon))
        let resolution = LineReplay.resolutionPly(steps, for: facts.opponent)
        let motif = themePhrase(facts, evidence: evidence)

        // Clause one has already named the refuting move; repeating it here just
        // to hang a motif off it reads as a stutter, so the proof picks up where
        // that sentence left off.
        var sentence = motif.map { "The point is \($0)" }
            ?? "It costs \(facts.points(facts.context.deltaEP)) in expected points"
        if let resolution {
            sentence += ", and the material is off within "
                + "\(facts.count(resolution)) \(resolution == 1 ? "ply" : "plies")"
        }
        return sentence + "."
    }

    private static func missedTacticProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        let steps = Array(facts.context.bestLineSteps.prefix(MissedTacticDetector.horizon))
        guard !steps.isEmpty else { return nil }
        let motif = themePhrase(facts, evidence: evidence)
        let resolution = LineReplay.resolutionPly(steps, for: facts.mover)

        var sentence = motif.map { "\(facts.bestSAN) is \($0)" } ?? "\(facts.bestSAN) is the move"
        sentence += ", worth \(Int(evidence.magnitude))cp"
        if let resolution {
            sentence += " by ply \(resolution)"
        }
        return sentence + "."
    }

    private static func quietMoveProof(_ facts: MomentFacts) -> String? {
        var sentence = "\(facts.bestSAN) gives them nothing to hit back at"
        if let threat = facts.context.threatProbe?.bestMove,
            let applied = LineReplay.apply(uci: threat, to: facts.context.positionBefore) {
            sentence += " and answers their idea of \(applied.move.san)"
        }
        return sentence + "; \(facts.playedSAN) cost \(facts.points(facts.context.deltaEP)) in expected points."
    }

    private static func tradeProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard let square = evidence.squares.first else { return nil }
        // The moving piece attacks the square from where it stands, so it counts
        // itself among the attackers; the useful number is the backup behind it.
        let recapturers = facts.occupancyBefore.attackers(of: square, by: facts.opponent).count
        let support = max(0, facts.occupancyBefore.attackers(of: square, by: facts.mover).count - 1)

        if evidence.subtype == .losesMaterial {
            return "Count the order on \(square.notation): \(facts.plural(recapturers, "recapture")) "
                + "against \(facts.plural(support, "piece")) of yours behind it, "
                + "and the exchange comes out \(Int(evidence.magnitude))cp short."
        }
        let standing = EvalMath.expectedPoints(score: facts.context.evalBefore)
        return "You were on \(facts.points(standing)) expected points before it, and every trade from there "
            + "suits the side with more to hold on to."
    }

    private static func kingProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard let start = evidence.squares.first,
            let king = facts.occupancyAfter.kingSquare(of: facts.mover)
        else { return nil }

        let zone = PositionUtilities.kingZone(of: facts.mover, in: facts.context.positionAfter)
        let coveredBefore = Set(facts.occupancyBefore.attackedSquares(from: start))
        let coveredAfter = Set(facts.occupancyAfter.attackedSquares(from: facts.context.playedMove.end))
        let abandoned = coveredBefore.subtracting(coveredAfter).intersection(zone)
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.notation)

        var sentence = "Your king is on \(king.notation)"
        if !abandoned.isEmpty {
            sentence += " and nothing covers \(list(abandoned)) any more"
        }
        if evidence.subtype == .tacticalPunish, facts.hasRefutation {
            sentence += "; \(facts.refutationSAN) came straight at it"
        }
        return sentence + "."
    }

    private static func endgameProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        if evidence.flags.contains(.exactBitbase),
            let before = KPKBitbase.probe(position: facts.context.positionBefore),
            let after = KPKBitbase.probe(position: facts.context.positionAfter) {
            // The bitbase answers "does the pawn's owner win", which is not the
            // same question as "was this good for you" whenever the defender is
            // the one to move.
            let verdict = before == after
                ? "The bitbase says this is \(bitbaseWord(before)) either way"
                : "The bitbase is exact here: \(bitbaseWord(before)) before \(facts.playedSAN), "
                    + "\(bitbaseWord(after)) after it"
            return verdict + ", and \(facts.bestSAN) held the other result."
        }

        if evidence.flags.contains(.lucenaAvailable) {
            return "This is the Lucena position: the rook builds a bridge on the fourth rank "
                + "and the king walks out. \(facts.bestSAN) was the first move of it."
        }
        if evidence.flags.contains(.philidorAvailable) {
            return "This is the Philidor position: the rook holds the third rank until the pawn "
                + "advances, then goes behind it. \(facts.bestSAN) kept it."
        }
        if evidence.flags.contains(.resultClassFlip) {
            return "The result changed with this move — \(facts.bestSAN) was the way to keep it."
        }
        return "\(facts.bestSAN) was the move, and \(facts.playedSAN) "
            + "cost \(facts.points(facts.context.deltaEP)) in expected points."
    }

    private static func openingProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        let home = undevelopedMinors(facts)
        switch evidence.subtype {
        case .earlyQueen:
            return "That left \(facts.plural(home, "minor piece")) still at home, "
                + "and \(facts.bestSAN) was the developing move."
        case .repeatedPieceMove:
            return "That leaves \(facts.plural(home, "minor piece")) on their starting squares."
        case .delayedCastling:
            let king = facts.occupancyBefore.kingSquare(of: facts.mover)?.notation ?? "the centre"
            return "The king is still on \(king) on move \(facts.context.positionBefore.clock.fullmoves), "
                + "with a central file open."
        default:
            return nil
        }
    }

    static func undevelopedMinors(_ facts: MomentFacts) -> Int {
        facts.occupancyBefore
            .pieces(of: facts.mover)
            .filter { ($0.kind == .knight || $0.kind == .bishop) && $0.square.relativeRank(for: facts.mover) == 1 }
            .count
    }

    static func bitbaseWord(_ outcome: KPKOutcome) -> String {
        outcome == .win ? "a win for the pawn" : "a draw"
    }

    // MARK: Themes

    /// Names the motif and the pieces it acts on.
    ///
    /// `nil` for `.unknownTactic` and for a motif whose squares did not survive:
    /// "a tactic was available" adds nothing the cause tag has not already said.
    static func themePhrase(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard let theme = evidence.themes.first else { return nil }
        let position = facts.themePosition
        // The finding leads with the key move's own two squares; the motif's
        // geometry is appended after them.
        let squares = Array(evidence.squares.dropFirst(2))

        func named(_ square: Square) -> String {
            "the \(facts.pieceName(at: square, in: position)) on \(square.notation)"
        }

        switch theme {
        case .fork:
            guard squares.count >= 2 else { return "a fork" }
            return "a fork hitting \(list(squares.prefix(3).map(named)))"
        case .pin:
            guard squares.count >= 2 else { return "a pin" }
            return "a pin — \(named(squares[0])) cannot move with \(named(squares[1])) behind it"
        case .skewer:
            guard squares.count >= 2 else { return "a skewer" }
            return "a skewer through \(named(squares[0])) to \(named(squares[1]))"
        case .discoveredAttack:
            guard let target = squares.first else { return "a discovered attack" }
            return "a discovered attack on \(named(target))"
        case .removalOfDefender:
            guard let exposed = squares.first else { return "removal of the defender" }
            return "removal of the defender, leaving \(named(exposed)) unguarded"
        case .trappedPiece:
            guard let trapped = squares.first else { return "a trapped piece" }
            return "\(named(trapped)) has nowhere to run"
        case .backRankMate:
            guard let square = squares.first else { return "a back-rank mate" }
            return "a back-rank mate on \(square.notation)"
        case .mateThreat:
            guard let square = squares.first else { return "a forced mate" }
            return "a forced mate landing on \(square.notation)"
        case .unknownTactic:
            return nil
        }
    }

    static func list(_ items: some Collection<String>) -> String {
        let parts = Array(items)
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    // MARK: - Clause 3: the thinking step

    static func stepClause(_ facts: MomentFacts) -> String {
        let modifiers = Set(facts.diagnosis.modifiers)
        let impulse = modifiers.contains(MistakeModifier.impulse.rawValue)
        let deepMiss = modifiers.contains(MistakeModifier.deepMiss.rawValue)
        let clock = modifiers.contains(MistakeModifier.clockPressure.rawValue)

        var prefix = ""
        if impulse, clock {
            prefix = "You moved fast with the clock nearly gone. "
        } else if impulse {
            prefix = "You moved fast in a position that deserved the time. "
        } else if deepMiss {
            prefix = "You thought for a long time here and still walked into it. "
        } else if clock {
            prefix = "There was very little time left on the clock. "
        } else if modifiers.contains(MistakeModifier.flagged.rawValue) {
            prefix = "The clock ran out on this move. "
        }

        return prefix + facts.choose(stepPhrasings(facts.diagnosis.stepTag), salt: "step")
    }

    static func stepPhrasings(_ step: StepTag) -> [String] {
        switch step {
        case .s1WhatChanged:
            [
                "Step 1 is the one to rebuild: say what their last move changed before you pick yours.",
                "Start the next move by naming what their move just did."
            ]
        case .s2ChecksCapturesThreats:
            [
                "Step 2: list every check, capture and threat — theirs as well as yours.",
                "Walk their checks and captures before you settle on a move."
            ]
        case .s3Candidates:
            [
                "Step 3: find a second and a third candidate before committing to one.",
                "Widen the candidate list; the first move that comes to mind was not the move."
            ]
        case .s4Calculate:
            [
                "Step 4: calculate to the end of the line and look at the position you land in.",
                "Take the calculation one move further than felt necessary."
            ]
        case .s5BlunderCheck:
            [
                "Step 5, the blunder check, is what would have caught this.",
                "One blunder check before releasing the piece is all this needed."
            ]
        case .kKnowledge:
            [
                "This is knowledge rather than process — learn the method away from the board.",
                "Nothing here was calculable; the method is something to study."
            ]
        }
    }

    // MARK: - The honest limits

    /// A move the player got right.
    ///
    /// Never a question, and never a diagnosis. The shipped copy handed praise
    /// moments the default "what did this move allow in return?", which reads as
    /// an accusation on the one moment in a review that is not one.
    static func praise(_ facts: MomentFacts) -> String {
        let clock = facts.diagnosis.modifiers.contains(MistakeModifier.clockPressure.rawValue)
        let opening = clock
            ? "With the clock nearly gone you still found \(facts.playedSAN), the engine's first choice"
            : "\(facts.playedSAN) was the engine's first choice"
        let gap = "the position genuinely branched here — the next-best line was "
            + "\(facts.points(facts.context.criticalityGap)) of a point worse"
        let ask = facts.choose(
            [
                "Say out loud what you checked before you played it; that is the routine to keep.",
                "Note what made you look at this move — that is the habit worth repeating."
            ],
            salt: "praise"
        )
        return "\(opening), and \(gap). \(ask)"
    }

    /// A move no detector explained.
    ///
    /// `positionalDrift` and the generic fallback are the two tags the data
    /// cannot support a specific sentence for: nothing hung, nothing was
    /// threatened, the position simply got worse. Inventing a plan here would be
    /// inventing it — so the note sets a task the player can actually do on a
    /// board instead.
    static func unexplained(_ facts: MomentFacts) -> String {
        let cost = facts.points(facts.context.deltaEP)
        switch facts.diagnosis.causeTag {
        case .positionalDrift:
            return "Nothing hung and nothing was threatened: \(facts.playedSAN) simply let the position "
                + "get \(cost) of a point worse, and the engine wanted \(facts.bestSAN). "
                + "Set the two positions side by side and name what changed — which squares you gave up, "
                + "which piece got worse. No engine line will hand you that answer."
        default:
            return "\(facts.playedSAN) cost \(cost) of a point and no single pattern explains it. "
                + "Put the position before the move next to the position after it and name the difference "
                + "before you look at \(facts.bestSAN)."
        }
    }

    // MARK: - Budget

    static func budgeted(_ clauses: [String]) -> String {
        truncate(clauses.filter { !$0.isEmpty }.joined(separator: " "), to: characterBudget)
    }

    /// Truncates on a word boundary so a clipped sentence still reads.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }

        let clipped = String(text.prefix(limit - 1))
        if let space = clipped.lastIndex(of: " ") {
            return String(clipped[clipped.startIndex..<space]) + "…"
        }
        return clipped + "…"
    }
}
