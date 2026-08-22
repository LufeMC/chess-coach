//
//  GuidedPromptMetricTests.swift
//  AppTests
//

import Database
import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The guided-prompt hit rate is the one metric whose window is counted in
/// guided games rather than in games, because a sparring game cannot produce a
/// prompt and so is not evidence about the habit either way. These tests pin
/// that, and the minimum sample that stops one lucky answer certifying a
/// required rung-2 skill.
@Suite("Guided-prompt hit rate")
struct GuidedPromptMetricTests {

    /// Only the rung-2 threat gate, so the arithmetic below stays readable: the
    /// window is what is under test, not the rest of the ladder.
    static let ladder: [Rung] = [
        Rung(
            id: 2,
            title: "Tactical Vision",
            ratingBand: 1000...1399,
            skills: [
                Skill(
                    id: "r2.threatAwareness",
                    title: "See the opponent's threats",
                    metricKey: .guidedScanThreatsHitRate,
                    window: .lastGames(10),
                    threshold: 0.60,
                    comparison: .greaterThanOrEqual,
                    isRequired: true,
                    habit: .scanThreats,
                    minimumSamples: DomainTuning.default.curriculum.guidedPromptMinimumSamples
                )
            ]
        )
    ]

    /// A game with no moves, moments or evaluations.
    ///
    /// Everything else the computer produces is read off the move list, so an
    /// empty one leaves the prompt metrics as the only survivors — which is the
    /// isolation these tests want, and the reason no engine and no database is
    /// involved.
    static func guided(
        _ habit: Habit = .scanThreats,
        hits: Int = 0,
        misses: Int = 0
    ) -> AnalysedGame {
        let game = Database.Game(mode: .guided, userColor: .white, opponentRating: 1_200)
        let prompts =
            (0..<hits).map { _ in
                GuidedPromptRecord(gameID: game.id, habit: habit.rawValue, hit: true)
            }
            + (0..<misses).map { _ in
                GuidedPromptRecord(gameID: game.id, habit: habit.rawValue, hit: false)
            }
        return AnalysedGame(game: game, guidedPrompts: prompts)
    }

    static func sparring() -> AnalysedGame {
        AnalysedGame(game: Database.Game(mode: .sparring, userColor: .white, opponentRating: 1_200))
    }

    /// - Parameter games: Most recent first, as `MetricComputer.compute` expects.
    static func hitRate(_ games: [AnalysedGame]) -> MetricValue? {
        MetricComputer.compute(games: games, counters: MetricCounters(), ladder: Self.ladder)[
            MetricAddress(key: .guidedScanThreatsHitRate, window: .lastGames(10))
        ]
    }

    static func threatSkill() -> Skill {
        Self.ladder[0].skills[0]
    }

    // MARK: - The window is counted in guided games

    @Test("Sparring games since the last guided one do not erase the metric")
    func sparringDoesNotEvictTheSample() throws {
        // Ten sparring games in a row used to fill the whole window, leaving the
        // hit rate unwritten — and `Skill.evaluate(in:)` reads a missing value
        // as unmet, so a *required* skill silently un-certified itself for
        // playing the wrong mode for a fortnight.
        let games = Array(repeating: Self.sparring(), count: 10)
            + Array(repeating: Self.guided(hits: 2), count: 4)

        let measured = try #require(Self.hitRate(games))
        #expect(measured.sampleCount == 8)
        #expect(abs(measured.value - 1.0) < 1e-12)
    }

    @Test("Interleaved sparring does not dilute the sample either")
    func interleavedSparringIsIgnored() throws {
        // Alternating modes left four guided games' worth of prompts inside a
        // ten-game window, which is below the minimum sample the gate now
        // carries — the metric would have been permanently unmeasurable for a
        // user who simply likes both modes.
        var games: [AnalysedGame] = []
        for _ in 0..<10 {
            games.append(Self.guided(hits: 1))
            games.append(Self.sparring())
        }

        let measured = try #require(Self.hitRate(games))
        #expect(measured.sampleCount == 10)
    }

    @Test("Older guided games age out once ten newer ones exist")
    func theWindowStillAgesOut() throws {
        // The window is still a window: a rate the user has moved past must not
        // be kept alive by history.
        let games = Array(repeating: Self.guided(hits: 1), count: 10)
            + Array(repeating: Self.guided(misses: 1), count: 5)

        let measured = try #require(Self.hitRate(games))
        #expect(measured.sampleCount == 10)
        #expect(abs(measured.value - 1.0) < 1e-12)
    }

    @Test("A guided game that asked about another habit is not one of the ten")
    func otherHabitsHaveTheirOwnWindow() throws {
        // Guided mode asks about whichever habit the position calls for, so a
        // run of blunder-check prompts says nothing about threat scanning and
        // must not push threat prompts out of their own window.
        let games = Array(repeating: Self.guided(.blunderCheck, hits: 3), count: 10)
            + Array(repeating: Self.guided(hits: 2, misses: 1), count: 3)

        let measured = try #require(Self.hitRate(games))
        #expect(measured.sampleCount == 9)
        #expect(abs(measured.value - 6.0 / 9.0) < 1e-12)
    }

    @Test("No guided games at all leaves the metric unwritten rather than zero")
    func noGuidedGamesIsUnmeasured() {
        // A fabricated zero would show as a failure the user cannot act on.
        #expect(Self.hitRate(Array(repeating: Self.sparring(), count: 12)) == nil)
    }

    // MARK: - The minimum sample

    @Test("One answered prompt does not certify the skill")
    func oneAnsweredPromptIsNotAHitRate() throws {
        let measured = try #require(Self.hitRate([Self.guided(hits: 1)]))
        #expect(measured.sampleCount == 1)
        #expect(abs(measured.value - 1.0) < 1e-12)

        // A perfect rate on a sample of one is not a rate. The skill must read
        // as unmeasured — "keep playing" — rather than met or failed.
        var snapshot = MetricSnapshot()
        snapshot.set(
            measured.value,
            samples: measured.sampleCount,
            for: .guidedScanThreatsHitRate,
            window: .lastGames(10)
        )

        let evaluation = Self.threatSkill().evaluate(in: snapshot)
        #expect(!evaluation.isMet)
        #expect(evaluation.failingCriteria.isEmpty)
        #expect(evaluation.unmeasuredCriteria.count == 1)
    }

    @Test("The same rate over a real sample does certify it")
    func aRealSampleCounts() throws {
        // Four guided games at two prompts each: eight, which is the bar.
        let measured = try #require(Self.hitRate(Array(repeating: Self.guided(hits: 2), count: 4)))
        #expect(measured.sampleCount == 8)

        var snapshot = MetricSnapshot()
        snapshot.set(
            measured.value,
            samples: measured.sampleCount,
            for: .guidedScanThreatsHitRate,
            window: .lastGames(10)
        )
        #expect(Self.threatSkill().evaluate(in: snapshot).isMet)
    }
}
