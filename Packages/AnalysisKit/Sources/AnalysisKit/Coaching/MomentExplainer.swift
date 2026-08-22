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

    // MARK: - Units the reader already has

    /// Material in the words a club player counts in.
    ///
    /// "310cp" is engine vocabulary. The rest of the app converts — the move
    /// list prints "+1.2" — and the one place that explains a mistake from the
    /// user's own game should be the last to make them learn a unit.
    ///
    /// A piece is named only where the figure is close enough to that piece's
    /// own value to *be* it. A 400-point swing is a queen for a rook, not "a
    /// piece", and printing the nearest name regardless would be inventing a
    /// material fact nothing checked — the one thing this file exists to avoid.
    /// Everything between the named values counts pawns instead, which stays
    /// true of a centipawn figure whatever produced it.
    static func material(_ centipawns: Double) -> String {
        let value = abs(centipawns).rounded()
        if value >= 950 { return "a queen and more" }
        if isNear(value, PieceValues.queen) { return "a queen" }
        if isNear(value, PieceValues.rook) { return "a rook" }
        // One band for both minors: an exchange count knows what a square was
        // worth, not which of the two pieces was standing on it.
        if value >= 280, value <= 380 { return "a piece" }
        // Rook for a minor is 170 or 180, and every player calls that the exchange.
        if value >= 155, value <= 195 { return "the exchange" }
        if value < 50 { return "a fraction of a pawn" }
        let whole = max(1, Int((value / 100).rounded()))
        return whole == 1 ? "about a pawn" : "about \(spelled(whole)) pawns"
    }

    /// Within half a pawn of a named piece.
    static func isNear(_ value: Double, _ piece: Int) -> Bool {
        abs(value - Double(piece)) < Double(PieceValues.pawn) / 2
    }

    /// Where the position stood, in the words the graph above the note is
    /// already drawn in.
    ///
    /// A player reads a game as winning, better, level, worse or lost, and that
    /// vocabulary needs no key — where "0.32 in expected points" is
    /// results-theory that also collides with the rating points on the next
    /// screen. The bands are wide because the search behind them is a dozen or
    /// so plies deep: the difference between 0.30 and 0.45 does not reliably
    /// survive a re-analysis on another device, so printing either figure would
    /// promise a precision the number does not have.
    static func standing(_ score: UCIScore) -> String {
        if case .mate(let count) = score {
            return count > 0 ? "a forced mate" : "a forced mate against you"
        }
        let centipawns = score.centipawnValue()
        if centipawns >= 500 { return "winning" }
        if centipawns >= 200 { return "clearly better" }
        if centipawns >= 80 { return "slightly better" }
        if centipawns > -80 { return "level" }
        if centipawns > -200 { return "slightly worse" }
        if centipawns > -500 { return "clearly worse" }
        return "losing"
    }

    /// How far the move moved the game, as two readings rather than a number.
    ///
    /// `nil` when both sides of the move land in the same band: "from level to
    /// level" proves nothing, and the clause is better left out than filled. The
    /// size of the drop is on the screen either way — the judgment chip and the
    /// graph both carry it — so the note loses nothing by refusing to guess.
    static func swing(_ facts: MomentFacts) -> String? {
        let before = standing(facts.context.evalBefore)
        let after = standing(facts.context.evalAfter)
        guard before != after else { return nil }
        return "from \(before) to \(after)"
    }

    /// Plies as moves. A player counts their own moves, not half-moves.
    static func moves(_ plies: Int) -> String {
        let whole = max(1, (plies + 1) / 2)
        return whole == 1 ? "one move" : "\(spelled(whole)) moves"
    }

    static func spelled(_ n: Int) -> String {
        switch n {
        case 1: "one"
        case 2: "two"
        case 3: "three"
        case 4: "four"
        case 5: "five"
        default: "\(n)"
        }
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

        // Only an engine-confirmed capture is allowed to price the piece. The
        // detector will also fire on the static exchange count alone whenever
        // the move cost an inaccuracy's worth of ground, and that count cannot
        // see a pin, a check or a desperado — so on a move the engine answered
        // some other way, "the exchange there wins a piece" is a material claim
        // nothing verified. The count itself is a fact about the board and
        // stays; naming their real answer is the more useful sentence anyway,
        // because that answer is the move that was actually missed.
        guard facts.engineTakesTarget else {
            let count = "On \(square.notation) the count is \(balance)"
            guard facts.hasRefutation else { return count + "." }
            return count + ", though their strongest answer was \(facts.refutationSAN) rather than the capture."
        }

        let worth = material(evidence.magnitude)
        if evidence.flags.contains(.refutationCapturesTarget) {
            return "\(facts.refutationSAN) takes it — \(balance) on \(square.notation), which is \(worth)."
        }
        // The capture is further down their line than the first move, so the
        // move to name is the one that starts it: that is the move the player
        // had to see coming.
        return "\(facts.refutationSAN) comes first, and your \(facts.targetPiece) on \(square.notation) "
            + "goes with it — \(balance) there, which is \(worth)."
    }

    private static func threatProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard facts.hasRefutation else { return nil }
        // The detector knows the square the threat was aimed at, and naming it
        // is the difference between a note that says a punishment landed and one
        // that says where to have been looking.
        guard let square = evidence.squares.first else {
            // No magnitude here on purpose: the detector measures the threat as
            // a half-budget probe score minus a full-budget search score, which
            // is fine for ranking findings against each other and not fine to
            // print as a number the reader takes at face value.
            return "They played \(facts.refutationSAN), the move the position was already threatening."
        }
        // Clause one has already said the move ignored the threat, so repeating
        // that here would be the same sentence twice. What it has not said is
        // the thing the detector actually proved: the opponent's move was on the
        // board before this one, so the square was there to be looked at.
        return "They played \(facts.refutationSAN), and it was available before \(facts.playedSAN) too — "
            + "\(square.notation) was the square to be looking at."
    }

    private static func allowedTacticProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        guard facts.hasRefutation else { return nil }
        let steps = Array(facts.context.refutationSteps.prefix(TacticThemeClassifier.defaultHorizon))
        let resolution = LineReplay.resolutionPly(steps, for: facts.opponent)
        let motif = themePhrase(facts, evidence: evidence)

        // Clause one has already named the refuting move; repeating it here just
        // to hang a motif off it reads as a stutter, so the proof picks up where
        // that sentence left off. With no motif to name, the honest magnitude is
        // where the game went — the same reading the graph above is showing.
        var sentence: String
        if let motif {
            sentence = "The point is \(motif)"
        } else if let reading = swing(facts) {
            sentence = "It takes the position \(reading)"
        } else if let resolution {
            // No motif and no change of standing to report, but the line does
            // win material, and how fast it lands is something to check.
            return "The material comes off within \(moves(resolution))."
        } else {
            // Nothing left to prove: clause one has already named the refuting
            // move, and a sentence that only restates that it was bad is filler.
            return nil
        }
        if let resolution {
            sentence += ", and the material is off within \(moves(resolution))"
        }
        return sentence + "."
    }

    private static func missedTacticProof(_ facts: MomentFacts, evidence: MomentEvidence) -> String? {
        let steps = Array(facts.context.bestLineSteps.prefix(MissedTacticDetector.horizon))
        guard !steps.isEmpty else { return nil }
        let resolution = LineReplay.resolutionPly(steps, for: facts.mover)

        // Without a motif there is no mechanism to state, and "Re8 is the move,
        // worth 180cp" is the "wins a knight" announcement in another costume.
        // Setting the task is the honest move: the reader can do it, and the
        // note has not claimed to have taught anything it did not.
        guard let motif = themePhrase(facts, evidence: evidence) else {
            return "The engine preferred \(facts.bestSAN) here. Set the position up and find what "
                + "it hits that \(facts.playedSAN) did not."
        }

        var sentence = "\(facts.bestSAN) is \(motif), worth \(material(evidence.magnitude))"
        if let resolution {
            sentence += " within \(moves(resolution))"
        }
        return sentence + "."
    }

    private static func quietMoveProof(_ facts: MomentFacts) -> String? {
        var sentence = "\(facts.bestSAN) gives them nothing to hit back at"
        if let threat = facts.context.threatProbe?.bestMove,
            let applied = LineReplay.apply(uci: threat, to: facts.context.positionBefore) {
            sentence += " and answers their idea of \(applied.move.san)"
        }
        if let reading = swing(facts) {
            sentence += "; \(facts.playedSAN) took the position \(reading)"
        }
        return sentence + "."
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
                + "and the exchange comes out \(material(evidence.magnitude)) short."
        }
        // One voice, and a mechanism. The old branch switched to "You were on
        // 0.62 expected points before it" — a second address to the reader in
        // the same template, and an outcome with nothing to do about it.
        return "Count what is left on the board after the trade: with material to hold on to, "
            + "fewer pieces suits whoever is ahead, so it is the side behind that wants them on."
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
                ? "This ending is known: it is \(bitbaseWord(before)) either way"
                : "This ending is known exactly: \(bitbaseWord(before)) before \(facts.playedSAN), "
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
        // No named position and no exact answer, so there is no method to hand
        // over. Naming the cost and stopping would be an outcome with nothing
        // behind it; the task is at least something to do at the board.
        return "The engine wanted \(facts.bestSAN). Play both moves out from here — an ending like "
            + "this turns on technique rather than calculation, and naming the rule that separates "
            + "them is the work."
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
        case .centreNeglect:
            return "Neither centre pawn had moved, so the middle of the board was still unclaimed."
        case .disconnectedRooks:
            return "Development is not finished until the rooks can see each other along the back rank."
        default:
            // The wildcard row's own sentence is "broke an opening principle",
            // which names no principle. Rather than leave the note as an
            // assertion with no proof under it, count the thing the principle is
            // actually about.
            return "Count what is still on its starting square, then compare that with what "
                + "\(facts.bestSAN) would have brought out."
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

    /// The step, named rather than numbered.
    ///
    /// The numbers pointed at a routine the app never teaches: no lesson,
    /// onboarding card or Train concept presents the five steps as a sequence,
    /// so "Step 5" on a first-time reviewer's first note raised a question about
    /// steps 1 to 4 that nothing on the device answers. The instructions stand
    /// on their own; the numbering comes back with the lesson.
    static func stepPhrasings(_ step: StepTag) -> [String] {
        switch step {
        case .s1WhatChanged:
            [
                "Rebuild the first habit: say what their last move changed before you pick yours.",
                "Start the next move by naming what their move just did."
            ]
        case .s2ChecksCapturesThreats:
            [
                "List every check, capture and threat — theirs as well as yours.",
                "Walk their checks and captures before you settle on a move."
            ]
        case .s3Candidates:
            [
                "Find a second and a third candidate before committing to one.",
                "Widen the candidate list; the first move that comes to mind was not the move."
            ]
        case .s4Calculate:
            [
                "Calculate to the end of the line and look at the position you land in.",
                "Take the calculation one move further than felt necessary."
            ]
        case .s5BlunderCheck:
            [
                "A blunder check is what would have caught this: what attacks the square you chose?",
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
        // No figure on the gap. Praise is the one note with nothing to fix, so
        // a number here would be decoration — and the fact worth stating is the
        // one criticality is defined by: there was a real distance between the
        // best move and the next one, which is why finding it counted.
        let gap = "the position genuinely branched here — the second-best move was a clear step down"
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
        let slide = swing(facts).map { "let the position slide \($0)" } ?? "simply let the position get worse"
        switch facts.diagnosis.causeTag {
        case .positionalDrift:
            // "Nothing was threatened" is only true when the threat probe
            // actually ran. It is skipped whenever the side to move was in
            // check, and there is none at all for a ply outside the enrichment
            // window or one whose probe search was cut short — so on those
            // moments the app never looked, and a note that reports the negative
            // anyway is inventing the one fact it is least entitled to. A king
            // move out of check is exactly the case: something *was* threatening
            // the king, and nothing here checked what else.
            let opening = facts.context.threatProbe == nil
                ? "Nothing hung here"
                : "Nothing hung and nothing was threatened"
            return "\(opening): \(facts.playedSAN) \(slide), and the engine wanted \(facts.bestSAN). "
                + "Set the two positions side by side and name what changed — which squares you gave up, "
                + "which piece got worse. No engine line will hand you that answer."
        default:
            return "\(facts.playedSAN) \(slide), and no single pattern explains it. "
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
