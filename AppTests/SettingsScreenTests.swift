import Foundation
import Testing

@testable import ChessCoach

/// The external rating anchor.
///
/// Everything the app says about strength is measured against its own engine
/// opponents, whose rating labels were assigned rather than measured — so a
/// displayed 2000 could be a real-world 1750 and nothing on screen would say
/// so. This is the one number that comes from outside, and these tests pin the
/// two things it has to get right: refusing an implausible entry, and stating
/// the gap in a direction the reader can actually apply.
@Suite("External rating anchor")
struct ExternalRatingAnchorTests {

    private let march = Date(timeIntervalSince1970: 1_772_000_000)

    @Test("A plausible rating parses; a typo does not")
    func parsing() {
        #expect(ExternalRatingAnchor.parse("1420") == 1420)
        #expect(ExternalRatingAnchor.parse("  1420 ") == 1420)
        // Out of band in both directions. An offset of nine hundred points
        // beside the Profile chart is worse than no anchor at all.
        #expect(ExternalRatingAnchor.parse("42") == nil)
        #expect(ExternalRatingAnchor.parse("14200") == nil)
        #expect(ExternalRatingAnchor.parse("") == nil)
        #expect(ExternalRatingAnchor.parse("1420?") == nil)
    }

    @Test("The gap is stated as a direction, not a sign")
    func gapDirection() {
        let anchor = ExternalRatingAnchor(rating: 1420, source: .lichess, measuredAt: march)

        // "+96" does not say which way to apply it, and this sentence exists so
        // the reader can convert one scale into the other in their head.
        let above = anchor.note(againstAppRating: 1516, now: march)
        #expect(above.contains("Rookly reads 96 points higher."))

        let below = anchor.note(againstAppRating: 1330, now: march)
        #expect(below.contains("Rookly reads 90 points lower."))

        let level = anchor.note(againstAppRating: 1420, now: march)
        #expect(level.contains("Rookly reads the same."))
    }

    @Test("With no app rating measured yet, the note reports the anchor alone")
    func noAppRating() {
        let anchor = ExternalRatingAnchor(rating: 1420, source: .chessCom, measuredAt: march)
        let note = anchor.note(againstAppRating: nil, now: march)
        #expect(note.contains("1420 on Chess.com rapid"))
        #expect(!note.contains("Rookly reads"))
    }

    @Test("The source names its time control, because blitz and rapid are not the same number")
    func sourceNaming() {
        #expect(ExternalRatingAnchor.Source.lichess.fullName == "Lichess rapid")
        #expect(ExternalRatingAnchor.Source.chessCom.fullName == "Chess.com rapid")
    }

    @Test("An anchor older than a quarter says so rather than being silently trusted")
    func staleness() {
        let anchor = ExternalRatingAnchor(rating: 1420, source: .lichess, measuredAt: march)
        let sameWeek = march.addingTimeInterval(5 * 86_400)
        #expect(!anchor.isStale(now: sameWeek))
        #expect(!anchor.note(againstAppRating: 1500, now: sameWeek).contains("Worth re-reading"))

        let halfAYearLater = march.addingTimeInterval(180 * 86_400)
        #expect(anchor.isStale(now: halfAYearLater))
        #expect(anchor.note(againstAppRating: 1500, now: halfAYearLater).contains("Worth re-reading"))
    }

    @Test("A saved anchor round-trips through the metrics table")
    @MainActor
    func roundTrip() {
        let metrics = InMemoryMetricStore()
        let model = SettingsModel(store: nil, metrics: metrics, database: nil)
        model.externalSource = .chessCom
        model.saveExternalRating("1655", now: march)

        let stored = ExternalRatingAnchor.stored(in: metrics)
        #expect(stored?.rating == 1655)
        #expect(stored?.source == .chessCom)
        #expect(stored?.measuredAt == march)
    }

    @Test("An implausible entry writes nothing")
    @MainActor
    func refusedEntryWritesNothing() {
        let metrics = InMemoryMetricStore()
        let model = SettingsModel(store: nil, metrics: metrics, database: nil)
        model.saveExternalRating("12")
        #expect(ExternalRatingAnchor.stored(in: metrics) == nil)
    }

    @Test("Nothing stored says so, rather than implying the scales agree")
    @MainActor
    func absentAnchorNote() {
        let model = SettingsModel(store: nil, metrics: InMemoryMetricStore(), database: nil)
        #expect(model.externalAnchorNote.contains("Nothing stored yet"))
    }
}

/// What the two expensive rows on the Settings screen promise before they are
/// tapped. Both spend something the user cannot get back — ninety minutes, or
/// the database — so neither is allowed to be a bare title.
@Suite("Settings progress rows")
@MainActor
struct SettingsProgressCopyTests {

    @Test("Recalibration prices itself and says the current rating survives")
    func recalibrationCost() {
        let model = SettingsModel(store: nil, metrics: nil, database: nil)
        // Without a readable settings row the sentence drops the number rather
        // than inventing one.
        #expect(model.recalibrationCost.contains("about 90 minutes"))
        #expect(model.recalibrationCost.contains("Your current rating stays until it finishes."))
    }

    @Test("With nothing recorded there is nothing to delete, and the row says so")
    func emptyEraseCost() {
        let model = SettingsModel(store: nil, metrics: nil, database: nil)
        #expect(!model.hasDataToErase)
        #expect(model.eraseCost == "Nothing has been recorded on this device yet.")
    }
}
