//
//  BoardAppearanceTests.swift
//  ChessCoachTests
//

import BoardUI
import Database
import Testing

@testable import ChessCoach

/// The settings-to-board seam.
///
/// Serialized because the haptics mirror is a process-wide switch, and a test
/// that flips it while another reads it is a flake nobody will reproduce.
@MainActor
@Suite("Board appearance", .serialized)
struct BoardAppearanceTests {

    /// The failure this type exists to make impossible: a picker offering a
    /// theme no board can draw is indistinguishable, from the user's chair,
    /// from a picker wired to nothing at all.
    @Test("A name no theme answers to resolves to the default")
    func unknownNamesFallBack() {
        #expect(BoardAppearance.theme(named: "lichessBrown") == BoardStyle.default)
        #expect(BoardAppearance.theme(named: nil) == BoardStyle.default)
        #expect(BoardAppearance.pieceSet(named: "merida") == PieceRenderer.clay)
        #expect(BoardAppearance.pieceSet(named: nil) == PieceRenderer.clay)
    }

    @Test("Every offered option round-trips through its stored name")
    func optionsRoundTrip() {
        for theme in BoardAppearance.themes {
            #expect(BoardAppearance.theme(named: BoardAppearance.storageName(for: theme)) == theme)
        }
        for set in BoardAppearance.pieceSets {
            #expect(BoardAppearance.pieceSet(named: BoardAppearance.storageName(for: set)) == set)
        }
    }

    /// Case is not part of the identity. The row syncs between devices and can
    /// be written by a build that spelled the name differently.
    @Test("Stored names resolve regardless of case")
    func namesAreCaseInsensitive() {
        #expect(BoardAppearance.theme(named: "INK") == BoardStyle.ink)
        #expect(BoardAppearance.pieceSet(named: "Cburnett") == PieceRenderer.cburnett)
    }

    /// Only the three artwork sets are offered. The vector and glyph renderers
    /// exist so a preview draws from a clean checkout, not as a choice.
    @Test("The offered sets are the ones with artwork")
    func onlyArtworkSetsAreOffered() {
        #expect(BoardAppearance.pieceSets == [.clay, .staunty, .cburnett])
        #expect(BoardAppearance.themes == BoardStyle.builtIn)
    }

    @Test("The stored row is what the boards are handed")
    func readsTheStoredRow() {
        let store = InMemoryAppSettingsStore(
            settings: AppSettings(boardTheme: "paper", pieceSet: "cburnett", hapticsOn: false)
        )
        let appearance = BoardAppearance(store: store)

        #expect(appearance.theme == BoardStyle.paper)
        #expect(appearance.style.pieceSet == PieceRenderer.cburnett)
        #expect(appearance.style.lightSquare == BoardStyle.paper.lightSquare)
        #expect(!appearance.hapticsEnabled)
    }

    /// There is no Done button on the settings screen, so a choice that waited
    /// for one would be a choice that never survived the launch.
    @Test("A choice is written through the moment it is made")
    func choicesPersist() throws {
        let store = InMemoryAppSettingsStore()
        let appearance = BoardAppearance(store: store)

        appearance.choose(theme: .ink)
        appearance.choose(pieces: .cburnett)

        let stored = try store.current()
        #expect(stored.boardTheme == "ink")
        #expect(stored.pieceSet == "cburnett")
        #expect(BoardAppearance(store: store).theme == BoardStyle.ink)
        #expect(BoardAppearance(store: store).pieces == PieceRenderer.cburnett)
    }

    /// `Haptics.isEnabled` documents itself as mirroring the setting. Nothing
    /// did the mirroring, so the switch moved a stored boolean and nothing else.
    @Test("The haptics switch reaches the taptic budget")
    func hapticsMirror() throws {
        let restore = Haptics.isEnabled
        defer { Haptics.isEnabled = restore }

        let store = InMemoryAppSettingsStore()
        let appearance = BoardAppearance(store: store)

        appearance.setHaptics(false)
        #expect(!Haptics.isEnabled)
        let silenced = try store.current()
        #expect(!silenced.hapticsOn)

        appearance.setHaptics(true)
        #expect(Haptics.isEnabled)
    }

    /// Reading the row is also what installs the mirror, so an appearance built
    /// from a row with haptics off leaves the switch off without being asked.
    @Test("Loading a row with haptics off silences them")
    func loadInstallsTheMirror() {
        let restore = Haptics.isEnabled
        defer { Haptics.isEnabled = restore }

        Haptics.isEnabled = true
        _ = BoardAppearance(store: InMemoryAppSettingsStore(settings: AppSettings(hapticsOn: false)))
        #expect(!Haptics.isEnabled)
    }

    /// No store at all is a real condition — Application Support can be
    /// unwritable — and it must degrade to the shipped defaults rather than
    /// crashing the first board.
    @Test("With no store the defaults still resolve")
    func degradesWithoutAStore() {
        let appearance = BoardAppearance(store: nil)
        #expect(appearance.theme == BoardStyle.default)
        #expect(appearance.pieces == PieceRenderer.clay)
    }
}
