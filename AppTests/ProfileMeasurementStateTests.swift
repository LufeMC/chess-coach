import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

@Suite("Honest empty states")
struct ProfileMeasurementStateTests {

    @Test("A missing metric is 'nothing yet', not a zero")
    func nothingYet() {
        let state = ProfileMeasurementState.forSamples(have: 0, need: 8)
        #expect(state == .nothingYet(noun: "games"))
        #expect(state.message == "No games recorded yet")
        #expect(!state.isMeasured)
    }

    @Test("A partially measured metric names how much more is needed")
    func needsMore() {
        let state = ProfileMeasurementState.forSamples(have: 5, need: 8)
        #expect(state.message == "Not enough games yet — 3 more to measure this")
    }

    @Test("A measured metric has no message, so the number shows")
    func measured() {
        let state = ProfileMeasurementState.forSamples(have: 8, need: 8)
        #expect(state == .measured)
        #expect(state.message == nil)
        #expect(state.isMeasured)
    }

    @Test("The remaining count never reads as zero more")
    func remainingIsAtLeastOne() {
        #expect(
            ProfileMeasurementState.needsMore(have: 9, need: 8, noun: "games").message
                == "Not enough games yet — 1 more to measure this"
        )
    }

    @Test("A chart needs two points before it is a trend")
    func seriesNeedsTwoPoints() {
        #expect(ProfileMeasurementState.forSeries(pointCount: 0).message == "No games recorded yet")
        #expect(
            ProfileMeasurementState.forSeries(pointCount: 1).message
                == "Not enough games yet — 1 more to measure this"
        )
        #expect(ProfileMeasurementState.forSeries(pointCount: 2) == .measured)
    }

    @Test("The noun follows the metric being described")
    func nounVaries() {
        #expect(
            ProfileMeasurementState.forSeries(pointCount: 1, noun: "sessions").message
                == "Not enough sessions yet — 1 more to measure this"
        )
    }

    // MARK: - Snapshot defaults

    @Test("The empty snapshot is an honest ladder, not a blank screen")
    func emptySnapshot() {
        let snapshot = ProfileSnapshot.empty()
        #expect(snapshot.currentRung == 1)
        #expect(snapshot.leaks.isEmpty)
        #expect(snapshot.leakWindowGames == 0)
        #expect(snapshot.leakState.message != nil)
        #expect(snapshot.ladder.rungs.count == Curriculum.default.count)
        #expect(snapshot.ladder.expandedRungID == 1)
        // Nothing is measured, so no skill may claim to be met.
        #expect(snapshot.ladder.rungs.allSatisfy { $0.metCount == 0 })
        #expect(snapshot.points(for: .rating).isEmpty)
    }

    @Test("Assembly picks the leak empty state from the games available")
    func assemblyChoosesLeakEmptyState() {
        let minimum = DomainTuning.default.focus.leakMinimumGames

        let thin = ProfileSnapshot.make(
            currentRung: 2,
            metrics: MetricSnapshot(),
            blockers: [],
            leaks: [
                Leak(causeTag: .hungMovedPiece, habit: .blunderCheck,
                     weightedEPLost: 1, epLostPerGame: 0.5, count: 2, deltaVsPreviousWeek: 0)
            ],
            series: [:],
            occurrences: [:],
            leakWindowGames: 3,
            gamesAvailable: 3
        )
        // Three games cannot rank causes; the section says so rather than
        // presenting noise as a diagnosis.
        #expect(thin.leakState.message != nil)
        #expect(thin.ladder.expandedRungID == 2)

        let full = ProfileSnapshot.make(
            currentRung: 2,
            metrics: MetricSnapshot(),
            blockers: [],
            leaks: [],
            series: [:],
            occurrences: [:],
            leakWindowGames: minimum,
            gamesAvailable: minimum
        )
        #expect(full.leakState == .measured)
    }

    @Test("Assembly sorts the leaks it is handed")
    func assemblySortsLeaks() {
        let snapshot = ProfileSnapshot.make(
            currentRung: 1,
            metrics: MetricSnapshot(),
            blockers: [],
            leaks: [
                Leak(causeTag: .forcingBias, habit: nil,
                     weightedEPLost: 1, epLostPerGame: 0.1, count: 2, deltaVsPreviousWeek: 0),
                Leak(causeTag: .hungMovedPiece, habit: nil,
                     weightedEPLost: 9, epLostPerGame: 0.4, count: 9, deltaVsPreviousWeek: 0)
            ],
            series: [.rating: [ProfileSeriesPoint(date: Date(), value: 1200, deviation: nil)]],
            occurrences: [:],
            leakWindowGames: 20,
            gamesAvailable: 20
        )
        #expect(snapshot.leaks.map(\.causeTag) == [.hungMovedPiece, .forcingBias])
        #expect(snapshot.points(for: .rating).count == 1)
        #expect(snapshot.points(for: .accuracy).isEmpty)
    }

    @Test("Occurrences come back most recent first")
    func occurrencesSorted() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func occurrence(daysAgo: Double) -> LeakOccurrence {
            LeakOccurrence(
                id: UUID(), gameID: UUID(),
                playedAt: now.addingTimeInterval(-daysAgo * 86_400),
                ply: 21, playedSAN: "Nf3", bestSAN: "Qe2", epLost: 0.3,
                opponentRating: 1200, result: "0-1"
            )
        }
        var snapshot = ProfileSnapshot.empty(now: now)
        snapshot.occurrences = [
            CauseTag.hungMovedPiece.rawValue: [
                occurrence(daysAgo: 5), occurrence(daysAgo: 1), occurrence(daysAgo: 3)
            ]
        ]
        let sorted = snapshot.occurrences(for: .hungMovedPiece)
        #expect(sorted.map(\.playedAt) == sorted.map(\.playedAt).sorted(by: >))
        #expect(sorted.first?.playedAt == now.addingTimeInterval(-86_400))
    }
}

@Suite("Metric formatting and window round-trip")
struct ProfileNumbersTests {

    @Test("Values format at a precision that distinguishes them from a threshold")
    func formatting() {
        #expect(formatMetricValue(0.8) == "0.8")
        #expect(formatMetricValue(0.55) == "0.55")
        #expect(formatMetricValue(1.0) == "1.0")
        #expect(formatMetricValue(4) == "4.0")
        #expect(formatMetricValue(12) == "12")
        #expect(formatMetricValue(1350) == "1350")
        #expect(formatMetricValue(0) == "0.0")
    }

    @Test("Comparison symbols match the domain's three forms")
    func symbols() {
        #expect(MetricComparison.lessThan.symbol == "<")
        #expect(MetricComparison.lessThanOrEqual.symbol == "≤")
        #expect(MetricComparison.greaterThanOrEqual.symbol == "≥")
    }

    @Test("Every window round-trips through its stored string")
    func windowRoundTrip() {
        let windows: [MetricWindow] = [.allTime, .lastGames(8), .lastGames(40), .lastDays(21)]
        for window in windows {
            #expect(MetricWindow(storageKey: window.key) == window)
        }
    }

    @Test("An unrecognised window is dropped rather than guessed at")
    func unknownWindow() {
        #expect(MetricWindow(storageKey: "rolling90") == nil)
        #expect(MetricWindow(storageKey: "last") == nil)
        #expect(MetricWindow(storageKey: "lastXd") == nil)
        #expect(MetricWindow(storageKey: "last0") == nil)
        #expect(MetricWindow(storageKey: "") == nil)
    }
}
