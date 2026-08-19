//
//  SettingsScreen.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import Database
import SwiftUI

/// Settings, ordered by reach: the board and its feedback first, because those
/// are the only controls here, then the engine's measured numbers, then the
/// notices — the two sections that can only be read sit below every one that
/// can be changed.
///
/// ## Every control here changes something
///
/// That sounds like the floor rather than a principle, and it is the one rule
/// this screen is built around. A settings screen is the only place in an app
/// where the user is *told* what the app can do, so a picker offering a theme no
/// board draws, or a toggle wired to nothing, does more damage than its absence:
/// it teaches that the controls are decoration, and that lesson generalises to
/// the ones that work. Options come from ``BoardAppearance``, which is the same
/// vocabulary the boards themselves resolve, and every change is written through
/// on the spot.
struct SettingsScreen: View {

    @Environment(AppModel.self) private var model
    @State private var viewModel = SettingsModel()

    private var appearance: BoardAppearance { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                boardSection
                engineSection
                aboutSection
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        // The app's accent rather than the system's, so a selected segment and
        // an on-state toggle read as the same "this one" the rest of the app
        // uses. Selection is the accent's whole job here: nothing on this
        // screen is a call to action, so nothing on it is filled.
        .tint(Palette.accent.dynamic)
        .navigationTitle("Settings")
        .task { viewModel.load() }
    }

    // MARK: - Board

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Board", qualifier: appearance.theme.name)

            SettingsCard {
                // A live preview, because a theme name means nothing until you
                // see it on the pieces you actually play with. It is drawn with
                // exactly the style the real boards resolve, so what is shown
                // here is what arrives on the next board.
                BoardView(position: .standard, interaction: .locked, style: appearance.style)
                    .frame(maxWidth: 200)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Preview of \(appearance.theme.name) squares with \(appearance.pieces.name) pieces")

                Picker(
                    "Squares",
                    selection: Binding(
                        get: { appearance.theme },
                        set: { appearance.choose(theme: $0) }
                    )
                ) {
                    ForEach(BoardAppearance.themes) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker(
                    "Pieces",
                    selection: Binding(
                        get: { appearance.pieces },
                        set: { appearance.choose(pieces: $0) }
                    )
                ) {
                    ForEach(BoardAppearance.pieceSets) { renderer in
                        Text(renderer.name).tag(renderer)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                #if os(iOS)
                    SettingsDivider()

                    Toggle(
                        "Sound",
                        isOn: Binding(
                            get: { viewModel.soundEnabled },
                            set: { viewModel.setSound($0) }
                        )
                    )
                    .typeRole(.body)

                    // Both halves of this sentence answer a question somebody
                    // is right to ask before touching the switch: what will I
                    // hear, and what will it do to what I am already
                    // listening to. The answer to the second is nothing, and
                    // saying so is worth more than describing the sounds.
                    Text("A wooden knock as a move lands, with its own sound for a capture, for check, and for a move that won't go. Mixes with whatever you're already playing, and the silent switch stops it.")
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsDivider()

                    Toggle(
                        "Haptics",
                        isOn: Binding(
                            get: { appearance.hapticsEnabled },
                            set: { appearance.setHaptics($0) }
                        )
                    )
                    .typeRole(.body)

                    // Naming the four events is the point: the budget is what
                    // keeps haptics from feeling like a defect, and a user who
                    // can see how short the list is has no reason to reach for
                    // this switch.
                    Text("A tap when you lift a piece, land a move, take something, or give check. Nothing else.")
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            .animation(Motion.colorShift, value: appearance.theme)
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Engine")

            SettingsCard {
                SettingsDetailRow(label: "Threads", value: "\(model.deviceProfile.threads)")
                SettingsDetailRow(label: "Hash", value: "\(model.deviceProfile.hashMB) MB")
                SettingsDetailRow(
                    label: "Nodes per position",
                    value: model.deviceProfile.analysisNodes.formatted()
                )
                if model.deviceProfile.benchNPS > 0 {
                    SettingsDetailRow(
                        label: "Measured speed",
                        value: "\(model.deviceProfile.benchNPS.formatted()) n/s"
                    )
                }

                Text("Measured on this device at launch, then used to keep each game's analysis to roughly 10–20 seconds.")
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")

            NavigationLink {
                AcknowledgementsScreen()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Acknowledgements")
                            .typeRole(.body)
                        Text("Stockfish, ChessKit, the Lichess puzzle database, and the piece art.")
                            .typeRole(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .elevation(.raised, cornerRadius: CornerRadius.card)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.primary)
        }
    }
}

// MARK: - Components

/// A level-1 card: solid fill, hairline, no shadow.
private struct SettingsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .elevation(.raised, cornerRadius: CornerRadius.card)
    }
}

/// The hairline that separates two groups inside one card.
///
/// A hairline rather than a second card, because everything either side of it
/// is the same subject: a card per group would say these are unrelated settings
/// that happen to sit near each other, when what they share is the board.
private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline.dynamic)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A read-only label/value row. Values are monospaced because they are
/// instrument readings, and a column of figures that do not line up reads as an
/// estimate.
private struct SettingsDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .typeRole(.body)
            Spacer(minLength: 12)
            Text(value)
                .typeRole(.caption, monospacedDigits: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model

@Observable
@MainActor
final class SettingsModel {

    private(set) var soundEnabled = true

    private let store: (any AppSettingsStore)?

    init(store: (any AppSettingsStore)? = AppDatabase.sharedIfAvailable?.settings) {
        self.store = store
    }

    func load() {
        guard let stored = try? store?.current() else { return }
        // Reading the row is also what installs the mirror, so arriving here
        // leaves `Sound.isEnabled` agreeing with the switch even if nothing
        // called `Sound.prepare` at launch. The alternative is a toggle that
        // reads "off" above a board that is still clicking.
        soundEnabled = stored.soundOn
        Sound.isEnabled = stored.soundOn
    }

    /// The switch and the audio service move together, in that order: the
    /// service is what the next move consults, and a write that persisted
    /// without mirroring would leave the setting correct on disk and wrong in
    /// the hand until the next launch.
    func setSound(_ enabled: Bool) {
        soundEnabled = enabled
        Sound.isEnabled = enabled
        try? store?.update { $0.soundOn = enabled }
    }
}
