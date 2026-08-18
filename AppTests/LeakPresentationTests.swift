import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

@Suite("Rating leak table")
struct LeakPresentationTests {

    static func leak(_ tag: CauseTag, ep: Double, count: Int, habit: Habit? = nil) -> Leak {
        Leak(
            causeTag: tag,
            habit: habit,
            weightedEPLost: ep * 40,
            epLostPerGame: ep,
            count: count,
            deltaVsPreviousWeek: 0
        )
    }

    // MARK: - Ordering
    //
    // The ordering IS the diagnosis, so it is tested independently of whatever
    // order `LeakAnalyzer` happened to hand over.

    @Test("Rows are sorted by expected points lost, descending")
    func sorting() {
        let rows = LeakTable.rows(from: [
            Self.leak(.forcingBias, ep: 0.12, count: 6),
            Self.leak(.hungMovedPiece, ep: 0.42, count: 14),
            Self.leak(.missedNewThreat, ep: 0.31, count: 11)
        ])
        #expect(rows.map(\.causeTag) == [.hungMovedPiece, .missedNewThreat, .forcingBias])
    }

    @Test("Equal magnitudes fall back to a stable tag order")
    func stableTieBreak() {
        let rows = LeakTable.rows(from: [
            Self.leak(.missedNewThreat, ep: 0.2, count: 3),
            Self.leak(.hungMovedPiece, ep: 0.2, count: 9)
        ])
        // Alphabetical by raw value, so repeated loads do not reshuffle the
        // table under the user's finger.
        #expect(rows.map(\.causeTag) == [.hungMovedPiece, .missedNewThreat])
    }

    @Test("Occurrence count does not influence the ordering")
    func countDoesNotOutrankPoints() {
        let rows = LeakTable.rows(from: [
            Self.leak(.forcingBias, ep: 0.05, count: 40),
            Self.leak(.hungMovedPiece, ep: 0.40, count: 3)
        ])
        #expect(rows.first?.causeTag == .hungMovedPiece)
    }

    // MARK: - Impact buckets

    @Test("Impact buckets are absolute, not relative to the top row")
    func impactBuckets() {
        #expect(LeakTable.impact(epLostPerGame: 0.42) == .high)
        #expect(LeakTable.impact(epLostPerGame: 0.20) == .high)
        #expect(LeakTable.impact(epLostPerGame: 0.19) == .medium)
        #expect(LeakTable.impact(epLostPerGame: 0.08) == .medium)
        #expect(LeakTable.impact(epLostPerGame: 0.07) == .low)
        #expect(LeakTable.impact(epLostPerGame: 0) == .low)
    }

    @Test("A user with only small leaks gets no HIGH IMPACT chip")
    func noFalseAlarm() {
        let rows = LeakTable.rows(from: [
            Self.leak(.forcingBias, ep: 0.03, count: 2),
            Self.leak(.hungMovedPiece, ep: 0.02, count: 1)
        ])
        #expect(rows.allSatisfy { $0.impact == .low })
        // Rule 4: a badge on 100% of rows conveys tone, not data.
        #expect(rows.allSatisfy { $0.impact.chipTitle == nil })
    }

    @Test("Low impact has no chip; high and medium do")
    func chipTitles() {
        #expect(LeakImpact.high.chipTitle == "HIGH IMPACT")
        #expect(LeakImpact.medium.chipTitle == "MEDIUM")
        #expect(LeakImpact.low.chipTitle == nil)
    }

    // MARK: - Magnitude

    @Test("Magnitude is relative to the largest leak and stays in 0...1")
    func magnitude() {
        let rows = LeakTable.rows(from: [
            Self.leak(.hungMovedPiece, ep: 0.40, count: 10),
            Self.leak(.missedNewThreat, ep: 0.20, count: 5),
            Self.leak(.forcingBias, ep: 0.00, count: 1)
        ])
        #expect(rows[0].magnitude == 1.0)
        #expect(abs(rows[1].magnitude - 0.5) < 0.0001)
        #expect(rows[2].magnitude == 0)
    }

    @Test("An empty table produces no rows and no division by zero")
    func emptyTable() {
        #expect(LeakTable.rows(from: []).isEmpty)
    }

    // MARK: - Reference values

    @Test("The typical-count reference is absent unless the data layer supplies it")
    func typicalCountOmittedByDefault() {
        let rows = LeakTable.rows(from: [Self.leak(.hungMovedPiece, ep: 0.4, count: 14)])
        // Nothing in the app computes a population baseline, and an invented
        // one would be the most misleading number on the screen.
        #expect(rows[0].typicalCount == nil)
    }

    @Test("A supplied typical count is carried through to the row")
    func typicalCountPassedThrough() {
        let rows = LeakTable.rows(
            from: [Self.leak(.hungMovedPiece, ep: 0.4, count: 14)],
            typicalCounts: [.hungMovedPiece: 4]
        )
        #expect(rows[0].typicalCount == 4)
    }

    // MARK: - Copy

    @Test("Known causes get a written name; unknown ones are de-camel-cased")
    func titles() {
        #expect(LeakTable.title(for: .hungMovedPiece) == "Hanging pieces")
        #expect(LeakTable.title(for: .missedNewThreat) == "Missed opponent threats")
        #expect(LeakTable.title(for: .forcingBias) == "Premature forcing moves")
        // A tag from a newer build must still appear in a table whose whole job
        // is completeness.
        #expect(LeakTable.title(for: CauseTag("someFutureCause")) == "Some future cause")
        #expect(LeakTable.title(for: CauseTag("")) == "Unclassified")
    }

    @Test("The habit that fixes a leak rides along with it")
    func habitCarried() {
        let rows = LeakTable.rows(from: [Self.leak(.hungMovedPiece, ep: 0.4, count: 3, habit: .blunderCheck)])
        #expect(rows[0].habit == .blunderCheck)
    }

    // MARK: - Window size

    @Test("The window label reports the games actually analysed")
    func windowSize() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let tuning = DomainTuning.default.focus

        // Twelve games inside the 21-day window, plus older ones.
        let games = (0..<30).map { index in
            GameRecord(id: "g\(index)", playedAt: now.addingTimeInterval(-Double(index) * 2 * 86_400))
        }
        // 21 days / 2 days apart = indices 0...10 inclusive.
        #expect(LeakTable.windowSize(games: games, now: now, tuning: tuning) == 11)
    }

    @Test("A quiet fortnight extends the window rather than shrinking the sample")
    func windowExtendsToMinimum() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let tuning = DomainTuning.default.focus
        // One recent game, nineteen old ones. Reporting "Last 1 game" would be
        // accurate about the fetch and useless about the analysis.
        var games = [GameRecord(id: "recent", playedAt: now.addingTimeInterval(-86_400))]
        games += (0..<19).map { index in
            GameRecord(id: "old\(index)", playedAt: now.addingTimeInterval(-Double(60 + index) * 86_400))
        }
        #expect(LeakTable.windowSize(games: games, now: now, tuning: tuning) == tuning.leakMinimumGames)
    }

    @Test("A window never claims more games than exist")
    func windowCappedByAvailability() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let games = [GameRecord(id: "a", playedAt: now), GameRecord(id: "b", playedAt: now)]
        #expect(LeakTable.windowSize(games: games, now: now) == 2)
        #expect(LeakTable.windowSize(games: [], now: now) == 0)
    }

    // MARK: - Occurrences

    @Test("Ply converts to the move number a player would say")
    func moveNumber() {
        func occurrence(ply: Int) -> LeakOccurrence {
            LeakOccurrence(
                id: UUID(), gameID: UUID(), playedAt: Date(), ply: ply,
                playedSAN: "Nf3", bestSAN: "Qe2", epLost: 0.3,
                opponentRating: 1200, result: "0-1"
            )
        }
        #expect(occurrence(ply: 1).moveNumber == 1)
        #expect(occurrence(ply: 2).moveNumber == 1)
        #expect(occurrence(ply: 3).moveNumber == 2)
        #expect(occurrence(ply: 27).moveNumber == 14)
    }
}
