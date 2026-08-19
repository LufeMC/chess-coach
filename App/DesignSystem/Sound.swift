//
//  Sound.swift
//  ChessCoach
//
//  Design system — Sound.
//

import AVFoundation
import Database
import Foundation

/// Every sound the app is allowed to make, and nothing else.
///
/// ## Why this is centralised
///
/// The same reason ``Haptics`` is: the budget is the design, and no individual
/// call site ever believes it is the one over it. Sound is the stricter of the
/// two channels, because a phone can be face-down in a pocket and still be
/// heard across a room — so this enum is a subset of the haptic one rather
/// than a copy of it. Lifting a piece and completing a checklist step buzz and
/// stay silent, and the reasoning is in ``Event``.
///
/// ## One sound per position, chosen by ``outcome(isCapture:isCheck:)``
///
/// A capture that also gives check is one thing happening, and playing both
/// the capture and the check for it is the failure this type is built to
/// prevent. The precedence lives here as a pure function rather than at the
/// call site, so a second board — review, puzzles, a future analysis screen —
/// cannot arrive at a different answer.
///
/// ## Why it never interrupts anything
///
/// The session category is `.ambient`, which is the whole contract with the
/// user: their podcast keeps playing, their music keeps playing, and the
/// physical silent switch silences the app the way it silences everything else
/// they own. A trainer somebody opens for twenty minutes a day that stops
/// their audiobook to click at them is a trainer they stop opening.
enum Sound {

    /// The sanctioned events. Adding a case is a design decision, which is
    /// exactly the friction wanted.
    ///
    /// Absent, and both absences are the point:
    ///
    /// - **Piece lifted.** It would double the sounds per move, and the user is
    ///   watching their own finger do it.
    /// - **Checklist step complete.** In guided mode a step completes on the
    ///   same gesture that lands a move, so it would arrive as a second sound
    ///   for one action.
    enum Event: Hashable, CaseIterable {
        case moved
        case captured
        case checkDelivered
        case illegalDrop
        /// One sound for every result. See ``Asset/gameEnd``.
        case gameEnd
        /// Fires **once** as the clock crosses ten seconds, not per tick.
        case clockWarning
    }

    /// The bundled recording an event plays.
    ///
    /// Separate from ``Event`` for the reason ``Haptics/Feedback`` is separate
    /// from its event: it is the description of what will be heard, so the map
    /// can be checked without a speaker — and no call site can name a file that
    /// is not in the bundle, because file names are not spellable here.
    enum Asset: String, Hashable, CaseIterable {
        case move
        case capture
        case check
        case refusal
        /// Deliberately result-blind. The outcome is on screen in words, and a
        /// sound that resolved happily for a win would have to resolve
        /// unhappily for a loss — which is a mascot expressing disappointment,
        /// in the one channel that cannot be looked away from.
        case gameEnd = "game-end"
        case clockLow = "clock-low"

        /// CAF rather than WAV: it is what iOS prefers for short one-shots, and
        /// `afconvert` lays the samples out page-aligned so the first play
        /// after a load does not fault.
        static let fileExtension = "caf"
    }

    /// The map, as a pure function.
    static func asset(for event: Event) -> Asset {
        switch event {
        case .moved: .move
        case .captured: .capture
        case .checkDelivered: .check
        case .illegalDrop: .refusal
        case .gameEnd: .gameEnd
        case .clockWarning: .clockLow
        }
    }

    /// The single sound a completed move is allowed to make.
    ///
    /// Check outranks capture because it is the more urgent fact: a hanging
    /// king ends the game and a hanging rook does not. Both outrank the plain
    /// move, so a move is never announced twice.
    static func outcome(isCapture: Bool, isCheck: Bool) -> Event {
        if isCheck { return .checkDelivered }
        if isCapture { return .captured }
        return .moved
    }

    /// Master switch, mirroring the `soundOn` app setting.
    ///
    /// Cached rather than read from the database per event, for the reason
    /// ``Haptics/isEnabled`` is: a SQLite round trip inside a drag gesture is
    /// how a board starts stuttering.
    @MainActor static var isEnabled = true

    /// What ``play(_:)`` would do, as a value rather than as an effect.
    ///
    /// The switch is state, so the decision has to be readable to be checkable
    /// at all: a test host has no speaker, and "it did not crash" is not
    /// evidence that a disabled app is silent.
    @MainActor
    static func audible(_ event: Event) -> Asset? {
        isEnabled ? asset(for: event) : nil
    }

    /// Plays the sound for an event, or nothing at all.
    ///
    /// Silent by design when sound is off, when the file is missing, and when
    /// nothing has called ``prepare(store:)`` — every one of those is a state
    /// the app can genuinely be in, and none of them is worth an exception on
    /// the move path.
    @MainActor
    static func play(_ event: Event) {
        guard let asset = audible(event), let player = players[asset] else { return }
        // Rewound rather than restarted. A player that is already sounding is a
        // capture immediately after a capture, which happens in every trade,
        // and letting the second one hit `play()` on a running player is how
        // one of the two goes missing.
        player.currentTime = 0
        player.play()
    }

    /// Reads the stored setting and loads the buffers.
    ///
    /// Worth calling at launch, and both halves matter. The mirror lives here,
    /// so until something has read the settings row the app runs on
    /// ``isEnabled``'s compiled-in default and a user who turned sound off
    /// hears it again after every relaunch. The buffers matter for a different
    /// reason: building an `AVAudioPlayer` reads and decodes a file, and doing
    /// that inside the first capture of a game is a hitch at the exact moment
    /// the board is animating.
    @MainActor
    static func prepare(store: (any AppSettingsStore)? = AppDatabase.sharedIfAvailable?.settings) {
        isEnabled = (try? store?.current())?.soundOn ?? true

        // Tests are hosted inside the app, and a suite that ran through here
        // would activate a real audio session on whatever machine is building.
        guard !AppModel.isRunningTests, players.isEmpty else { return }

        // `.ambient` is the contract: mixes with other audio, respects the
        // silent switch, and never becomes the active session on its own.
        // `.notifyOthersOnDeactivation` is absent because this session never
        // ducked anybody to begin with.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [])
        try? session.setActive(true)

        for asset in Asset.allCases {
            guard let url = asset.url, let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            // Allocates the hardware buffers now rather than on first play.
            player.prepareToPlay()
            players[asset] = player
        }
    }

    /// One player per asset, alive for the life of the process.
    ///
    /// Six of them, each holding a decoded buffer of well under a second — the
    /// whole set is smaller than one board screenshot, and the alternative is
    /// an allocation on the move path.
    @MainActor private static var players: [Asset: AVAudioPlayer] = [:]
}

extension Sound.Asset {

    /// Where the file landed in the bundle.
    ///
    /// Both locations are checked because both are correct depending on how the
    /// resource was declared: a file reference is copied to the bundle root, a
    /// folder reference keeps its directory. A sound that silently stops
    /// playing because the project file changed shape is a bug nobody reports —
    /// they assume it was never there.
    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: Self.fileExtension)
            ?? Bundle.main.url(
                forResource: rawValue,
                withExtension: Self.fileExtension,
                subdirectory: "Sounds"
            )
    }
}
