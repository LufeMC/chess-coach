//
//  TrainingVocabulary.swift
//  ChessCoach
//

import AnalysisKit
import Database
import Foundation
import TrainingCore

// MARK: - Why this file exists
//
// Four packages each own a slice of the same vocabulary and, correctly, none of
// them depends on the others:
//
// * `AnalysisKit.CauseTag` — a closed enum, produced by the detectors.
// * `TrainingCore.CauseTag` — an open `String` wrapper, consumed by the leak
//   analyser (open so a tag from a newer build cannot become undecodable).
// * `Database.PuzzleTheme` — the 73-bit corpus theme vocabulary.
// * `TrainingCore.ThemeTag` — the handful of themes the curriculum gates on.
//
// The app is where they meet, so the translation lives here, once, instead of
// being open-coded at each call site.

enum TrainingVocabulary {

    // MARK: Cause tags

    /// `AnalysisKit`'s closed tag as `TrainingCore`'s open one.
    static func trainingCause(_ tag: AnalysisKit.CauseTag) -> TrainingCore.CauseTag {
        TrainingCore.CauseTag(tag.rawValue)
    }

    /// A stored `Moment.causeTag` string as `TrainingCore`'s tag.
    ///
    /// Deliberately total: the column is loosely typed so a row synced from a
    /// newer build round-trips, and `TrainingCore.CauseTag` maps an unknown
    /// value to "no habit" rather than crashing.
    static func trainingCause(rawValue: String) -> TrainingCore.CauseTag {
        TrainingCore.CauseTag(rawValue)
    }

    // MARK: Themes

    /// The corpus theme a curriculum `ThemeTag` names.
    static func puzzleTheme(_ tag: ThemeTag) -> PuzzleTheme? {
        PuzzleTheme(rawValue: tag.rawValue)
    }

    /// The curriculum tag for a corpus theme.
    static func themeTag(_ theme: PuzzleTheme) -> ThemeTag {
        ThemeTag(theme.rawValue)
    }

    /// The theme a puzzle is primarily teaching.
    ///
    /// A Lichess puzzle carries a bag of themes, most of which are metadata
    /// (`short`, `middlegame`, `crushing`, `master`) rather than a tactical
    /// idea. The anti-memorization ladder needs *one* theme to search siblings
    /// by, so the tactical themes are ranked and the first match wins. Ordering
    /// is by how specific the idea is: a puzzle tagged both `fork` and `mate` is
    /// a fork puzzle that happens to end in mate.
    static func primaryTheme(of puzzle: Puzzle) -> ThemeTag {
        let themes = puzzle.themes
        for candidate in primaryThemeRanking where themes.contains(candidate) {
            return themeTag(candidate)
        }
        return themeTag(themes.themes.first ?? .middlegame)
    }

    private static let primaryThemeRanking: [PuzzleTheme] = [
        .fork, .pin, .skewer, .discoveredAttack, .doubleCheck, .deflection,
        .capturingDefender, .interference, .clearance, .attraction, .intermezzo,
        .xRayAttack, .trappedPiece, .hangingPiece, .backRankMate, .smotheredMate,
        .anastasiaMate, .arabianMate, .bodenMate, .doubleBishopMate, .dovetailMate,
        .hookMate, .killBoxMate, .vukovicMate, .promotion, .underPromotion,
        .enPassant, .zugzwang, .quietMove, .defensiveMove, .sacrifice,
        .advancedPawn, .exposedKing, .kingsideAttack, .queensideAttack,
        .attackingF2F7, .castling, .mateIn1, .mateIn2, .mateIn3, .mateIn4,
        .mateIn5, .rookEndgame, .pawnEndgame, .queenEndgame, .knightEndgame,
        .bishopEndgame, .queenRookEndgame, .endgame
    ]

    // MARK: Habits → drillable themes

    /// The corpus themes that rehearse a habit.
    ///
    /// This is the mapping the 60/40 focus bias runs on, and it is the point
    /// where "your weekly habit is blunder-check" becomes an actual SQL
    /// predicate. Two rules shaped it:
    ///
    /// 1. **Only themes that rehearse the behaviour.** A habit's drill set is
    ///    not "everything vaguely related"; it is the positions where doing the
    ///    habit is what finds the move. `blunderCheck` gets `hangingPiece` and
    ///    the tactics that punish a loose piece, not `zugzwang`.
    /// 2. **Every habit that can be drilled at all gets a non-empty set**, so
    ///    the focus bias never silently degrades to "no filter". The one
    ///    exception is `clockDiscipline`, which is a pacing habit: no puzzle
    ///    theme rehearses it, and pretending otherwise would fill the user's
    ///    week with unrelated puzzles labelled as their focus.
    static func themes(for habit: Habit) -> ThemeMask {
        switch habit {
        case .blunderCheck:
            return ThemeMask([.hangingPiece, .fork, .skewer, .pin, .capturingDefender, .trappedPiece])
        case .scanThreats:
            return ThemeMask([.defensiveMove, .discoveredAttack, .doubleCheck, .xRayAttack, .interference, .exposedKing])
        case .whatChanged:
            return ThemeMask([.discoveredAttack, .doubleCheck, .intermezzo, .deflection, .attraction])
        case .candidatesFirst:
            return ThemeMask([.quietMove, .zugzwang, .clearance, .deflection, .advancedPawn, .promotion])
        case .calcToQuiet:
            return ThemeMask([.sacrifice, .attraction, .clearance, .mateIn2, .mateIn3, .mateIn4, .long, .veryLong])
        case .kingSafety:
            return ThemeMask([.kingsideAttack, .queensideAttack, .exposedKing, .attackingF2F7, .backRankMate, .smotheredMate])
        case .endgameTechnique:
            return ThemeMask([.endgame, .rookEndgame, .pawnEndgame, .queenEndgame, .knightEndgame, .bishopEndgame, .zugzwang])
        case .convertCleanly:
            return ThemeMask([.advantage, .crushing, .endgame, .advancedPawn, .promotion])
        case .clockDiscipline:
            // No theme drills a pacing habit. An empty mask means "no filter",
            // which is the honest answer: the week's work is in the clock UI,
            // not in the puzzle queue.
            return .empty
        }
    }

    /// The rating band fresh puzzles are served from.
    static func servingBand(
        userPuzzleRating: Int,
        tuning: DomainTuning.Cards = DomainTuning.default.cards
    ) -> ClosedRange<Int> {
        let low = max(0, userPuzzleRating - tuning.freshServingBand)
        let high = userPuzzleRating + tuning.freshServingBand
        return low...high
    }

    /// The raised band the calculation set is drawn from.
    ///
    /// Deliberately **not** clamped to the corpus's own range. A clamp would
    /// quietly slide the band down onto puzzles the user can already recognise
    /// and go on calling them calculation work, which is the one failure this
    /// mode must not have; an empty band is a fact the entry point states
    /// instead. See ``SessionAssembler/calculationSet(candidates:tuning:)``.
    static func calculationBand(
        userPuzzleRating: Int,
        tuning: DomainTuning.Calculation = DomainTuning.default.calculation
    ) -> ClosedRange<Int> {
        let low = max(0, userPuzzleRating + tuning.bandOffset)
        return low...(low + tuning.bandWidth)
    }

    /// The rating band a puzzle's latency is normalised against.
    ///
    /// 200-point buckets: wide enough that a bucket accumulates samples in days
    /// rather than months, narrow enough that "the median solver time for this
    /// difficulty" still means something.
    static let latencyBandWidth = 200

    static func latencyBand(forRating rating: Int) -> Int {
        max(0, rating) / latencyBandWidth
    }
}
