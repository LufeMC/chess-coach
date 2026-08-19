//
//  Moment.swift
//  AnalysisKit
//

import ChessKit
import EngineKit

/// Why a moment was picked out of a game.
public enum MomentKind: String, Sendable, Codable {
    /// Something went wrong here.
    case mistake
    /// Something went right in a position where it could easily have gone wrong.
    case reinforcement
}

/// The three factors behind a moment's ranking, kept separately so the UI can
/// explain a choice and so the weights can be re-tuned without re-analysing.
public struct MomentScore: Sendable, Equatable, Codable {
    /// How much was lost, normalised: 0.30 EP is 0.6, half a point or worse is 1.
    public let severity: Double
    /// How teachable the position is — clear best move, short solution.
    public let learnability: Double
    /// How much this particular lesson matters to this player right now.
    public let relevance: Double

    public var total: Double { severity * learnability * relevance }

    public init(severity: Double, learnability: Double, relevance: Double) {
        self.severity = severity
        self.learnability = learnability
        self.relevance = relevance
    }
}

/// What the detector actually saw, kept for the copy that is written from it.
///
/// Every detector emits a ``Finding`` naming the hanging square, the size of the
/// loss, the motif and the flags that decided the subtype, and a moment that
/// keeps only the cause tag throws all of it away — leaving whatever writes the
/// coaching note strictly less to work with than the analysis already had. The
/// subtype alone is worth carrying: `CauseTag` collapses retreat, prophylaxis
/// and improvement into `forcingBias`, and every ending type into
/// `endgameTechnique`, and those are exactly the distinctions a sentence turns
/// on.
///
/// The whole value rides to disk inside the moment's opaque payload blob, so it
/// costs no column and no migration.
public struct MomentEvidence: Sendable, Equatable, Codable {
    public let detector: DetectorID
    public let subtype: FindingSubtype
    /// The finding's own squares, in the order it emitted them.
    public let squares: [Square]
    public let flags: Set<FindingFlag>
    /// Centipawns for material findings, expected points for evaluation ones.
    public let magnitude: Double
    public let themes: [TacticTheme]

    public init(
        detector: DetectorID,
        subtype: FindingSubtype,
        squares: [Square] = [],
        flags: Set<FindingFlag> = [],
        magnitude: Double = 0,
        themes: [TacticTheme] = []
    ) {
        self.detector = detector
        self.subtype = subtype
        self.squares = squares
        self.flags = flags
        self.magnitude = magnitude
        self.themes = themes
    }

    public init(_ finding: Finding) {
        self.init(
            detector: finding.detector,
            subtype: finding.subtype,
            squares: finding.squares,
            flags: finding.flags,
            magnitude: finding.magnitude,
            themes: finding.themes
        )
    }
}

/// One reviewable position, carrying everything the review screen, the drill
/// generator and the spaced-repetition scheduler need.
///
/// Self-contained by design: no identifiers into other tables, no references back
/// into the game object. A moment can be persisted, replayed and drilled on its
/// own.
public struct Moment: Sendable, Equatable, Codable {

    // MARK: Position

    /// 1-based half-move number.
    public let ply: Int
    public let phase: Phase
    public let fenBefore: String
    public let sideToMove: Piece.Color

    // MARK: Moves

    public let playedSAN: String
    public let playedUCI: String
    public let bestSAN: String?
    public let bestUCI: String?

    // MARK: Evaluation

    /// Mover-relative centipawns, mates mapped to ±10000.
    public let cpBefore: Int
    public let cpAfter: Int
    /// Mate distance in moves, when the evaluation was a mate score.
    public let mateBefore: Int?
    public let mateAfter: Int?
    public let winPctBefore: Double
    public let winPctAfter: Double
    public let deltaEP: Double
    public let judgment: Judgment

    // MARK: Lines (UCI, at most 10 plies)

    public let pvBest: [String]
    public let pvRefutation: [String]
    public let pvAlt: [String]
    public let criticalityGap: Double

    // MARK: Diagnosis

    public let detector: DetectorID?
    public let causeTag: CauseTag
    public let stepTag: StepTag
    public let modifiers: [String]
    public let secondaryTags: [String]
    public let themeTags: [TacticTheme]
    /// The primary finding's own facts. `nil` on a reinforcement, and on a
    /// moment no detector explained.
    public let evidence: MomentEvidence?

    // MARK: Coaching

    /// The coaching note for this moment, in plain English.
    ///
    /// Written here rather than by a later pass because this is the last place
    /// the facts exist: the findings and the ``MoveContext`` are both in scope
    /// when a moment is built, and neither survives the trip to the database.
    public let coachText: String?

    // MARK: Meta

    public let thinkTimeMs: Int?
    public let score: MomentScore
    public let kind: MomentKind
    /// Whether this moment can become a spaced-repetition card.
    public let srsEligible: Bool

    public var total: Double { score.total }

    /// Public so persistence layers can rebuild a stored moment, and so tests can
    /// construct one without running an engine.
    public init(
        ply: Int,
        phase: Phase,
        fenBefore: String,
        sideToMove: Piece.Color,
        playedSAN: String,
        playedUCI: String,
        bestSAN: String?,
        bestUCI: String?,
        cpBefore: Int,
        cpAfter: Int,
        mateBefore: Int? = nil,
        mateAfter: Int? = nil,
        winPctBefore: Double,
        winPctAfter: Double,
        deltaEP: Double,
        judgment: Judgment,
        pvBest: [String] = [],
        pvRefutation: [String] = [],
        pvAlt: [String] = [],
        criticalityGap: Double,
        detector: DetectorID?,
        causeTag: CauseTag,
        stepTag: StepTag,
        modifiers: [String] = [],
        secondaryTags: [String] = [],
        themeTags: [TacticTheme] = [],
        evidence: MomentEvidence? = nil,
        coachText: String? = nil,
        thinkTimeMs: Int? = nil,
        score: MomentScore,
        kind: MomentKind,
        srsEligible: Bool
    ) {
        self.ply = ply
        self.phase = phase
        self.fenBefore = fenBefore
        self.sideToMove = sideToMove
        self.playedSAN = playedSAN
        self.playedUCI = playedUCI
        self.bestSAN = bestSAN
        self.bestUCI = bestUCI
        self.cpBefore = cpBefore
        self.cpAfter = cpAfter
        self.mateBefore = mateBefore
        self.mateAfter = mateAfter
        self.winPctBefore = winPctBefore
        self.winPctAfter = winPctAfter
        self.deltaEP = deltaEP
        self.judgment = judgment
        self.pvBest = pvBest
        self.pvRefutation = pvRefutation
        self.pvAlt = pvAlt
        self.criticalityGap = criticalityGap
        self.detector = detector
        self.causeTag = causeTag
        self.stepTag = stepTag
        self.modifiers = modifiers
        self.secondaryTags = secondaryTags
        self.themeTags = themeTags
        self.evidence = evidence
        self.coachText = coachText
        self.thinkTimeMs = thinkTimeMs
        self.score = score
        self.kind = kind
        self.srsEligible = srsEligible
    }
}

/// Tuning inputs for scoring: what this player is working on right now.
public struct MomentPolicy: Sendable, Equatable {
    /// Cause tags that map to the player's weekly focus habit.
    public var weeklyFocusTags: Set<CauseTag>
    /// Cause tags that map to the skills on the player's current curriculum rung.
    public var currentRungTags: Set<CauseTag>
    /// Maximum moments per game.
    public var limit: Int
    /// Minimum plies between two selected moments, so a review does not show the
    /// same skirmish three times.
    public var minimumPlySpacing: Int
    /// How much better a second moment with an already-used cause tag must score
    /// before it displaces the variety rule.
    public var duplicateTagDominance: Double

    public init(
        weeklyFocusTags: Set<CauseTag> = [],
        currentRungTags: Set<CauseTag> = [],
        limit: Int = 3,
        minimumPlySpacing: Int = 5,
        duplicateTagDominance: Double = 3.0
    ) {
        self.weeklyFocusTags = weeklyFocusTags
        self.currentRungTags = currentRungTags
        self.limit = limit
        self.minimumPlySpacing = minimumPlySpacing
        self.duplicateTagDominance = duplicateTagDominance
    }

    public static let none = MomentPolicy()
}

/// Assembles ``Moment`` values and scores them.
public enum MomentBuilder {

    /// Expected-points loss that saturates the severity score.
    public static let severityCeiling = 0.5
    /// Criticality gap at which clarity saturates.
    public static let clarityCeiling = 0.15
    /// Clarity never drops below this: even a murky position is worth something.
    public static let clarityFloor = 0.3

    /// Every move that cost something is a candidate for review.
    public static func isMistakeCandidate(_ context: MoveContext) -> Bool {
        context.judgment >= .inaccuracy
    }

    /// A move worth praising: the position genuinely branched and the player
    /// found the engine's move anyway. Reinforcement is only meaningful where the
    /// player could plausibly have gone wrong, which is why criticality — not a
    /// low delta — is the gate.
    public static func isReinforcementCandidate(_ context: MoveContext) -> Bool {
        context.isCritical && context.playedBestMove && context.judgment == .ok
    }

    public static func make(
        context: MoveContext,
        findings: [Finding],
        mistake: Mistake,
        policy: MomentPolicy = .none,
        kind: MomentKind = .mistake
    ) -> Moment {
        let gap = context.criticalityGap
        let solutionPlies = solutionLength(context)
        let diagnosis = kind == .mistake ? mistake : praise(mistake)

        let severityInput = kind == .mistake ? context.deltaEP : gap
        let severity = min(max(severityInput, 0), severityCeiling) / severityCeiling
        let clarity = min(max(gap / clarityCeiling, clarityFloor), 1.0)
        let learnability = clarity * brevity(solutionPlies)
        let relevance = relevanceScore(causeTag: diagnosis.causeTag, context: context, policy: policy)

        // The same finding the cause tag came from, so the moment's evidence, its
        // label and its coaching note are three views of one observation.
        let primary = CauseTagger.primary(of: findings)
        // A reinforcement carries no evidence for the same reason it carries no
        // cause tag: the findings that fired on a good move describe the position,
        // not the decision, and a note written from "the piece you moved is en
        // prise" belongs to a mistake.
        let evidence = kind == .mistake ? primary.map(MomentEvidence.init) : nil

        return Moment(
            ply: context.ply,
            phase: context.phase,
            fenBefore: context.positionBefore.fen,
            sideToMove: context.mover,
            playedSAN: context.playedMove.san,
            playedUCI: context.playedUCI,
            bestSAN: context.bestMove?.san,
            bestUCI: context.bestLine.pv.first,
            cpBefore: context.evalBefore.centipawnValue(),
            cpAfter: context.evalAfter.centipawnValue(),
            mateBefore: mateDistance(context.evalBefore),
            mateAfter: mateDistance(context.evalAfter),
            winPctBefore: EvalMath.winPercent(score: context.evalBefore),
            winPctAfter: EvalMath.winPercent(score: context.evalAfter),
            deltaEP: context.deltaEP,
            judgment: context.judgment,
            pvBest: Array(context.bestLine.pv.prefix(10)),
            pvRefutation: Array((context.refutationLine?.pv ?? []).prefix(10)),
            pvAlt: Array((context.secondLine?.pv ?? []).prefix(10)),
            criticalityGap: gap,
            detector: primary?.detector,
            causeTag: diagnosis.causeTag,
            stepTag: diagnosis.stepTag,
            modifiers: diagnosis.modifiers,
            secondaryTags: diagnosis.secondaryTags,
            themeTags: Array(Set(findings.flatMap(\.themes))).sorted { $0.rawValue < $1.rawValue },
            evidence: evidence,
            coachText: MomentExplainer.note(
                findings: findings,
                context: context,
                diagnosis: diagnosis,
                kind: kind
            ),
            thinkTimeMs: context.thinkTimeMs,
            score: MomentScore(severity: severity, learnability: learnability, relevance: relevance),
            kind: kind,
            srsEligible: isSRSEligible(kind: kind, mistake: diagnosis, solutionPlies: solutionPlies, gap: gap)
        )
    }

    /// The tag a reinforcement carries instead of the one the cause tagger
    /// produced.
    ///
    /// Every value in ``CauseTag`` names something that went wrong, and every
    /// value in ``StepTag`` except S3 names a step that broke down. A
    /// reinforcement is the opposite claim — the player found the engine's move
    /// in a position that genuinely branched — so the tagger's answer for it is
    /// not a diagnosis of the move at all. It is whatever a detector happened to
    /// notice about the *position*, and several of them can fire on a good move:
    /// a piece can sit en prise behind a refutation that never comes, and an
    /// exact endgame result can change under a move the engine still ranks
    /// first. Passing that through would put "hung the piece you moved" and
    /// "blunder check" on a moment the review screen captions as praise, and
    /// hand the same words to the coach writing the copy.
    ///
    /// Clock pressure is the one overlay that survives, because it is a fact
    /// about the position rather than a verdict on the move — and finding the
    /// only move with seconds left is part of the praise. The findings
    /// themselves are not lost: they still reach the moment through `detector`
    /// and `themeTags`, which describe what was on the board.
    static func praise(_ mistake: Mistake) -> Mistake {
        Mistake(
            causeTag: .generic,
            stepTag: .s3Candidates,
            modifiers: mistake.modifiers.filter { $0 == MistakeModifier.clockPressure.rawValue },
            secondaryTags: [],
            severity: 0
        )
    }

    /// Relevance takes the **maximum** of the three tiers rather than multiplying
    /// them: a moment that is both the weekly focus and a rung skill is not twice
    /// as relevant, it is simply relevant. The guided-prompt multiplier does
    /// stack, because erring right after being prompted about that exact idea is
    /// independent evidence that the lesson has not landed.
    static func relevanceScore(causeTag: CauseTag, context: MoveContext, policy: MomentPolicy) -> Double {
        var relevance = 1.0
        if policy.currentRungTags.contains(causeTag) { relevance = max(relevance, 1.5) }
        if policy.weeklyFocusTags.contains(causeTag) { relevance = max(relevance, 2.0) }
        if context.guidedPromptShown { relevance *= 1.25 }
        return relevance
    }

    /// Short solutions are easier to learn from; long ones are engine lines.
    static func brevity(_ plies: Int) -> Double {
        if plies <= 4 { return 1.0 }
        if plies <= 6 { return 0.8 }
        return 0.6
    }

    /// How many plies the best line needs before the point is made.
    static func solutionLength(_ context: MoveContext) -> Int {
        if case .mate(let n) = context.bestLine.score, n > 0 { return max(1, 2 * n - 1) }
        if let resolution = LineReplay.resolutionPly(context.bestLineSteps, for: context.mover) {
            return resolution
        }
        return max(1, min(context.bestLine.pv.count, 10))
    }

    /// A moment earns a spaced-repetition card when it has a concrete answer:
    /// one clearly best move, a short solution, and a cause worth drilling.
    /// Knowledge-shaped causes are excluded — they belong in lessons, not cards.
    static func isSRSEligible(kind: MomentKind, mistake: Mistake, solutionPlies: Int, gap: Double) -> Bool {
        guard kind == .mistake else { return false }
        guard mistake.causeTag != .generic, mistake.causeTag != .openingPrinciple else { return false }
        guard solutionPlies <= 6 else { return false }
        return gap >= Criticality.gapThreshold || mistake.severity >= EvalMath.mistakeThreshold
    }

    static func mateDistance(_ score: UCIScore) -> Int? {
        if case .mate(let n) = score { return n }
        return nil
    }
}
