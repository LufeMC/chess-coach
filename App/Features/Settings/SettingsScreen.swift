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
    @State private var isShowingEngineDetails = false
    @State private var isConfirmingRecalibration = false
    @State private var isRecalibrating = false
    @State private var isConfirmingErase = false
    @State private var externalRatingText = ""

    private var appearance: BoardAppearance { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                boardSection
                progressSection
                engineSection
                howItWorksSection
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
        // Both destructive-ish paths ask in a sheet rather than inline, and
        // both name what they cost before the tap that spends it — the whole
        // reason either row is safe to put on a screen the user browses.
        .confirmationDialog(
            "Measure your rating again?",
            isPresented: $isConfirmingRecalibration,
            titleVisibility: .visible
        ) {
            Button("Start the five games") { isRecalibrating = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.recalibrationCost)
        }
        .confirmationDialog(
            "Delete all games and progress?",
            isPresented: $isConfirmingErase,
            titleVisibility: .visible
        ) {
            // Tinted inside a sheet, which is where craft-standards routes a
            // destructive action: red on the settings list itself would be a
            // second meaning for the colour the eval bar already owns.
            Button("Delete and measure again", role: .destructive) {
                viewModel.eraseEverything()
                // Straight into calibration rather than back to a Today screen
                // with an empty ladder and a default 1100 nobody measured. The
                // wipe removed the completion marker, so the gate would reopen
                // on the next launch anyway; doing it now is the difference
                // between a re-measure and a week of mis-pitched opponents.
                isRecalibrating = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.eraseCost)
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $isRecalibrating) {
                CalibrationScreen {
                    isRecalibrating = false
                    viewModel.load()
                }
                .environment(model)
            }
        #else
            .sheet(isPresented: $isRecalibrating) {
                CalibrationScreen {
                    isRecalibrating = false
                    viewModel.load()
                }
                .environment(model)
            }
        #endif
    }

    // MARK: - Board

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Board", qualifier: appearance.theme.name)

            SettingsCard {
                // Every control below writes straight through to the settings
                // row, so when that row cannot be written they all become
                // session-length choices. Saying so beats letting the user
                // discover it tomorrow, when the board is clay again.
                if model.databaseError != nil {
                    Text("Saving is off: the app's storage could not be opened, so these choices last until you close the app.")
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // A live preview, because a theme name means nothing until you
                // see it on the pieces you actually play with. It is drawn with
                // exactly the style the real boards resolve, so what is shown
                // here is what arrives on the next board.
                BoardView(position: .standard, interaction: .locked, style: appearance.style)
                    .frame(maxWidth: 200)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)
                    .accessibilityLabel("Preview of \(appearance.theme.name) squares with \(appearance.pieces.name) pieces")

                // Both rows are segmented controls with no visible label, and
                // both open on a segment called "Clay" — so the one cue that
                // could have told them apart was the one they shared. The
                // words are cheaper than the confusion.
                Text("Squares")
                    .typeRole(.label)

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

                Text("Pieces")
                    .typeRole(.label)

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
                    Text("A wooden knock as a move lands, with its own sound for a capture, for check, and for a move that won't go — one more when a game ends, and one as your clock passes ten seconds. Plays over your music or podcast without pausing it, and the silent switch stops it.")
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

                    // Naming the events is the point: the budget is what keeps
                    // haptics from feeling like a defect, and a user who can see
                    // how short the list is has no reason to reach for this
                    // switch. The list has to be the whole list, though —
                    // "nothing else" over four omissions teaches that the
                    // captions on this screen are not to be trusted, and that
                    // lesson generalises to the ones that are true.
                    Text("A tap when you lift a piece, land a move, take something, give check, or try a move that won't go — one when a game is won or lost, and one as your clock passes ten seconds.")
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            .animation(Motion.colorShift, value: appearance.theme)
        }
    }

    // MARK: - Progress

    /// The three things a user can do to the measurement itself: anchor it,
    /// retake it, or throw it away.
    ///
    /// All three were missing, and the first two are the ones that matter. A
    /// rating seeded by a rushed day-one calibration drives every opponent, the
    /// rung and the leak chart for the rest of the year, and until this section
    /// existed the only way to re-measure was to delete the app. The anchor is
    /// the other half of the same problem: Rookly's rating is measured against
    /// Rookly's own opponents, so without a number from outside there is no way
    /// to know whether a displayed 2000 is a real-world 1750.
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Progress")

            SettingsCard {
                externalRatingRows

                SettingsDivider()

                SettingsActionRow(
                    title: "Measure my rating again",
                    detail: viewModel.recalibrationCost,
                    action: { isConfirmingRecalibration = true }
                )

                SettingsDivider()

                SettingsActionRow(
                    title: "Delete all games and progress",
                    detail: viewModel.eraseCost,
                    isEnabled: viewModel.hasDataToErase,
                    action: { isConfirmingErase = true }
                )
            }
        }
    }

    /// The one number in the app that comes from outside it.
    ///
    /// Typed rather than fetched: nothing here talks to a network, and a field
    /// the user fills in once a quarter is the whole mechanism. What it buys is
    /// the offset — the app can then say how far its own scale sits from a
    /// rating the user already trusts, instead of leaving the year's goal
    /// measured in a unit with no external meaning.
    private var externalRatingRows: some View {
        // An explicit stack rather than a loose group, so the rows keep the
        // card's own rhythm instead of inheriting whatever a nested tuple gets.
        VStack(alignment: .leading, spacing: 12) {
            Text("External rating")
                .typeRole(.label)

            Text("Rookly's rating comes from Rookly's own opponents. Put your rapid rating from Lichess or Chess.com here and the app will show the gap between the two scales, on this screen and beside the Profile chart.")
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)

            Picker(
                "Where from",
                selection: Binding(
                    get: { viewModel.externalSource },
                    set: { viewModel.externalSource = $0 }
                )
            ) {
                ForEach(ExternalRatingAnchor.Source.allCases) { source in
                    Text(source.shortName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                TextField("Rating", text: $externalRatingText)
                    .typeRole(.body, monospacedDigits: true)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                    .accessibilityLabel("Your rapid rating on \(viewModel.externalSource.shortName)")

                Button("Save") {
                    viewModel.saveExternalRating(externalRatingText)
                }
                .buttonStyle(.secondaryAction)
                .disabled(ExternalRatingAnchor.parse(externalRatingText) == nil)
            }

            // Says what is stored and how stale it is. A rating entered in March is
            // still evidence in August, but it is weaker evidence, and the line
            // that reports the offset is the only place that can say so.
            Text(viewModel.externalAnchorNote)
                .typeRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Analysis

    /// One sentence the user can feel, and the instrument readings behind it.
    ///
    /// "Threads", "Hash" and "n/s" are words this app teaches nowhere, and four
    /// numbers nobody can change, sitting above About, read as settings that
    /// simply do not work. The only fact a player has any use for is how long
    /// they wait after a game, so that is the line that stays on screen; the
    /// readings are still one tap away for the reader who wanted them.
    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Analysis")

            SettingsCard {
                Text("Every finished game is analysed on this device, which takes about 10–20 seconds. Nothing is sent anywhere.")
                    .typeRole(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    isShowingEngineDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Engine details")
                            .typeRole(.label)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isShowingEngineDetails ? 180 : 0))
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityHint("Shows how the engine is configured on this device")

                if isShowingEngineDetails {
                    SettingsDivider()

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

                    // Tied to the same condition as the row above it: a caption
                    // claiming a measurement, over a list with no measurement
                    // in it, is the screen contradicting itself.
                    //
                    // "At launch" was dropped when the measurement started being
                    // remembered between launches: the number on screen may well
                    // have been taken days ago, and the sentence has to be true
                    // of the number actually shown.
                    Text(
                        model.deviceProfile.benchNPS > 0
                            ? "Measured on this device, then used to size each game's analysis."
                            : "Set for this device, then used to size each game's analysis."
                    )
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(Motion.snappy, value: isShowingEngineDetails)
        }
    }

    // MARK: - How it works

    /// The three decisions the app makes for the user, stated.
    ///
    /// Not offering the choice is defensible — one time control and one ladder
    /// is what makes five months of results comparable — but making it silently
    /// is not: "why did my rating move after that game" and "can I play 10+0"
    /// currently have no answer anywhere in the app.
    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "How Rookly works")

            SettingsCard {
                Text("Every game is 15 minutes each side, plus 10 seconds after each move. There is no other time control on purpose: results are only comparable across months if the clock never changes.")
                    .typeRole(.body)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                Text("The opponent is pitched near your rating, and your rating moves after every game you play here — by half the usual step, because take-backs and coaching are within reach in all of them. A game where the coach showed you the move and you took yours back does not count at all.")
                    .typeRole(.body)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                Text("The five calibration games are the exception: the rating they produced is the number you started with, so counting them again would use the same evidence twice.")
                    .typeRole(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "About")

            // The build ships daily to TestFlight, and a report that cannot
            // name which build it is about costs more time than the row does.
            SettingsCard {
                SettingsDetailRow(label: "Version", value: Self.versionText)
            }

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

// MARK: - Version

extension SettingsScreen {

    /// `1.0 (2026082102)`, from the bundle rather than from a constant that
    /// would need remembering on every release.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
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

/// A row that starts something, with the cost of it printed underneath.
///
/// Not a chevron row: nothing here navigates, and a chevron would promise a
/// screen the tap does not open. The detail line is required rather than
/// optional because both rows that use it are expensive — ninety minutes of
/// measurement, or the whole database — and a title alone would be exactly the
/// bare "Continue" the copy rules exist to prevent.
private struct SettingsActionRow: View {
    let title: String
    let detail: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .typeRole(.body)
                Text(detail)
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
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

// MARK: - The external anchor

/// A rating the user holds somewhere else, and the date they read it off.
///
/// ## Why this exists
///
/// Everything the app says about strength is measured against the app's own
/// engine opponents, whose `rating:` labels were assigned rather than measured
/// (see `Docs/humanizer-calibration.md`). That makes the displayed rating a
/// self-consistent progress metric — it moves the right way by the right amount
/// — and *not* a number comparable to a rating from anywhere else. A user can
/// therefore reach a displayed 2000 with no idea whether that is a real-world
/// 1750 or a real-world 2100, which is a problem for an app whose entire point
/// is a rating target.
///
/// One typed number fixes the reporting half of that: with an anchor on file
/// the app can print the gap between the two scales instead of implying there
/// is none. It deliberately does **not** shift the engine's labels — that
/// change wants roughly thirty games against a real population behind it, and
/// moving the ladder on the strength of one self-reported figure would replace
/// an honest unknown with a confident error.
///
/// Stored in the metrics table rather than as `AppSettings` columns: adding
/// columns to a CloudKit-synced row is a schema migration every device has to
/// agree on, and "a number and the day it was read" is exactly what the
/// `(key, window) -> value, updatedAt` store already holds.
struct ExternalRatingAnchor: Sendable, Hashable {

    enum Source: Int, Sendable, Hashable, CaseIterable, Identifiable {
        case lichess = 1
        case chessCom = 2

        var id: Int { rawValue }

        var shortName: String {
            switch self {
            case .lichess: return "Lichess"
            case .chessCom: return "Chess.com"
            }
        }

        /// Named with the time control, because a blitz rating and a rapid
        /// rating from the same site are 150 points apart and an anchor that
        /// does not say which one it is cannot be compared to anything.
        var fullName: String {
            switch self {
            case .lichess: return "Lichess rapid"
            case .chessCom: return "Chess.com rapid"
            }
        }
    }

    var rating: Int
    var source: Source
    /// When the user read the number off, which is what makes it stale.
    var measuredAt: Date

    static let ratingKey = "anchor.externalRating"
    static let sourceKey = "anchor.externalRatingSource"

    /// Ratings outside this are a typo, not a measurement. Refusing them beats
    /// printing an offset of nine hundred points beside the Profile chart.
    static let plausible = 400...3200

    /// Reads the stored anchor, or `nil` when the user has never entered one.
    ///
    /// Static and store-taking so Profile can read the same two rows Settings
    /// wrote without either screen owning the other's model — the offset has to
    /// appear beside the chart, which is the only place the rating is big enough
    /// for the question "compared to what" to occur to anyone.
    static func stored(in metrics: (any MetricStore)?) -> ExternalRatingAnchor? {
        guard
            let metrics,
            let row = try? metrics.metric(key: ratingKey, window: TrainingMetricKeys.allTime)
        else { return nil }
        let sourceRaw = (try? metrics.metric(key: sourceKey, window: TrainingMetricKeys.allTime))?.value
        return ExternalRatingAnchor(
            rating: Int(row.value.rounded()),
            source: Source(rawValue: Int(sourceRaw ?? 1)) ?? .lichess,
            // The row's own timestamp is the measurement date: the user reads
            // the number off the site and types it the same minute, so there is
            // no second date worth storing.
            measuredAt: row.updatedAt
        )
    }

    static func parse(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(digits), plausible.contains(value) else { return nil }
        return value
    }

    /// Beyond this the anchor is still evidence, but weaker, and the line that
    /// reports it says so. A quarter is the interval the calibration doc asks
    /// for a re-read on.
    static let freshnessDays = 92

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(measuredAt) > Double(Self.freshnessDays) * 86_400
    }

    /// `1420 on Lichess rapid, 12 Mar. Rookly reads 96 points higher.`
    ///
    /// The direction is spelled out rather than left as a signed number: this
    /// sentence exists so a reader can convert one scale into the other in
    /// their head, and "+96" does not say which way to apply it.
    func note(againstAppRating appRating: Int?, now: Date = Date()) -> String {
        let date = measuredAt.formatted(.dateTime.day().month(.abbreviated).year())
        var sentence = "\(rating) on \(source.fullName), entered \(date)."
        if let appRating {
            let gap = appRating - rating
            if gap == 0 {
                sentence += " Rookly reads the same."
            } else {
                let direction = gap > 0 ? "higher" : "lower"
                sentence += " Rookly reads \(abs(gap)) points \(direction)."
            }
        }
        if isStale(now: now) {
            sentence += " Worth re-reading — it has been more than three months."
        }
        return sentence
    }
}

// MARK: - Model

@Observable
@MainActor
final class SettingsModel {

    private(set) var soundEnabled: Bool

    /// The playing rating, read for the two sentences that have to price what a
    /// tap costs. `nil` when the settings row could not be read, in which case
    /// both of those sentences drop the number rather than invent one.
    private(set) var playingRating: Int?

    private(set) var externalAnchor: ExternalRatingAnchor?

    /// Which site the picker is on. Follows the stored anchor when there is
    /// one, so re-entering next quarter starts where the user left off.
    var externalSource: ExternalRatingAnchor.Source = .lichess

    /// What a wipe would take. `nil` until the first read lands.
    private(set) var dataSummary: UserDatabase.UserDataSummary?

    private let store: (any AppSettingsStore)?
    private let metrics: (any MetricStore)?
    private let database: UserDatabase?

    /// Seeded from the service rather than from the compiled-in default.
    ///
    /// `Sound.prepare()` runs at launch, so by the time this screen is built the
    /// service already agrees with the stored row — and a switch that draws
    /// "on" for a frame and then flips off, in front of a user who turned sound
    /// off weeks ago, reads as the app having forgotten. ``load()`` still runs
    /// and is still the authority; this only decides what is drawn first.
    init(
        store: (any AppSettingsStore)? = AppDatabase.sharedIfAvailable?.settings,
        metrics: (any MetricStore)? = AppDatabase.sharedIfAvailable?.metrics,
        database: UserDatabase? = AppDatabase.sharedIfAvailable?.user
    ) {
        self.store = store
        self.metrics = metrics
        self.database = database
        self.soundEnabled = Sound.isEnabled
    }

    func load() {
        if let stored = try? store?.current() {
            // Reading the row is also what installs the mirror, so arriving here
            // leaves `Sound.isEnabled` agreeing with the switch even if nothing
            // called `Sound.prepare` at launch. The alternative is a toggle that
            // reads "off" above a board that is still clicking.
            soundEnabled = stored.soundOn
            Sound.isEnabled = stored.soundOn
            playingRating = Int(stored.userRating.rounded())
        }
        loadExternalAnchor()
        dataSummary = try? database?.userDataSummary()
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

    // MARK: External anchor

    private func loadExternalAnchor() {
        externalAnchor = ExternalRatingAnchor.stored(in: metrics)
        // The picker follows the stored anchor so re-entering next quarter
        // starts on the site the user actually plays on.
        if let source = externalAnchor?.source { externalSource = source }
    }

    /// Stores a typed rating, or does nothing if it is not a plausible one.
    ///
    /// Silent refusal rather than an alert: the Save button is disabled for
    /// exactly the inputs this rejects, so reaching here with a bad value means
    /// the two disagreed, and an alert would be reporting a bug to the user.
    func saveExternalRating(_ text: String, now: Date = Date()) {
        guard let rating = ExternalRatingAnchor.parse(text), let metrics else { return }
        try? metrics.set(ExternalRatingAnchor.ratingKey, value: Double(rating), sampleCount: 1, at: now)
        try? metrics.set(
            ExternalRatingAnchor.sourceKey,
            value: Double(externalSource.rawValue),
            sampleCount: 1,
            at: now
        )
        externalAnchor = ExternalRatingAnchor(rating: rating, source: externalSource, measuredAt: now)
    }

    var externalAnchorNote: String {
        guard let externalAnchor else {
            return "Nothing stored yet, so the app cannot say how its scale compares to any other."
        }
        return externalAnchor.note(againstAppRating: playingRating)
    }

    // MARK: Recalibration and erasure

    /// Stated in full before the tap, because ninety minutes is the largest
    /// single cost the app ever asks for and it is spent in one sitting.
    var recalibrationCost: String {
        let held = playingRating.map { "Your current \($0) stays until it finishes." }
            ?? "Your current rating stays until it finishes."
        return "Five games and twenty puzzles, about 90 minutes. \(held)"
    }

    var hasDataToErase: Bool { dataSummary.map { !$0.isEmpty } ?? false }

    /// The loss in counts, not in adjectives.
    var eraseCost: String {
        guard let dataSummary, !dataSummary.isEmpty else {
            return "Nothing has been recorded on this device yet."
        }
        var parts: [String] = []
        if dataSummary.games > 0 {
            parts.append("\(dataSummary.games) game\(dataSummary.games == 1 ? "" : "s")")
        }
        if dataSummary.moments > 0 {
            parts.append("\(dataSummary.moments) reviewed moment\(dataSummary.moments == 1 ? "" : "s")")
        }
        if dataSummary.cards > 0 {
            parts.append("\(dataSummary.cards) review card\(dataSummary.cards == 1 ? "" : "s")")
        }
        parts.append("your \(dataSummary.rating) rating")
        let list = parts.count == 1
            ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return "\(list). Nothing is stored anywhere else, so this cannot be undone. Your board and sound settings stay."
    }

    /// Empties the database and re-reads it, so the screen's own counts go to
    /// zero in the same frame the rows disappear from every other screen.
    func eraseEverything() {
        try? database?.deleteAllUserData()
        load()
    }
}
