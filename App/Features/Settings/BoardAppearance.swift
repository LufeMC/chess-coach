//
//  BoardAppearance.swift
//  ChessCoach
//

import BoardUI
import Database
import Observation
import SwiftUI

/// The board settings, resolved into the values `BoardUI` actually draws with.
///
/// ## Why a resolver and not two strings
///
/// `AppSettings` stores a theme name and a piece-set name, which is the right
/// shape for a synced row and the wrong shape for a call site: a board wants a
/// `BoardStyle`. If every screen resolved those strings itself, a name that
/// matched nothing would fall back silently, screen by screen — and a settings
/// picker offering an option no board honours is indistinguishable, from the
/// user's chair, from a picker that does nothing at all. One resolver means the
/// unrecognised name is decided once and decided the same way everywhere.
///
/// ## Why a shared object and not an environment value
///
/// `@Observable` tracks correctly through a static instance, so a board reads
/// ``style`` in its body and re-renders the moment the theme changes, with no
/// environment key to inject and no ancestor that has to remember to inject it.
/// An ancestor that forgets is the exact failure this type exists to prevent.
@MainActor
@Observable
final class BoardAppearance {

    /// The process-wide appearance.
    static let shared = BoardAppearance()

    /// The square theme.
    private(set) var theme: BoardStyle
    /// The piece artwork.
    private(set) var pieces: PieceRenderer
    /// Mirrored into ``Haptics/isEnabled`` on every change.
    private(set) var hapticsEnabled: Bool

    private let store: (any AppSettingsStore)?

    /// The style to hand a `BoardView`.
    var style: BoardStyle { theme.usingPieceSet(pieces) }

    /// Reads the stored appearance.
    ///
    /// The read is synchronous, on the main actor, and that is deliberate: it is
    /// one row out of a local SQLite file, and the alternative is a board that
    /// draws in the default theme for a frame and then repaints in the user's.
    /// A theme that flickers on every push is worse than a sub-millisecond read.
    init(store: (any AppSettingsStore)? = AppDatabase.sharedIfAvailable?.settings) {
        self.store = store
        let stored = try? store?.current()
        theme = Self.theme(named: stored?.boardTheme)
        pieces = Self.pieceSet(named: stored?.pieceSet)
        hapticsEnabled = stored?.hapticsOn ?? true
        Haptics.isEnabled = hapticsEnabled
    }

    /// Forces the shared appearance open.
    ///
    /// Worth calling at launch: the haptics mirror lives here, so until
    /// something has read the settings row the app runs on ``Haptics/isEnabled``'s
    /// compiled-in default and a user who turned haptics off feels them again
    /// after every relaunch.
    static func prepare() {
        _ = shared
    }

    // MARK: Choices

    func choose(theme: BoardStyle) {
        self.theme = theme
        try? store?.update { $0.boardTheme = Self.storageName(for: theme) }
    }

    func choose(pieces: PieceRenderer) {
        self.pieces = pieces
        try? store?.update { $0.pieceSet = Self.storageName(for: pieces) }
    }

    func setHaptics(_ enabled: Bool) {
        hapticsEnabled = enabled
        Haptics.isEnabled = enabled
        try? store?.update { $0.hapticsOn = enabled }
    }

    // MARK: Vocabulary

    /// The square themes offered in settings.
    static let themes: [BoardStyle] = BoardStyle.builtIn

    /// The piece sets offered in settings.
    ///
    /// The vector and glyph sets `BoardUI` also ships are absent on purpose:
    /// they exist so a preview renders from a clean checkout and so a 40pt
    /// thumbnail has something cheap to draw, not as artwork anyone would pick.
    static let pieceSets: [PieceRenderer] = [.staunty, .cburnett]

    /// The string written to the settings row.
    ///
    /// Lower-cased so a hand-edited row, an older write, and the picker all
    /// resolve to the same theme — the stored value is an identifier, and an
    /// identifier that is case-sensitive across sync is an identifier that
    /// eventually stops matching.
    static func storageName(for theme: BoardStyle) -> String {
        theme.name.lowercased()
    }

    static func storageName(for pieces: PieceRenderer) -> String {
        pieces.name.lowercased()
    }

    /// The theme a stored name refers to, or the default when it refers to
    /// nothing. A name from a newer build that this one has never heard of is
    /// the same situation as no name at all.
    static func theme(named name: String?) -> BoardStyle {
        guard let name else { return .default }
        return themes.first { storageName(for: $0) == name.lowercased() } ?? .default
    }

    static func pieceSet(named name: String?) -> PieceRenderer {
        guard let name else { return .staunty }
        return pieceSets.first { storageName(for: $0) == name.lowercased() } ?? .staunty
    }
}
