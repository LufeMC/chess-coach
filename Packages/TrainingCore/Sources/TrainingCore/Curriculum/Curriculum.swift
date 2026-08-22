//
//  Curriculum.swift
//  TrainingCore
//

import Foundation

/// One rung of the ladder.
public struct Rung: Sendable, Hashable, Codable, Identifiable {

    /// 1...4. Also the sort order.
    public var id: Int

    public var title: String

    /// The rating range this rung is aimed at. Used for the header UI and for
    /// choosing a rung from a rating; it does *not* gate advancement, which is
    /// driven entirely by ``skills``.
    public var ratingBand: ClosedRange<Int>

    public var skills: [Skill]

    public init(id: Int, title: String, ratingBand: ClosedRange<Int>, skills: [Skill]) {
        self.id = id
        self.title = title
        self.ratingBand = ratingBand
        self.skills = skills
    }

    public var requiredSkills: [Skill] { skills.filter(\.isRequired) }

    /// Habits the curriculum is actually measuring at this rung. The weekly
    /// focus is restricted to these.
    public var habits: Set<Habit> { Set(skills.compactMap(\.habit)) }
}

/// The four-rung curriculum, as data.
///
/// ## Where the numbers live
///
/// Cross-cutting constants that appear inside *logic* — the drill move budgets,
/// the streak requirement, the minimum games and days at a rung, the opening
/// composite's parameters — live in ``DomainTuning/Curriculum`` and are threaded
/// into this table. The per-skill thresholds live here, in the table itself,
/// because the table *is* their single place: a threshold and the metric it
/// applies to are meaningless apart, and hoisting thirty of them into
/// `DomainTuning` would produce two files to edit instead of one.
///
/// ## Why the ladder is short
///
/// Four rungs covering roughly 800-2000. Each is a genuine phase change in how
/// a player thinks, not a rating bracket: stop hanging pieces, then see tactics,
/// then calculate and plan, then convert and prevent. A finer ladder would be
/// more precise and much less motivating — a rung the user cannot finish inside
/// a couple of months is indistinguishable from no ladder at all.
public enum Curriculum {

    /// Builds the ladder for a given tuning.
    public static func ladder(
        tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) -> [Rung] {
        [rung1(tuning), rung2(tuning), rung3(tuning), rung4(tuning)]
    }

    /// The shipping ladder.
    public static var `default`: [Rung] { ladder() }

    public static func rung(
        _ id: Int,
        tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) -> Rung? {
        ladder(tuning: tuning).first { $0.id == id }
    }

    /// The rung whose band contains a rating. Ratings above the top band map to
    /// the top rung — there is nothing above rung 4 to be promoted to.
    public static func rung(
        forRating rating: Int,
        tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) -> Rung {
        let rungs = ladder(tuning: tuning)
        return rungs.first { $0.ratingBand.contains(rating) } ?? rungs[rungs.count - 1]
    }

    // MARK: - Rung 1

    /// Below 1000. The whole rung is one idea: **stop giving material away.**
    /// Nothing else a sub-1000 player learns survives contact with a game they
    /// lose by hanging a rook on move 14.
    private static func rung1(_ t: DomainTuning.Curriculum) -> Rung {
        Rung(
            id: 1,
            title: "Board Vision",
            ratingBand: 0...999,
            skills: [
                Skill(
                    id: "r1.hangingPieces",
                    title: "Stop hanging pieces",
                    metricKey: .hangingPiecePer100,
                    window: .lastGames(8),
                    threshold: 1.0,
                    comparison: .lessThan,
                    isRequired: true,
                    habit: .blunderCheck
                ),
                Skill(
                    id: "r1.basicMates",
                    // Stated as the thing you do, not as the notation for it:
                    // "K+Q vs K in 15" asks the reader to know that 15 counts
                    // moves, and this row is the only place the app tells them
                    // what to go and practise.
                    title: "Mate with the queen in \(t.kqkMaxMoves) moves, with the rook in \(t.krkMaxMoves)",
                    criteria: [
                        SkillCriterion(
                            metricKey: .kqkDrillCleanStreak,
                            window: .allTime,
                            threshold: Double(t.drillCleanStreakRequired),
                            comparison: .greaterThanOrEqual
                        ),
                        SkillCriterion(
                            metricKey: .krkDrillCleanStreak,
                            window: .allTime,
                            threshold: Double(t.drillCleanStreakRequired),
                            comparison: .greaterThanOrEqual
                        )
                    ],
                    isRequired: true,
                    habit: .endgameTechnique
                ),
                Skill(
                    // Not required: a legitimate early queen trade or a forced
                    // line can cost the composite through no fault of the user,
                    // and gating on it would teach opening dogma over judgement.
                    id: "r1.openingBasics",
                    title: "Sound opening habits",
                    metricKey: .openingCompositeRate,
                    window: .lastGames(8),
                    threshold: 0.75,
                    comparison: .greaterThanOrEqual,
                    isRequired: false,
                    habit: .blunderCheck
                ),
                Skill(
                    id: "r1.blunderControl",
                    title: "Blunder control",
                    criteria: [
                        SkillCriterion(
                            metricKey: .blundersPer100,
                            window: .lastGames(8),
                            threshold: 4.0,
                            comparison: .lessThan
                        )
                    ],
                    isRequired: true,
                    habit: .blunderCheck
                ),
                Skill(
                    // Split out of `r1.blunderControl`, and **not required**,
                    // because of where the number comes from. A clean retry is
                    // counted when a review card that was failed earlier in the
                    // same session is re-played and solved unaided — so the only
                    // way to produce the data is to *fail* a card first. A user
                    // with no due cards yet, or one who simply solves their
                    // reviews, never generates a single attempt, the metric
                    // stays unmeasured, and an unmeasured criterion is unmet:
                    // as a required conjunct it held rung 1 shut on evidence the
                    // user had no way to go and create. It stays on the ladder
                    // because the measurement is real and worth showing; it just
                    // cannot be a gate until something other than a failed card
                    // can feed it.
                    id: "r1.cleanRetries",
                    title: "Second tries land clean",
                    metricKey: .cleanRetryRate,
                    window: .lastGames(8),
                    threshold: 0.55,
                    comparison: .greaterThanOrEqual,
                    isRequired: false,
                    habit: .blunderCheck
                ),
                Skill(
                    id: "r1.puzzleRating",
                    // "Settled" rather than "with a settled deviation": the
                    // second criterion is a Glicko RD, and RD is a word the
                    // user has no reason to know on the first screen after
                    // calibration, where this title is shown verbatim.
                    title: "Puzzle rating 1000, and settled",
                    criteria: [
                        SkillCriterion(
                            metricKey: .puzzleRating,
                            window: .allTime,
                            threshold: 1000,
                            comparison: .greaterThanOrEqual
                        ),
                        // The RD condition is what stops a lucky streak from
                        // clearing this gate: the rating must be *believed*,
                        // not merely reached.
                        SkillCriterion(
                            metricKey: .puzzleRatingDeviation,
                            window: .allTime,
                            threshold: 100,
                            comparison: .lessThan
                        )
                    ],
                    isRequired: false,
                    habit: .calcToQuiet
                )
            ]
        )
    }

    // MARK: - Rung 2

    /// `Forks, pins, skewers, discovered attacks and back-rank mates`.
    ///
    /// An Oxford-comma-free list with "and" before the last item, because the
    /// result is read as a sentence fragment in a skill title rather than
    /// scanned as data.
    static func themeList(_ themes: [ThemeTag]) -> String {
        let nouns = themes.map(\.pluralNoun)
        guard let last = nouns.last else { return "Tactical themes" }
        guard nouns.count > 1 else { return last.capitalisedFirst }
        return (nouns.dropLast().joined(separator: ", ") + " and " + last).capitalisedFirst
    }

    /// 1000-1400. The player no longer drops pieces; now they have to *see*
    /// the tactics that are there.
    private static func rung2(_ t: DomainTuning.Curriculum) -> Rung {
        Rung(
            id: 2,
            title: "Tactical Vision",
            ratingBand: 1000...1399,
            skills: [
                Skill(
                    id: "r2.themes",
                    // The themes are named rather than summarised as "core
                    // tactical themes": a row that does not say which patterns
                    // it means is a row the user cannot go and practise, which
                    // is the only reason the sub-skills are listed at all. Built
                    // from the tuning's list so it cannot drift from the gate.
                    title: "\(Self.themeList(t.rung2Themes)) at \(t.themeRatingFloor)+",
                    criteria: t.rung2Themes.map { theme in
                        SkillCriterion(
                            metricKey: .puzzleThemeSuccess(theme, ratingFloor: t.themeRatingFloor),
                            window: .allTime,
                            threshold: 0.70,
                            comparison: .greaterThanOrEqual,
                            minimumSamples: t.themeMinimumAttempts
                        )
                    },
                    isRequired: true,
                    habit: .calcToQuiet
                ),
                Skill(
                    id: "r2.missedTactics",
                    title: "Find the tactics on the board",
                    metricKey: .missedTacticPer100,
                    window: .lastGames(10),
                    threshold: 2.5,
                    comparison: .lessThan,
                    isRequired: true,
                    habit: .candidatesFirst
                ),
                Skill(
                    id: "r2.kpk",
                    title: "King and pawn endings",
                    metricKey: .kpkDrillCleanSetStreak,
                    window: .allTime,
                    threshold: Double(t.drillCleanStreakRequired),
                    comparison: .greaterThanOrEqual,
                    isRequired: false,
                    habit: .endgameTechnique
                ),
                Skill(
                    id: "r2.threatAwareness",
                    title: "See the opponent's threats",
                    criteria: [
                        SkillCriterion(
                            metricKey: .ignoredThreatPer100,
                            window: .lastGames(10),
                            threshold: 1.5,
                            comparison: .lessThan
                        ),
                        // The guided-mode hit rate is the *deliberate* half of
                        // the same skill: the game metric says it happens, this
                        // says the user can do it on demand when prompted.
                        //
                        // The minimum sample is the part that was missing, and
                        // it is not decoration. Guided mode asks at most three
                        // questions per game, so a single answered prompt was a
                        // 100% hit rate — enough on its own to certify a
                        // *required* rung-2 skill — and two missed ones blocked
                        // the rung just as cheaply. Rung promotion picks which
                        // habit the week's focus trains, so a gate this noisy
                        // mis-aims the whole loop.
                        //
                        // Most rates on the ladder need no such rule because
                        // their denominator *is* the game count, and
                        // ``DomainTuning/Curriculum/minimumGamesAtRung`` already
                        // makes that ten. A rate counted in anything else has to
                        // say so itself: the puzzle-theme gates and the
                        // critical-moment gate do, and this one did not.
                        SkillCriterion(
                            metricKey: .guidedScanThreatsHitRate,
                            window: .lastGames(10),
                            threshold: 0.60,
                            comparison: .greaterThanOrEqual,
                            minimumSamples: t.guidedPromptMinimumSamples
                        )
                    ],
                    isRequired: true,
                    habit: .scanThreats
                ),
                Skill(
                    id: "r2.ladderStrength",
                    // "Game rating", not "ladder rating". On first launch "the
                    // ladder" is the staircase of opponent ratings, and reusing
                    // the word for the user's own rating — inside a section
                    // built of rungs — leaves the reader unable to tell which
                    // of the three the number belongs to.
                    title: "Game rating 1350 and holding",
                    criteria: [
                        SkillCriterion(
                            metricKey: .ladderRating,
                            window: .allTime,
                            threshold: 1350,
                            comparison: .greaterThanOrEqual
                        ),
                        SkillCriterion(
                            metricKey: .ladderPerformance,
                            window: .lastGames(10),
                            threshold: 1400,
                            comparison: .greaterThanOrEqual
                        )
                    ],
                    isRequired: false
                )
            ]
        )
    }

    // MARK: - Rung 3

    /// 1400-1800. Tactics are mostly seen; the errors move deeper — allowing
    /// combinations two moves further out, missing quiet moves, drifting.
    private static func rung3(_ t: DomainTuning.Curriculum) -> Rung {
        Rung(
            id: 3,
            title: "Calculation & Structure",
            ratingBand: 1400...1799,
            skills: [
                Skill(
                    id: "r3.deepTactics",
                    title: "Do not allow deep tactics",
                    metricKey: .allowedDeepTacticPer100,
                    window: .lastGames(12),
                    threshold: 1.0,
                    comparison: .lessThan,
                    isRequired: true,
                    habit: .calcToQuiet
                ),
                Skill(
                    id: "r3.criticalMoments",
                    // "Hold", not "get right": the metric counts moments the
                    // user came through without giving anything back, which is
                    // holding the position — finding the single best move is a
                    // stronger claim than the measurement supports.
                    title: "Hold the critical moments",
                    metricKey: .criticalMomentHitRate,
                    window: .lastGames(12),
                    threshold: 0.55,
                    comparison: .greaterThanOrEqual,
                    isRequired: true,
                    habit: .whatChanged,
                    minimumSamples: t.criticalMomentMinimumSamples
                ),
                Skill(
                    id: "r3.quietMoves",
                    title: "Quiet moves and steady play",
                    criteria: [
                        SkillCriterion(
                            metricKey: .missedQuietMovePer100,
                            window: .lastGames(12),
                            threshold: 2.0,
                            comparison: .lessThan
                        ),
                        SkillCriterion(
                            metricKey: .middlegameNonCriticalAccuracy,
                            window: .lastGames(12),
                            threshold: 82,
                            comparison: .greaterThanOrEqual
                        )
                    ],
                    isRequired: false,
                    habit: .candidatesFirst
                ),
                Skill(
                    id: "r3.rookEndings",
                    title: "Rook endings: Lucena and Philidor",
                    criteria: [
                        SkillCriterion(
                            metricKey: .lucenaDrillCleanStreak,
                            window: .allTime,
                            threshold: Double(t.drillCleanStreakRequired),
                            comparison: .greaterThanOrEqual
                        ),
                        SkillCriterion(
                            metricKey: .philidorDrillCleanStreak,
                            window: .allTime,
                            threshold: Double(t.drillCleanStreakRequired),
                            comparison: .greaterThanOrEqual
                        ),
                        // Knowing the positions is not the same as not throwing
                        // rook endings away, so the drill and the game evidence
                        // are both required.
                        SkillCriterion(
                            metricKey: .rookEndingResultFlipsPer8,
                            window: .lastGames(12),
                            threshold: 1,
                            comparison: .lessThanOrEqual
                        )
                    ],
                    isRequired: false,
                    habit: .endgameTechnique
                ),
                Skill(
                    id: "r3.opening",
                    title: "Accurate openings",
                    criteria: [
                        SkillCriterion(
                            metricKey: .openingAccuracy,
                            window: .lastGames(12),
                            threshold: 85,
                            comparison: .greaterThanOrEqual
                        ),
                        SkillCriterion(
                            metricKey: .openingMistakesPerGame,
                            window: .lastGames(12),
                            threshold: 0.5,
                            comparison: .lessThanOrEqual
                        )
                    ],
                    isRequired: false,
                    habit: .candidatesFirst
                ),
                Skill(
                    id: "r3.ladderStrength",
                    title: "Performing at 1750",
                    metricKey: .ladderPerformance,
                    window: .lastGames(10),
                    threshold: 1750,
                    comparison: .greaterThanOrEqual,
                    isRequired: false
                )
            ]
        )
    }

    // MARK: - Rung 4

    /// 1800-2000. Nothing here is about finding moves. It is about not letting
    /// won games get away and not letting the opponent get started.
    private static func rung4(_ t: DomainTuning.Curriculum) -> Rung {
        Rung(
            id: 4,
            title: "Conversion & Prophylaxis",
            ratingBand: 1800...2000,
            skills: [
                Skill(
                    id: "r4.prophylaxis",
                    title: "Stop ideas before they start",
                    criteria: [
                        SkillCriterion(
                            metricKey: .ignoredThreatPer100,
                            window: .lastGames(12),
                            threshold: 0.7,
                            comparison: .lessThan
                        ),
                        SkillCriterion(
                            metricKey: .prophylacticFindRate,
                            window: .lastGames(12),
                            threshold: 0.45,
                            comparison: .greaterThanOrEqual
                        )
                    ],
                    isRequired: false,
                    habit: .scanThreats
                ),
                Skill(
                    id: "r4.criticalMoments",
                    title: "Own the critical moments",
                    criteria: [
                        SkillCriterion(
                            metricKey: .criticalMomentHitRate,
                            window: .lastGames(12),
                            threshold: 0.65,
                            comparison: .greaterThanOrEqual,
                            minimumSamples: t.criticalMomentMinimumSamples
                        ),
                        // Zero, not "few". At this level an instant move in a
                        // position the engine flags as critical is never
                        // anything but a lapse of discipline.
                        SkillCriterion(
                            metricKey: .impulseAtCriticalCount,
                            window: .lastGames(12),
                            threshold: 0,
                            comparison: .lessThanOrEqual
                        )
                    ],
                    isRequired: false,
                    habit: .whatChanged
                ),
                Skill(
                    id: "r4.conversion",
                    title: "Convert winning positions",
                    criteria: [
                        SkillCriterion(
                            metricKey: .winRateFromWinningPosition,
                            window: .lastGames(20),
                            threshold: 0.85,
                            comparison: .greaterThanOrEqual
                        ),
                        SkillCriterion(
                            metricKey: .advantageSlipsPerWinningGame,
                            window: .lastGames(20),
                            threshold: 0.2,
                            comparison: .lessThanOrEqual
                        )
                    ],
                    isRequired: true,
                    habit: .convertCleanly
                ),
                Skill(
                    id: "r4.clock",
                    title: "Spend the clock where it matters",
                    criteria: [
                        SkillCriterion(
                            metricKey: .clockPressureGameRate,
                            window: .lastGames(20),
                            threshold: 0.10,
                            comparison: .lessThanOrEqual
                        ),
                        SkillCriterion(
                            metricKey: .criticalToNormalThinkTimeRatio,
                            window: .lastGames(20),
                            threshold: 2.0,
                            comparison: .greaterThanOrEqual
                        )
                    ],
                    isRequired: false,
                    habit: .clockDiscipline
                ),
                Skill(
                    id: "r4.ladderStrength",
                    title: "Performing at 1950",
                    metricKey: .ladderPerformance,
                    window: .lastGames(15),
                    threshold: 1950,
                    comparison: .greaterThanOrEqual,
                    isRequired: true
                )
            ]
        )
    }
}

// MARK: - What the ladder asks to be taught

extension Curriculum {

    /// The catalogue ids of the concepts a skill's evidence can only come from.
    ///
    /// ## Why any of this is needed
    ///
    /// Most gates measure something the user was going to do anyway: `r3.opening`
    /// moves whenever they open a game, `r2.missedTactics` whenever they miss a
    /// tactic. Three do not. A drill streak is written by one screen, that screen
    /// is reached only as a concept's exercise, and the concept catalogue serves
    /// a concept only once the user's *puzzle* rating has passed its `fromRating`
    /// — a number with no relationship to which rung they are standing on, since
    /// the rung is a counter advanced by skills and seeded from a fused
    /// playing-scale estimate. So the ladder could, and did, require Lucena of a
    /// rung-3 user the catalogue would not show Lucena to until 1400: the row was
    /// unpassable, and the weekly micro-goal built on it was arithmetic nobody
    /// could move.
    ///
    /// Naming the teacher here is what closes it. `fromRating` stays what it was
    /// written to be — the app's guess at when an idea starts being worth
    /// offering, for content nobody has asked for yet — and an explicit
    /// requirement outranks a guess.
    ///
    /// ## What belongs in it
    ///
    /// Only skills whose metric has **no other producer**. "The opening concepts
    /// teach `r3.opening`" is true as pedagogy and wrong here twice over: that
    /// gate is measured from the user's own games, so it is reachable without
    /// them, and listing them would unlock the whole opening tier for anybody who
    /// reached rung 3 — which is the spoiler the tiers exist to prevent.
    ///
    /// The ids are plain strings because the catalogue lives in the app target,
    /// above this package. `ConceptCurriculumReachabilityTests` checks both
    /// directions: that every id here resolves to a real concept, and that every
    /// drill-backed criterion on the ladder is named here by the skill that gates
    /// on it.
    public static let conceptTeachers: [Skill.ID: [String]] = [
        "r1.basicMates": ["endgame.kqk", "endgame.krk"],
        "r2.kpk": ["endgame.kpk"],
        "r3.rookEndings": ["endgame.lucena", "endgame.philidor"]
    ]

    /// Every concept the ladder has already asked this user to demonstrate.
    ///
    /// Through the rung rather than at it: calibration can place someone on rung
    /// 3 who has never been asked for the basic mates, and rung 1's rows are
    /// still on their ladder saying so. Rungs *above* are left alone — the app
    /// has not asked for them yet, so their rating floors still hold, which is
    /// the whole of the anti-spoiler property.
    ///
    /// Derived from the ladder rather than from ``conceptTeachers`` directly, so
    /// a skill dropped from the curriculum stops unlocking its teacher without
    /// anybody having to remember this table exists.
    public static func requiredConcepts(
        throughRung rung: Int,
        tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) -> Set<String> {
        var ids: Set<String> = []
        for laddered in ladder(tuning: tuning) where laddered.id <= rung {
            for skill in laddered.skills {
                ids.formUnion(conceptTeachers[skill.id] ?? [])
            }
        }
        return ids
    }
}

// MARK: - Composite helpers

extension Curriculum {

    /// Whether a game passes the rung-1 opening composite.
    ///
    /// Three sub-conditions, two of which must hold. The "two of three" rule is
    /// the point: each condition alone has legitimate exceptions (a forced line
    /// delays castling; an early trade means there are no minors left to
    /// develop), and requiring all three would fail good games and teach the
    /// user to follow rules rather than play chess.
    public static func openingCompositePasses(
        castledByMoveLimit: Bool,
        minorsDevelopedByMoveLimit: Bool,
        noOpeningMistakes: Bool,
        tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) -> Bool {
        let passes = [castledByMoveLimit, minorsDevelopedByMoveLimit, noOpeningMistakes]
            .filter { $0 }
            .count
        return passes >= tuning.openingCompositeSubConditionsRequired
    }

    /// Whether a basic-mate drill run counts as clean.
    public static func basicMateDrillIsClean(
        mate: BasicMate,
        moves: Int,
        tuning: DomainTuning.Curriculum = DomainTuning.default.curriculum
    ) -> Bool {
        switch mate {
        case .kqk: return moves <= tuning.kqkMaxMoves
        case .krk: return moves <= tuning.krkMaxMoves
        }
    }

    public enum BasicMate: String, Sendable, Hashable, CaseIterable {
        case kqk
        case krk
    }
}
