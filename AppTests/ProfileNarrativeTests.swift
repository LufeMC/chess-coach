import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

@Suite("Profile narrative")
struct ProfileNarrativeTests {

    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// A rising walk, one point per day, ending at `now`.
    static func rising(days: Int, from start: Double, step: Double) -> [ProfileSeriesPoint] {
        (0..<days).map { index in
            ProfileSeriesPoint(
                date: now.addingTimeInterval(-Double(days - 1 - index) * 86_400),
                value: start + Double(index) * step,
                deviation: nil
            )
        }
    }

    // MARK: - Period segments

    @Test("A period needs two points before its average is an average")
    func segmentCountFloor() {
        #expect(ProfileChartSeries.segmentCount(pointCount: 3) == 1)
        #expect(ProfileChartSeries.segmentCount(pointCount: 4) == 2)
        #expect(ProfileChartSeries.segmentCount(pointCount: 7) == 3)
        // Capped, because five bars over a 176pt plot is a bar chart pretending
        // to be an annotation.
        #expect(ProfileChartSeries.segmentCount(pointCount: 400) == 4)
    }

    @Test("A full window splits into four periods, each compared to the last")
    func segments() {
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 16, from: 1000, step: 10),
            range: .oneMonth,
            now: Self.now
        )
        #expect(series.segments.count == 4)
        // The first has nothing behind it, and `0%` there would claim a flat
        // period that was never measured.
        #expect(series.segments.first?.delta == nil)
        #expect(series.segments.dropFirst().allSatisfy { ($0.delta ?? 0) > 0 })
        #expect(series.segments.map(\.average) == [1015, 1055, 1095, 1135])
    }

    @Test("Two points cannot make a comparison, so they make no bars")
    func segmentsNeedAComparison() {
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 2, from: 1000, step: 10),
            range: .oneMonth,
            now: Self.now
        )
        #expect(series.segments.isEmpty)
    }

    @Test("A delta reads as a signed percentage")
    func deltaLabels() {
        func segment(delta: Double?) -> ProfileChartSegment {
            ProfileChartSegment(
                interval: DateInterval(start: Self.now, duration: 86_400),
                average: 1000,
                delta: delta
            )
        }
        #expect(segment(delta: 0.104).deltaLabel == "+10%")
        #expect(segment(delta: -0.071).deltaLabel == "−7%")
        #expect(segment(delta: nil).deltaLabel == nil)
    }

    // MARK: - The sentence

    @Test("The interpretation states the movement in the user's own units")
    func movementSentence() {
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 16, from: 1000, step: 10),
            range: .oneMonth,
            now: Self.now
        )
        let text = ProfileNarrative.interpretation(for: series, metric: .rating, range: .oneMonth)
        // "two weeks", not "month": the window is 1M but the data covers 15
        // days, and the sentence describes the data.
        #expect(text?.hasPrefix("Up 150 rating points over the last two weeks.") == true)
    }

    @Test("Movement inside the noise floor is called level, not a decline")
    func noiseIsNotADirection() {
        // Six rating points across a month is the estimate breathing.
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 30, from: 1200, step: -0.2),
            range: .oneMonth,
            now: Self.now
        )
        let text = ProfileNarrative.interpretation(for: series, metric: .rating, range: .oneMonth)
        #expect(text?.hasPrefix("Level over the last three weeks.") == true)
    }

    // MARK: - The sentence describes the data, not the picker

    @Test("A window wider than the data does not stretch the claim")
    func spanFollowsTheDataNotTheWindow() {
        // Three weeks of play, looked at through the 1Y window.
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 22, from: 1000, step: 5),
            range: .oneYear,
            now: Self.now
        )
        let text = ProfileNarrative.interpretation(for: series, metric: .rating, range: .oneYear)
        #expect(text?.contains("over the last three weeks") == true)
        #expect(text?.contains("year") == false)
    }

    @Test("Data wider than the window is clipped to the window")
    func spanNeverExceedsTheWindow() {
        // A year of history seen through 1M: the chart only draws the last
        // month, so the sentence must not describe the year behind it.
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 300, from: 900, step: 1),
            range: .oneMonth,
            now: Self.now
        )
        let text = ProfileNarrative.interpretation(for: series, metric: .rating, range: .oneMonth)
        #expect(text?.contains("year") == false)
        #expect(text?.contains("months") == false)
    }

    @Test("A change too recent to be a period says nothing at all")
    func tooRecentToInterpret() {
        // Five measurements inside a week. Enough points, not enough time —
        // "down 11 over the last three months" from two days of play is the
        // sentence this guard exists to prevent.
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 5, from: 1100, step: -3),
            range: .threeMonths,
            now: Self.now
        )
        #expect(ProfileNarrative.interpretation(for: series, metric: .rating, range: .threeMonths) == nil)
    }

    @Test("Three points spread over months are still not a trend")
    func tooFewPointsToInterpret() {
        let sparse = [
            ProfileSeriesPoint(date: Self.now.addingTimeInterval(-60 * 86_400), value: 1_000, deviation: nil),
            ProfileSeriesPoint(date: Self.now.addingTimeInterval(-30 * 86_400), value: 1_050, deviation: nil),
            ProfileSeriesPoint(date: Self.now, value: 1_100, deviation: nil),
        ]
        let series = ProfileChartSeries.make(from: sparse, range: .threeMonths, now: Self.now)
        #expect(ProfileNarrative.interpretation(for: series, metric: .rating, range: .threeMonths) == nil)
    }

    @Test("Two points get no interpretation at all")
    func nothingToInterpret() {
        let series = ProfileChartSeries.make(
            from: Self.rising(days: 1, from: 1000, step: 0),
            range: .oneMonth,
            now: Self.now
        )
        #expect(ProfileNarrative.interpretation(for: series, metric: .rating, range: .oneMonth) == nil)
    }

    @Test("A gain that has stopped is reported as a gain that has stopped")
    func staleGain() {
        // The sentence exists so the reader does not have to reconcile "up 150"
        // against a recent stretch that gave some of it back.
        let sentence = ProfileNarrative.recentStretch(delta: -0.06, overall: .up)
        #expect(sentence.contains("6%"))
        #expect(sentence.contains("older than it looks"))
    }
}

@Suite("Rating leak diagnosis")
struct LeakDiagnosisTests {

    static func rows(_ values: [(CauseTag, Double)], habit: Habit? = nil) -> [LeakRow] {
        LeakTable.rows(
            from: values.map { tag, ep in
                Leak(
                    causeTag: tag,
                    habit: habit,
                    weightedEPLost: ep * 40,
                    epLostPerGame: ep,
                    count: 6,
                    deltaVsPreviousWeek: 0
                )
            }
        )
    }

    @Test("An empty table is not diagnosed")
    func nothingToRead() {
        #expect(LeakDiagnosis.make(rows: [], windowGames: 40) == nil)
    }

    @Test("Loss below the noise floor is reported as clean, not as a small problem")
    func clean() {
        let diagnosis = LeakDiagnosis.make(
            rows: Self.rows([(.hungMovedPiece, 0.02), (.forcingBias, 0.01)]),
            windowGames: 40
        )
        #expect(diagnosis?.shape == .clean)
        // The word states how many holes there are, like the other two shapes.
        // "Clean" sat beside a figure and read as a grade on the player.
        #expect(diagnosis?.shape.word == "Nothing much")
    }

    @Test("One dominant cause is called out as the only thing worth working")
    func concentrated() {
        let diagnosis = LeakDiagnosis.make(
            rows: Self.rows([(.hungMovedPiece, 0.42), (.missedNewThreat, 0.20), (.forcingBias, 0.10)]),
            windowGames: 40
        )
        #expect(diagnosis?.shape == .concentrated)
        #expect(diagnosis?.headline == "Hanging pieces is where most of it goes.")
        #expect(diagnosis?.formattedPoints == "0.72")
    }

    @Test("An even split is called even, because the instruction is different")
    func spread() {
        let diagnosis = LeakDiagnosis.make(
            rows: Self.rows([
                (.hungMovedPiece, 0.15), (.missedNewThreat, 0.15),
                (.forcingBias, 0.15), (.positionalDrift, 0.15)
            ]),
            windowGames: 40
        )
        #expect(diagnosis?.shape == .spread)
        // A user with no dominant habit has a standard-of-play problem and
        // nothing single to practise; telling them to "work the top one" would
        // be advice the table does not support.
        #expect(diagnosis?.explanation.contains("split fairly evenly") == true)
    }

    // MARK: - Bars

    @Test("Bars dim down the table and never disappear")
    func barRamp() {
        #expect(LeakTable.barOpacity(rank: 0) == 1.0)
        #expect(LeakTable.barOpacity(rank: 1) < LeakTable.barOpacity(rank: 0))
        #expect(LeakTable.barOpacity(rank: 3) < LeakTable.barOpacity(rank: 2))
        // A bar too faint to see is a row the table forgot to draw.
        #expect(LeakTable.barOpacity(rank: 40) >= 0.34)
    }

    // MARK: - The action

    @Test("The button names the habit that fixes the leak, not the leak")
    func trainAction() {
        let withHabit = Self.rows([(.hungMovedPiece, 0.4)], habit: .blunderCheck)[0]
        #expect(LeakTable.trainActionTitle(for: withHabit) == "Train blunder-checking")

        // No habit, no button. The handoff to Train carries the habit and
        // nothing else, so a title here would put a filled call to action in
        // front of a tab switch that opens no session.
        let unmapped = Self.rows([(CauseTag("someFutureCause"), 0.4)])[0]
        #expect(LeakTable.trainActionTitle(for: unmapped) == nil)
    }

    @Test("Every cause carries a line explaining itself, known or not")
    func details() {
        #expect(LeakTable.detail(for: .hungMovedPiece).isEmpty == false)
        #expect(LeakTable.detail(for: CauseTag("someFutureCause")).isEmpty == false)
        // Written about the move, never about the person.
        #expect(LeakTable.detail(for: .hungMovedPiece).contains("You") == false)
    }
}

@Suite("Per-leak history")
struct LeakTrendTests {

    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func occurrence(daysAgo: Double, epLost: Double = 0.3) -> LeakOccurrence {
        LeakOccurrence(
            id: UUID(),
            gameID: UUID(),
            playedAt: now.addingTimeInterval(-daysAgo * 86_400),
            ply: 27,
            playedSAN: "Nf3",
            bestSAN: "Qe2",
            epLost: epLost,
            opponentRating: 1200,
            result: "0-1"
        )
    }

    @Test("Buckets run oldest first, so the sparkline reads the way time does")
    func ordering() {
        let trend = LeakTrend.make(
            from: [
                Self.occurrence(daysAgo: 80, epLost: 0.4),
                Self.occurrence(daysAgo: 60),
                Self.occurrence(daysAgo: 40),
                Self.occurrence(daysAgo: 5, epLost: 0.1)
            ],
            now: Self.now
        )
        #expect(trend?.buckets.count == 6)
        #expect(trend?.buckets.first == 0.4)
        #expect(trend?.buckets.last == 0.1)
        #expect(trend?.peak == 0.4)
    }

    @Test("Thin evidence gets no sparkline rather than a flat one")
    func refusesToGuess() {
        // A shape drawn from three moves is read as a claim about direction.
        let trend = LeakTrend.make(
            from: [Self.occurrence(daysAgo: 10), Self.occurrence(daysAgo: 20)],
            now: Self.now
        )
        #expect(trend == nil)
    }

    @Test("Occurrences all landing in one week make no shape")
    func needsSpread() {
        let trend = LeakTrend.make(
            from: (0..<6).map { Self.occurrence(daysAgo: Double($0)) },
            now: Self.now
        )
        #expect(trend == nil)
    }

    @Test("Anything older than the window is outside the story")
    func windowed() {
        let trend = LeakTrend.make(
            from: [
                Self.occurrence(daysAgo: 200),
                Self.occurrence(daysAgo: 190),
                Self.occurrence(daysAgo: 180),
                Self.occurrence(daysAgo: 170)
            ],
            now: Self.now
        )
        #expect(trend == nil)
    }
}

// MARK: - The absence explains itself

/// A card that drops its sentence when the data is too young leaves a gap where
/// the sentence was, and a gap reads as a bug. These cover the replacement.
@Suite("Profile pending note")
struct ProfilePendingNoteTests {

    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func walk(days: Int, points: Int, from start: Double) -> [ProfileSeriesPoint] {
        (0..<points).map { index in
            let fraction = points == 1 ? 0 : Double(index) / Double(points - 1)
            return ProfileSeriesPoint(
                date: now.addingTimeInterval(-Double(days) * 86_400 * (1 - fraction)),
                value: start + Double(index) * 5,
                deviation: nil
            )
        }
    }

    @Test("Too few points names how many more are needed")
    func namesTheShortfall() {
        let series = ProfileChartSeries.make(
            from: Self.walk(days: 40, points: 3, from: 1_000),
            range: .threeMonths,
            now: Self.now
        )
        let note = try! #require(ProfileNarrative.pendingNote(for: series, metric: .rating))
        // The rating series counts stored observations — one a day the value
        // stood still, one per move — so the noun is days of play, not games.
        #expect(note == "1 more day of play before this is a trend.")
    }

    @Test("The count is pluralised")
    func pluralises() {
        let series = ProfileChartSeries.make(
            from: Self.walk(days: 40, points: 2, from: 1_000),
            range: .threeMonths,
            now: Self.now
        )
        let note = try! #require(ProfileNarrative.pendingNote(for: series, metric: .rating))
        #expect(note == "2 more days of play before this is a trend.")
    }

    @Test("Enough points but too little time says so instead")
    func namesTheTimeShortfall() {
        let series = ProfileChartSeries.make(
            from: Self.walk(days: 3, points: 6, from: 1_000),
            range: .threeMonths,
            now: Self.now
        )
        let note = try! #require(ProfileNarrative.pendingNote(for: series, metric: .rating))
        #expect(note.contains("last few days"))
    }

    @Test("A series that earns an interpretation gets no pending note")
    func noNoteWhenThereIsASentence() {
        let series = ProfileChartSeries.make(
            from: Self.walk(days: 40, points: 8, from: 1_000),
            range: .threeMonths,
            now: Self.now
        )
        #expect(ProfileNarrative.interpretation(for: series, metric: .rating, range: .threeMonths) != nil)
        #expect(ProfileNarrative.pendingNote(for: series, metric: .rating) == nil)
    }

    @Test("A single point falls to the card's own empty state, not to this")
    func singlePointIsNotThisNotesJob() {
        let series = ProfileChartSeries.make(
            from: Self.walk(days: 0, points: 1, from: 1_000),
            range: .threeMonths,
            now: Self.now
        )
        #expect(ProfileNarrative.pendingNote(for: series, metric: .rating) == nil)
    }

    @Test("Every state the card can be in produces exactly one line, or a known empty state")
    func noSilentGap() {
        // The invariant the card depends on: for any plottable series, either
        // there is a sentence or there is a note saying why there is not.
        for points in 2...10 {
            for days in [1, 5, 20, 60] {
                let series = ProfileChartSeries.make(
                    from: Self.walk(days: days, points: points, from: 1_000),
                    range: .threeMonths,
                    now: Self.now
                )
                guard series.isPlottable else { continue }
                let sentence = ProfileNarrative.interpretation(
                    for: series, metric: .rating, range: .threeMonths
                )
                let note = ProfileNarrative.pendingNote(for: series, metric: .rating)
                #expect(
                    (sentence != nil) != (note != nil),
                    "points=\(points) days=\(days) sentence=\(String(describing: sentence)) note=\(String(describing: note))"
                )
            }
        }
    }
}
