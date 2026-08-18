import BoardUI
import ChessKit
import ClaudeKit
import SwiftUI

/// Settings, ordered by what unblocks something: the coach key first (nothing
/// else here enables a feature), then appearance, then engine diagnostics.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel = SettingsModel()

    var body: some View {
        Form {
            coachSection
            modelSection
            boardSection
            engineSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { viewModel.load() }
    }

    // MARK: - API key

    @ViewBuilder
    private var coachSection: some View {
        Section {
            if viewModel.hasStoredKey {
                // Naming the environment variable rather than a friendly label:
                // anyone holding an Anthropic key recognises this faster than
                // "API key", and it says exactly which credential is wanted.
                LabeledContent("ANTHROPIC_API_KEY") {
                    Text(viewModel.displayedKey)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                // Actions as full-width accent rows rather than trailing icon
                // buttons — they are distinct operations, not adornments on the
                // field.
                Button(viewModel.isKeyRevealed ? "Hide key" : "Reveal key") {
                    viewModel.toggleReveal()
                }
                Button("Remove key", role: .destructive) {
                    viewModel.removeKey()
                }
            } else {
                SecureField("sk-ant-…", text: $viewModel.draftKey)
                    .font(.body.monospaced())
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { viewModel.saveKey() }

                Button("Save key") { viewModel.saveKey() }
                    .disabled(!viewModel.draftKeyLooksValid)
            }
        } header: {
            Text("Coach")
        } footer: {
            statusFooter
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let error = viewModel.keyError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if viewModel.hasStoredKey {
            VStack(alignment: .leading, spacing: 6) {
                Label("Stored in the Keychain on this device", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.tint)
                Text(
                    "Coaching notes are written from engine analysis. The coach can never state a line the engine didn't produce — every move it names is checked against the engine's own variations before you see it."
                )
            }
        } else {
            Text("Add an Anthropic API key to turn engine findings into coaching notes. Everything else in the app works without one.")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            // Grouped by capability with the cost tradeoff stated, rather than a
            // bare list of model names: the choice being made is really
            // quality-versus-cost, so label that axis directly.
            Picker("Model", selection: $viewModel.model) {
                ForEach(SettingsModel.CoachModel.allCases) { model in
                    VStack(alignment: .leading) {
                        Text(model.title)
                        Text(model.costHint).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(model)
                }
            }
            #if os(macOS)
                .pickerStyle(.menu)
            #else
                .pickerStyle(.navigationLink)
            #endif

            Picker("Depth", selection: $viewModel.effort) {
                Text("Brief").tag("low")
                Text("Standard").tag("medium")
                Text("Thorough").tag("high")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Coaching model")
        } footer: {
            Text("Thorough spends more tokens per game for more careful notes.")
        }
    }

    // MARK: - Board

    private var boardSection: some View {
        Section("Board") {
            // A live preview, because a theme name means nothing until you see
            // it on the pieces you actually play with.
            BoardView(position: .standard, interaction: .locked)
                .frame(maxWidth: 200)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)

            Picker("Pieces", selection: $viewModel.pieceSet) {
                Text("Cburnett").tag("cburnett")
                Text("Merida").tag("merida")
            }
            Picker("Squares", selection: $viewModel.boardTheme) {
                Text("Brown").tag("lichessBrown")
                Text("Blue").tag("lichessBlue")
                Text("Green").tag("lichessGreen")
            }
            Toggle("Sound", isOn: $viewModel.soundOn)
            #if os(iOS)
                Toggle("Haptics", isOn: $viewModel.hapticsOn)
            #endif
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            LabeledContent("Threads", value: "\(model.deviceProfile.threads)")
            LabeledContent("Hash", value: "\(model.deviceProfile.hashMB) MB")
            LabeledContent("Nodes per position", value: model.deviceProfile.analysisNodes.formatted())
            if model.deviceProfile.benchNPS > 0 {
                LabeledContent("Measured speed", value: "\(model.deviceProfile.benchNPS.formatted()) n/s")
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("Measured on this device at launch, then used to keep each game's analysis to roughly 10–20 seconds.")
        }
    }
}

@Observable
@MainActor
final class SettingsModel {

    enum CoachModel: String, CaseIterable, Identifiable {
        case opus = "claude-opus-5"
        case sonnet = "claude-sonnet-5"
        case haiku = "claude-haiku-4-5"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .opus: "Opus 5"
            case .sonnet: "Sonnet 5"
            case .haiku: "Haiku 4.5"
            }
        }

        var costHint: String {
            switch self {
            case .opus: "Best coaching · highest cost"
            case .sonnet: "Nearly as good · moderate cost"
            case .haiku: "Serviceable · lowest cost"
            }
        }
    }

    var draftKey = ""
    var hasStoredKey = false
    var isKeyRevealed = false
    var keyError: String?

    var model: CoachModel = .opus
    var effort = "medium"
    var pieceSet = "cburnett"
    var boardTheme = "lichessBrown"
    var soundOn = true
    var hapticsOn = true

    private let keychain = KeychainStore()
    private var storedKey: String?

    /// Cheap shape check so an obviously-wrong paste fails here rather than as a
    /// 401 several screens later.
    var draftKeyLooksValid: Bool {
        draftKey.hasPrefix("sk-ant-") && draftKey.count > 20
    }

    /// Masked by default, with the last four characters shown.
    ///
    /// Reading the key back out is a deliberate choice: with multiple keys in
    /// circulation the only question a user actually has here is *which* key is
    /// stored, and a bare "Stored ✓" can't answer it.
    var displayedKey: String {
        guard let key = storedKey else { return "—" }
        if isKeyRevealed { return key }
        let suffix = key.suffix(4)
        return "sk-ant-••••••••••••\(suffix)"
    }

    func load() {
        do {
            storedKey = try keychain.load()
            hasStoredKey = storedKey != nil
        } catch {
            storedKey = nil
            hasStoredKey = false
        }
    }

    func toggleReveal() {
        isKeyRevealed.toggle()
    }

    func saveKey() {
        guard draftKeyLooksValid else { return }
        do {
            try keychain.store(key: draftKey)
            storedKey = draftKey
            draftKey = ""
            keyError = nil
            hasStoredKey = true
        } catch {
            keyError = "Couldn't save to the Keychain: \(error.localizedDescription)"
        }
    }

    func removeKey() {
        do {
            try keychain.delete()
            storedKey = nil
            hasStoredKey = false
            isKeyRevealed = false
            keyError = nil
        } catch {
            keyError = "Couldn't remove the key: \(error.localizedDescription)"
        }
    }
}
