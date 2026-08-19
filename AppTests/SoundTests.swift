//
//  SoundTests.swift
//  ChessCoachTests
//

import Database
import Foundation
import Testing

@testable import ChessCoach

/// The audio service, minus the audio.
///
/// Nothing here asserts that a sound was heard — a test host has no speaker and
/// the service deliberately loads no players under the test runner. What is
/// checkable is everything that made the previous version of this feature a
/// lie: that every event names a file the bundle actually contains, that the
/// switch reaches the code that plays, and that the setting survives a
/// relaunch.
///
/// Serialized because ``Sound/isEnabled`` is process-wide, and a test that
/// flips it while another reads it is a flake nobody will reproduce.
@MainActor
@Suite("Sound", .serialized)
struct SoundTests {

    // MARK: The map

    /// The failure this catches is the one that cannot be seen: a case added to
    /// the enum without an asset beside it plays nothing, and nothing is
    /// exactly what a working sound looks like to a compiler.
    @Test("Every event resolves to a file in the bundle")
    func eventsResolveToBundledFiles() {
        for event in Sound.Event.allCases {
            let asset = Sound.asset(for: event)
            #expect(asset.url != nil, "\(event) has no bundled \(asset.rawValue).\(Sound.Asset.fileExtension)")
        }
    }

    /// Every file that ships is reachable from some event. A recording nobody
    /// can trigger is a dozen kilobytes of bundle and a design decision that
    /// quietly did not happen.
    @Test("Every bundled asset is reachable from an event")
    func assetsAreReachable() {
        let reachable = Set(Sound.Event.allCases.map(Sound.asset(for:)))
        #expect(reachable == Set(Sound.Asset.allCases))
    }

    @Test("The map matches the sound the event is named for")
    func eventMap() {
        #expect(Sound.asset(for: .moved) == .move)
        #expect(Sound.asset(for: .captured) == .capture)
        #expect(Sound.asset(for: .checkDelivered) == .check)
        #expect(Sound.asset(for: .illegalDrop) == .refusal)
        #expect(Sound.asset(for: .gameEnd) == .gameEnd)
        #expect(Sound.asset(for: .clockWarning) == .clockLow)
    }

    /// Six events, six sounds. Two events sharing one recording would make the
    /// board ambiguous in the one channel the user cannot look at.
    @Test("No two events share a sound")
    func soundsAreDistinct() {
        #expect(Set(Sound.Event.allCases.map(Sound.asset(for:))).count == Sound.Event.allCases.count)
    }

    // MARK: The budget

    /// One move, one sound. A capture that gives check is a single thing
    /// happening, and announcing it twice is the failure the precedence exists
    /// to prevent.
    @Test("A move makes exactly one sound, and check outranks capture")
    func outcomePrecedence() {
        #expect(Sound.outcome(isCapture: false, isCheck: false) == .moved)
        #expect(Sound.outcome(isCapture: true, isCheck: false) == .captured)
        #expect(Sound.outcome(isCapture: false, isCheck: true) == .checkDelivered)
        #expect(Sound.outcome(isCapture: true, isCheck: true) == .checkDelivered)
    }

    /// Lifting a piece and completing a checklist step buzz and stay silent.
    /// They are absent from the enum rather than mapped to silence, so a call
    /// site cannot ask for a sound the design decided against.
    @Test("The sanctioned set is smaller than the haptic set")
    func soundIsTheStricterChannel() {
        #expect(Sound.Event.allCases.count == 6)
    }

    // MARK: The switch

    @Test("Sound off means every event resolves to silence")
    func disabledIsSilent() {
        let restore = Sound.isEnabled
        defer { Sound.isEnabled = restore }

        Sound.isEnabled = false
        for event in Sound.Event.allCases {
            #expect(Sound.audible(event) == nil)
        }

        Sound.isEnabled = true
        for event in Sound.Event.allCases {
            #expect(Sound.audible(event) != nil)
        }
    }

    /// Playing with nothing loaded is the state every test host is in, and the
    /// first launch before ``Sound/prepare(store:)`` runs.
    @Test("Playing with no buffers loaded does nothing")
    func playingUnpreparedIsSafe() {
        let restore = Sound.isEnabled
        defer { Sound.isEnabled = restore }

        Sound.isEnabled = true
        for event in Sound.Event.allCases {
            // Enabled, so the silence that follows is the missing buffer being
            // handled rather than the switch swallowing the call.
            #expect(Sound.audible(event) != nil)
            Sound.play(event)
        }
    }

    // MARK: The setting

    /// `soundOn` was a column nothing read and nothing wrote — a switch in
    /// Settings that moved a boolean and touched nothing else.
    @Test("Preparing installs the stored setting")
    func prepareMirrorsTheStoredRow() {
        let restore = Sound.isEnabled
        defer { Sound.isEnabled = restore }

        Sound.isEnabled = true
        Sound.prepare(store: InMemoryAppSettingsStore(settings: AppSettings(soundOn: false)))
        #expect(!Sound.isEnabled)

        Sound.prepare(store: InMemoryAppSettingsStore(settings: AppSettings(soundOn: true)))
        #expect(Sound.isEnabled)
    }

    /// No store at all is a real condition — Application Support can be
    /// unwritable — and it must leave the shipped default in place.
    @Test("With no store the default survives")
    func prepareDegradesWithoutAStore() {
        let restore = Sound.isEnabled
        defer { Sound.isEnabled = restore }

        Sound.isEnabled = false
        Sound.prepare(store: nil)
        #expect(Sound.isEnabled)
    }

    /// There is no Done button on the settings screen, so a choice that waited
    /// for one would be a choice that never survived the launch.
    @Test("The switch is written through and reaches the service")
    func toggleRoundTrips() throws {
        let restore = Sound.isEnabled
        defer { Sound.isEnabled = restore }

        let store = InMemoryAppSettingsStore()
        let settings = SettingsModel(store: store)

        settings.setSound(false)
        #expect(!settings.soundEnabled)
        #expect(!Sound.isEnabled)
        let silenced = try store.current()
        #expect(!silenced.soundOn)

        settings.setSound(true)
        #expect(Sound.isEnabled)
        let restored = try store.current()
        #expect(restored.soundOn)
    }

    /// Loading the screen is also what installs the mirror, so a stored row
    /// with sound off silences the board without being asked twice.
    @Test("Loading a row with sound off silences the board")
    func loadInstallsTheMirror() {
        let restore = Sound.isEnabled
        defer { Sound.isEnabled = restore }

        Sound.isEnabled = true
        let settings = SettingsModel(store: InMemoryAppSettingsStore(settings: AppSettings(soundOn: false)))
        settings.load()

        #expect(!settings.soundEnabled)
        #expect(!Sound.isEnabled)
    }
}
