import BoardUI
import ChessKit
import Database
import SwiftUI
import TrainingCore

/// The play surface.
///
/// ## The shape
///
/// Exit, then one status pill, then the screen's title, then the opponent, then
/// the board, then your own side of the table. Every one of those is a fixed
/// slot: over forty moves the only things that change are the numbers inside the
/// pill, one line of the opponent's text, and the pieces. Nothing resizes,
/// nothing slides, nothing spins.
///
/// The board runs edge to edge and sits about a third of the way down, with the
/// space beneath it deliberately empty — that space is where interruption sheets
/// and the result banner arrive, which is what lets both of them appear *without
/// the board moving or being covered*. It is not wasted space; it is the reason
/// the rest of the design works.
///
/// ## Focus
///
/// During a game the tab bar and the navigation bar are gone and the exit is a
/// grey glyph in the top-left corner: present, never prominent, never accented.
/// Leaving mid-game resigns, so it asks first — from a sheet where the safe
/// answer is the filled button.
struct PlayScreen: View {

    @Environment(AppModel.self) private var model

    @State private var session: GameSession?
    @State private var sequencer = GameEndSequencer()
    @State private var manualSheet: PlaySheetKind?
    @State private var summaryTarget: GameSummaryTarget?
    @State private var boardFlipped = false
    @State private var lowTimeWarned = false
    @State private var picker: OpponentPicker = .unmeasured
    /// The guided verdict currently on screen, and the move it belongs to.
    @State private var guidedFlash: GuidedFlash?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Alternate colours across games so the user isn't always White. Playing
    /// only one side hides half the openings and half the mistakes.
    private var userColor: Piece.Color {
        picker.gamesPlayed.isMultiple(of: 2) ? .white : .black
    }

    /// Measured so a sheet can be sized to the space *below* the board.
    @State private var boardFrame: CGRect = .zero
    /// The window's bottom edge and the safe area's. Both are needed: the gap
    /// between them is the home-indicator strip, which a sheet consumes on top
    /// of its detent height, and budgeting for it is the difference between a
    /// sheet that clears the board and one that clips its last rank.
    @State private var screenBottom: CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0

    /// How far the board shrinks on a screen where a sheet cannot otherwise
    /// clear it. Scaling from the top raises the bottom edge without moving the
    /// top one and without cropping a single square.
    private static let compressedBoardScale: CGFloat = 0.90

    var body: some View {
        Group {
            if let session {
                activeGame(session)
            } else {
                startPrompt
            }
        }
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // `startGame` re-reads the picker itself, so reading here as well
            // would run the same two queries twice on the way into a game.
            if !consumePendingRequest() {
                // Loaded on appear so the start prompt names the opponent you
                // will actually face, not a placeholder that changes when you
                // tap.
                picker = .current()
            }
        }
        // The tab is kept alive once visited, so a request arriving while this
        // screen already exists would never reach `task`. Both entry points run
        // the same consume, which is what stops a stale flag from starting a
        // game later on a screen the user came back to for something else.
        .onChange(of: model.pendingPlayRequest) { _, requested in
            if requested { consumePendingRequest() }
        }
        // The summary's CTA sends the review to the Today stack, so a finished
        // game's next step is on another tab. Without this the board and its
        // pushed summary stay here, and opening Play tomorrow lands on last
        // night's summary instead of an offer to play. Guarded on `isFinished`
        // so a game in progress is never dropped — during a game there is no tab
        // bar to leave by anyway.
        .onChange(of: model.selectedTab) { _, tab in
            guard tab != .play, session?.isFinished == true else { return }
            summaryTarget = nil
            leaveGame()
        }
        .toolbar(session == nil ? .visible : .hidden, for: .navigationBar)
        .toolbar(session == nil ? .visible : .hidden, for: .tabBar)
        // The app's own tab bar lives outside the `TabView`, where the modifier
        // above cannot reach it. Mirrored through the model instead, and cleared
        // on the way out so a game left by any route restores the bar.
        // Pushing the summary fires `onDisappear`, and coming back does not
        // change `session == nil` — so without the appear half, the same
        // finished board had a tab bar or not depending on which door was used.
        .onAppear { model.isPlayingGame = session != nil }
        .onChange(of: session == nil) { _, idle in model.isPlayingGame = !idle }
        .onDisappear { model.isPlayingGame = false }
        .navigationDestination(item: $summaryTarget) { target in
            GameSummaryScreen(target: target)
        }
    }

    // MARK: - Start

    private var startPrompt: some View {
        VStack(spacing: 24) {
            Spacer()

            BoardView(position: .standard, interaction: .locked, style: BoardAppearance.shared.style)
                .frame(maxWidth: 280)
                .opacity(0.35)

            VStack(spacing: 6) {
                Text("Sparring")
                    .typeRole(.title)
                // Not "three moments": the number is a property of the game
                // you are about to play, and this screen is standing in front
                // of it. A clean game yields one moment or none, and a promise
                // made here is one the summary screen has to break. See
                // `DailyProgress.momentsAvailable` for the same rule on Today.
                Text("One game, then the moments worth studying.")
                    .typeRole(.caption)
            }

            Spacer()

            VStack(spacing: 8) {
                // Priced from the same constant Today's CTA prices from.
                // Arriving through the Play tab, this button was the whole
                // offer: a name, and nothing about the clock, the colour, the
                // rating, or how long the evening was about to get. Two screens
                // quoting two different numbers for one game would be the same
                // failure wearing a fix.
                Button("Play \(opponentName) · \(gamePrice)") {
                    startGame()
                }
                .buttonStyle(.primaryAction)

                Text(sparringCaption)
                    .typeRole(.caption)
                    .multilineTextAlignment(.center)

                // Offered only when there is a habit to coach. A guided game
                // with no focus would pause to ask about nothing in particular,
                // which is the fastest way to teach someone to dismiss the
                // pauses unread.
                if let habit = guidedFocusHabit {
                    Button("Guided game · \(gamePrice)") {
                        startGame(guidedBy: habit)
                    }
                    .buttonStyle(.secondaryAction)
                    .padding(.top, 8)

                    // The habit moved off the button and into the caption on
                    // purpose: what a first-time reader needs is not the name of
                    // the habit but the fact that this game stops and asks them
                    // things.
                    Text(guidedCaption(habit))
                        .typeRole(.caption)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom)
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
    }

    private var opponentName: String {
        picker.opponent.name
    }

    private var gamePrice: String {
        "~\(TodayStep.game.estimatedMinutes) min"
    }

    /// Who, how strong, which side, and what the interruption budget is.
    ///
    /// The cycle framing is here rather than nowhere because the opponent's
    /// rating moves by up to 150 points between games; unexplained, that reads
    /// as the named person drifting rather than as a plan.
    ///
    /// The take-back sentence comes from the session rather than being typed
    /// here, because it carries the clock condition with it: second try stops
    /// firing in the last minute, and a caption that promised it unconditionally
    /// left the user to discover the boundary at the worst possible moment and
    /// read it as the coach breaking.
    private var sparringCaption: String {
        var text = "\(opponentName) · \(opponentRating)"
        if let framing = picker.framing { text += " · \(framing)" }
        let color = userColor == .white ? "White" : "Black"
        text += ". You play \(color), 15+10. \(GameSession.secondTryPromise)"
        return text
    }

    /// What "guided" costs, in the order the reader needs it: the habit, the
    /// interruptions, and what is switched off to pay for them.
    ///
    /// It does not claim the game counts less. Sparring carries second-try, so
    /// `GameSession.ratingWeight` already puts both modes on the same half-K
    /// tier — a differential the copy invented would be the wrong kind of
    /// precise.
    private func guidedCaption(_ habit: Habit) -> String {
        // The pause count comes from the budget that enforces it, so the promise
        // cannot outlive the rule.
        let pauses = GuidedMode.Budget.default.maxPausesPerGame
        return "\(habit.microGoalTitle). Stops up to \(pauses) times to ask what the position needs. "
            + "No take-backs, and the pauses are off the clock."
    }

    /// The week's habit, or nil when there is nothing to coach yet.
    ///
    /// Read straight from storage rather than through a `MetricsService`
    /// refresh: selection replays up to twenty games, and the start prompt only
    /// needs to know which habit is in force — which selection already wrote
    /// down. A fresh install has no focus, and the guided option correctly does
    /// not appear until the first weekly selection has run.
    private var guidedFocusHabit: Habit? {
        guard let database = AppDatabase.sharedIfAvailable else { return nil }
        return MetricsService.storedFocus(
            metrics: database.metrics,
            settings: database.settings
        )?.habit
    }

    private var opponentRating: Int {
        picker.rating
    }

    /// Starts the game Today's CTA already promised.
    ///
    /// Today's button names the opponent and the price, so arriving here to a
    /// second `Play Oscar` button would be the app asking twice for one
    /// decision. A game in progress wins — but the request is still consumed,
    /// because a flag left set is a game that starts out of nowhere later.
    ///
    /// - Returns: whether a game was started.
    @discardableResult
    private func consumePendingRequest() -> Bool {
        // Taken before the guard, not inside it: a habit left on the model is a
        // sparring game that turns coached three taps later.
        let habit = model.consumeGuidedRequest()
        guard model.consumePlayRequest(), session == nil else { return false }
        startGame(guidedBy: habit)
        return true
    }

    private func startGame(guidedBy habit: Habit? = nil) {
        // Re-read on each start: the rating moves after every rated game, and
        // the games-played count is what advances the offset cycle.
        picker = .current()

        // Guided and sparring are the same game with different interruptions,
        // so they share every other parameter. They differ in what they are
        // evidence of: a guided game is coached, so the ladder discounts it and
        // `guided.scanThreatsHitRate` — which gates the required rung-2 skill —
        // is only ever measured here.
        let configuration = habit.map {
            GameSession.Configuration.guided(
                userColor: userColor,
                opponentRating: picker.rating,
                focusHabit: $0
            )
        } ?? GameSession.Configuration.sparring(
            userColor: userColor,
            opponentRating: picker.rating
        )
        let newSession = GameSession(configuration: configuration, engineService: model.engineService)
        sequencer.reset()
        manualSheet = nil
        summaryTarget = nil
        boardFlipped = false
        lowTimeWarned = false
        guidedFlash = nil
        session = newSession
        Task { await newSession.start() }
    }

    private func leaveGame() {
        session = nil
        sequencer.reset()
        manualSheet = nil
        lowTimeWarned = false
        guidedFlash = nil
        // The game that just ended moved the rating and advanced the offset
        // cycle, so the picker read before it is stale. Without this the start
        // prompt says "Play Oscar" while Today says "Play Petra" — and tapping
        // it starts Petra's game, because `startGame` re-reads. The label was
        // the only thing lying.
        picker = .current()
    }

    // MARK: - Active game

    @ViewBuilder
    private func activeGame(_ session: GameSession) -> some View {
        let opponent = OpponentRoster.opponent(forRating: session.configuration.opponentRating)
        let sheetKind = currentSheet(session)

        let phaseSheetIsUp = isPhaseDriven(session)

        VStack(spacing: 0) {
            topRow(session, locked: phaseSheetIsUp)
                .padding(.horizontal, 16)
                .padding(.top, 4)

            titleRow(session)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            OpponentPresenceView(opponent: opponent, line: opponentLine(session, opponent: opponent))
                .padding(.horizontal, 16)
                .padding(.top, 10)

            // What the opponent has taken, directly under their name and above
            // their side of the board — the same place it sits on a real table.
            CapturedTray(
                side: session.configuration.userColor == .white ? .black : .white,
                position: session.board.position,
                renderer: BoardAppearance.shared.style.pieceSet
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)

            BoardView(
                position: session.board.position,
                orientation: orientation(session),
                interaction: interaction(for: session),
                highlights: highlights(for: session),
                arrows: arrows(for: session),
                style: BoardAppearance.shared.style
            )
            .scaleEffect(boardScale(for: sheetKind), anchor: .top)
            .animation(Motion.gentle, value: boardScale(for: sheetKind))
            .padding(.top, 12)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { boardFrame = $0 }

            bottomRow(session, locked: phaseSheetIsUp)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { safeAreaBottom = $0 }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .background {
            // Ignores the safe area so its own bottom edge *is* the window's,
            // which is the measurement the sheet detents need.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { screenBottom = $0 }
        }
        .overlay(alignment: .bottom) {
            endOverlay(session, opponent: opponent)
        }
        .animation(Motion.standard, value: sequencer.stage)
        .task(id: session.gameID) { await tick(session) }
        // A phase sheet wins the sheet binding, so a `manualSheet` set while one
        // is up never appears — and then pops the moment the phase resolves, on
        // top of a board the user has gone back to playing. Cleared here so the
        // stale request cannot survive the pause.
        .onChange(of: phaseSheetIsUp) { _, isUp in
            if isUp { manualSheet = nil }
        }
        // The verdict on a guided answer, held just long enough to read.
        .onChange(of: latestGuidedVerdict(session)) { _, verdict in
            guidedFlash = verdict
        }
        .task(id: guidedFlash) { await expireGuidedFlash() }
        .onChange(of: finishedOutcome(session)) { _, outcome in
            guard let outcome else { return }
            Task {
                await sequencer.gameFinished()
                // Fired as the banner rises rather than on the final move: the
                // 600ms hold is meant to be quiet, and a buzz during it is a
                // chrome change by another route.
                //
                // A draw gets nothing. The haptic vocabulary has success and
                // error and no third thing, and a draw is neither — buzzing
                // "error" at somebody who held a worse position is a small lie
                // told in the one channel that cannot be ignored.
                if let won = outcome.userWon {
                    Haptics.play(.gameEnd(won: won))
                }
                // Outside that guard on purpose: the sound is the same for a
                // win, a loss and a draw, so unlike the haptic it has nothing
                // to withhold from a player who drew.
                Sound.play(.gameEnd)
            }
        }
        .sheet(item: sheetBinding(session)) { kind in
            sheetBody(kind, session: session)
                .presentationDetents(detents(for: kind))
                // Removes the system dimming layer, which is the whole point:
                // the board stays visible *and* stays playable underneath. The
                // guided pause is the one sheet that says no, and it says why.
                .presentationBackgroundInteraction(
                    kind.allowsBoardInteraction ? .enabled : .disabled
                )
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(CornerRadius.sheet)
        }
    }

    // MARK: Rows

    private func topRow(_ session: GameSession, locked: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                if session.isFinished {
                    // A finished game's next step is the review, not another
                    // game. Clearing the board left the user looking at "Play
                    // Oscar", which is the app asking them to play again in the
                    // one moment it has something better to offer.
                    leaveGame()
                    model.selectedTab = .today
                } else {
                    manualSheet = .leave
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.secondary)
            .disabled(locked)
            .opacity(locked ? 0.35 : 1)
            .accessibilityLabel(session.isFinished ? "Done with this game" : "Leave this game")

            Spacer(minLength: 8)

            PlayStatusPill(
                eval: evalReading(session),
                opponentClock: clockState(session, isUser: false),
                userClock: clockState(session, isUser: true),
                clocksDimmed: session.isFinished
            )
        }
    }

    private func titleRow(_ session: GameSession) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.configuration.mode.capitalized)
                    .typeRole(.title)
                // The start prompt named the habit and then the board said only
                // "Guided". By move 20 nobody remembers which of nine they are
                // practising. Present for the whole game or not at all, so the
                // row's height is fixed the moment the game starts.
                if let habit = session.configuration.guidedFocusHabit {
                    Text(habit.microGoalTitle)
                        .typeRole(.caption)
                }
            }
            Spacer(minLength: 12)
            // The qualifier a section header carries: same small-caps style,
            // dimmer, right-aligned.
            Text(timeControl(session))
                .typeRole(.label, monospacedDigits: true)
        }
    }

    private func bottomRow(_ session: GameSession, locked: Bool) -> some View {
        HStack(spacing: 10) {
            Text(session.configuration.userColor == .white ? "You · White" : "You · Black")
                .typeRole(.caption)

            CapturedTray(
                side: session.configuration.userColor,
                position: session.board.position,
                renderer: BoardAppearance.shared.style.pieceSet
            )

            Spacer(minLength: 0)

            Button {
                manualSheet = .options
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(.secondary)
            // Both chrome buttons go quiet while a coaching sheet is up. They
            // used to stay lit and do nothing: the phase sheet owns the binding,
            // so the tap was swallowed with no sound and no sheet.
            .disabled(locked)
            .opacity(locked ? 0.35 : 1)
            .accessibilityLabel("Game options")
        }
    }

    // MARK: Game end

    @ViewBuilder
    private func endOverlay(_ session: GameSession, opponent: OpponentRoster.Opponent) -> some View {
        if let outcome = finishedOutcome(session) {
            let banner = GameEndBanner.make(
                outcome: outcome,
                opponentName: opponent.name,
                // The banner is the one beat every finished game passes through.
                // Read only on the summary, a failed write was invisible to
                // anyone who collapsed the banner or tapped the exit.
                persistenceFailure: session.persistenceFailure
            )

            switch sequencer.stage {
            case .banner:
                GameResultBanner(
                    banner: banner,
                    onCollapse: { sequencer.collapse() },
                    onContinue: { openSummary(session, outcome: outcome, opponent: opponent) }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))

            case .collapsed:
                GameResultChip(title: "Summary") { sequencer.expand() }
                    .padding(.bottom, 16)
                    .transition(.opacity)

            // `.holding` draws nothing on purpose: for 600ms after the last move
            // the screen does not change at all.
            case .none, .holding:
                EmptyView()
            }
        }
    }

    private func openSummary(
        _ session: GameSession,
        outcome: GameSession.Outcome,
        opponent: OpponentRoster.Opponent
    ) {
        summaryTarget = GameSummaryTarget(
            gameID: session.gameID,
            outcome: outcome,
            opponentName: opponent.name,
            opponentRating: session.configuration.opponentRating,
            plyCount: session.moves.count,
            persistenceFailure: session.persistenceFailure
        )
    }

    // MARK: Sheets

    private func currentSheet(_ session: GameSession) -> PlaySheetKind? {
        if case .secondTry = session.phase { return .secondTry }
        if case .guidedPrompt = session.phase { return .guidedPrompt }
        return manualSheet
    }

    /// Whether the phase — not a tap — is what is showing a sheet.
    private func isPhaseDriven(_ session: GameSession) -> Bool {
        switch session.phase {
        case .secondTry, .guidedPrompt: true
        default: false
        }
    }

    private func sheetBinding(_ session: GameSession) -> Binding<PlaySheetKind?> {
        Binding(
            get: { currentSheet(session) },
            set: { newValue in
                // Pulling the coaching card down is an answer, not an escape:
                // it means "let me look at it again", so the move stays taken
                // back and the board goes live.
                if newValue == nil, case .secondTry = session.phase {
                    session.resumeAfterSecondTry()
                }
                // Pulling the guided card down ends the pause too. It counts as
                // asking to be shown rather than as answering: a question
                // dismissed unanswered is not evidence the idea landed.
                if newValue == nil, case .guidedPrompt = session.phase {
                    session.resolveGuidedPrompt(revealed: true)
                }
                manualSheet = newValue
            }
        )
    }

    /// The sheet, made reachable at every text size.
    ///
    /// At accessibility sizes a hundred-character question runs to five lines,
    /// the content's spacer collapses to nothing, and the action row is pushed
    /// below the detent where it cannot be tapped — a coaching pause with no way
    /// out while the game waits. Scrolling is the honest answer: the user chose
    /// legibility over layout, so the board gives up its clearance rather than
    /// the sheet losing its buttons.
    @ViewBuilder
    private func sheetBody(_ kind: PlaySheetKind, session: GameSession) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView { sheetContent(kind, session: session) }
        } else {
            sheetContent(kind, session: session)
        }
    }

    @ViewBuilder
    private func sheetContent(_ kind: PlaySheetKind, session: GameSession) -> some View {
        switch kind {
        case .secondTry:
            if case .secondTry(let state) = session.phase {
                SecondTrySheet(state: state, session: session)
            }
        case .guidedPrompt:
            if case .guidedPrompt(let state) = session.phase {
                GuidedPromptSheet(state: state) { revealed in
                    session.resolveGuidedPrompt(revealed: revealed)
                }
            }
        case .options:
            GameOptionsSheet(
                isFinished: session.isFinished,
                onFlip: { boardFlipped.toggle() },
                // Offered only on the user's own move, which is also the only
                // time the opponent has a settled position to answer about.
                onOfferDraw: session.canOfferDraw ? { session.offerDraw() } : nil,
                // Resigning from here keeps the player on the board and runs the
                // normal end-of-game handoff; only the exit in the corner leaves.
                onResign: { session.resign() },
                onNewGame: { startGame() }
            )
        case .leave:
            LeaveGameSheet(
                onKeepPlaying: { manualSheet = nil },
                // Resigns and stays, exactly as the options-sheet resign does.
                // Clearing the board here dropped the user on the start prompt
                // with no result, no summary and no route to the review — the
                // most common way a bad game ends, and the one path out of it
                // that showed them nothing.
                onLeave: {
                    session.resign()
                    manualSheet = nil
                }
            )
        }
    }

    private func detents(for kind: PlaySheetKind) -> Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.height(detentHeight(for: kind))]
    }

    /// The tallest this sheet may be without its top edge crossing the board.
    ///
    /// Never rounded up past the space available. The rule that the board stays
    /// visible is absolute, so when the content does not fit, the *content*
    /// gives — its spacer collapses — and the board keeps its ground.
    private func detentHeight(for kind: PlaySheetKind) -> CGFloat {
        min(kind.preferredHeight, spaceBelowBoard(for: kind))
    }

    private func spaceBelowBoard(for kind: PlaySheetKind) -> CGFloat {
        guard boardFrame.height > 0, screenBottom > boardFrame.maxY else {
            return kind.preferredHeight
        }
        let atFullSize = clearance
        guard atFullSize < kind.preferredHeight else { return atFullSize }
        // The board gives up a tenth of its side rather than being covered or
        // cropped — worth about another 40pt on a phone, and the last resort
        // before a sheet would have to sit over the position.
        return atFullSize + boardFrame.height * (1 - Self.compressedBoardScale)
    }

    /// Space between the board's bottom edge and the top a sheet may occupy.
    ///
    /// Two subtractions, both deliberate. The 10pt gap keeps the sheet from
    /// kissing the board's last rank. The home-indicator strip comes off
    /// because a detent height and the strip are *added* by the system on some
    /// devices — budgeting for it costs a little sheet height and guarantees
    /// the one rule that cannot bend: the board stays whole.
    private var clearance: CGFloat {
        let homeIndicator = max(0, screenBottom - safeAreaBottom)
        return screenBottom - boardFrame.maxY - 10 - homeIndicator
    }

    private func boardScale(for kind: PlaySheetKind?) -> CGFloat {
        guard let kind, boardFrame.height > 0, screenBottom > boardFrame.maxY else { return 1 }
        return clearance < kind.preferredHeight ? Self.compressedBoardScale : 1
    }

    // MARK: Clock

    /// One loop for the whole game: charges elapsed time so a player who simply
    /// stops moving still flags, and notices the ten-second crossing so it can
    /// be felt once rather than watched for.
    private func tick(_ session: GameSession) async {
        var previousUserMs = session.userClockMs

        while !Task.isCancelled, !session.isFinished {
            session.checkClock()

            let userMs = PlayClock.remainingMs(
                chargedMs: session.userClockMs,
                startedAt: session.moveStartedAt,
                now: .now,
                isRunning: isUserSideActive(session)
            )
            // Once, on the way past ten seconds, and only for the clock the user
            // is actually burning.
            if !lowTimeWarned, PlayClock.crossedCritical(previousMs: previousUserMs, currentMs: userMs) {
                lowTimeWarned = true
                Haptics.play(.clockWarning)
                Sound.play(.clockWarning)
            }
            previousUserMs = userMs

            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func clockState(_ session: GameSession, isUser: Bool) -> PlayStatusPill.ClockState {
        let active = isUser ? isUserSideActive(session) : isOpponentSideActive(session)
        return PlayStatusPill.ClockState(
            chargedMs: isUser ? session.userClockMs : session.opponentClockMs,
            startedAt: session.moveStartedAt,
            isRunning: active,
            isActive: active,
            widthSample: PlayClock.widthSample(baseSeconds: session.configuration.baseSeconds),
            accessibilityName: isUser ? "Your clock" : "Their clock"
        )
    }

    private func isUserSideActive(_ session: GameSession) -> Bool {
        switch session.phase {
        // Coaching pauses are nobody's move. Both of them reset `moveStartedAt`
        // when they resume, so the time spent reading is never charged — which
        // meant a clock that ticked down through the sheet and then leapt back
        // up on "Try again", reading as a bug and training hurry at the one
        // moment the app is asking for deliberate thought.
        case .userToMove: true
        default: false
        }
    }

    private func isOpponentSideActive(_ session: GameSession) -> Bool {
        session.phase == .opponentThinking
    }

    private func timeControl(_ session: GameSession) -> String {
        let minutes = session.configuration.baseSeconds / 60
        return "\(minutes)+\(session.configuration.incrementSeconds)"
    }

    // MARK: Readings

    private func evalReading(_ session: GameSession) -> PlayEvalReading? {
        // Guided mode is the one place the session sanctions showing the
        // engine's own number, so it is the one place this segment appears at
        // all. In sparring the number that describes the position is material,
        // and `CapturedTray` already prints it under whoever is ahead, beside
        // the pieces that explain it — printing it up here as well gave the user
        // two readouts for one number and no way to know they meant the same
        // thing, which in guided games they do not.
        guard session.configuration.guidedEnabled else { return nil }
        return .winPercent(session.currentEvaluation)
    }

    private func opponentLine(_ session: GameSession, opponent: OpponentRoster.Opponent) -> OpponentLine {
        let isThinking = session.phase == .opponentThinking
        let lastUserSAN = session.moves.last(where: \.byUser)?.san
        // Short-circuited so the move generation behind `lastMoveCanBeAnswered`
        // only runs on the one render where a capture is being spoken about.
        let capturedAndAnswerable =
            isThinking && lastUserSAN?.contains("x") == true && session.lastMoveCanBeAnswered

        return OpponentStatusLine.line(
            for: OpponentStatusLine.Input(
                trait: opponent.trait,
                isThinking: isThinking,
                ply: session.moves.count,
                lastUserSAN: lastUserSAN,
                materialBalance: PlayEvalReading.materialBalance(
                    in: session.board.position,
                    for: session.configuration.userColor
                ),
                canAnswerLastCapture: capturedAndAnswerable,
                guidedVerdict: guidedFlash?.hit
            )
        )
    }

    // MARK: Guided verdict

    /// A graded guided answer, and the move it was graded on.
    ///
    /// The ply is carried so a second prompt later in the game re-arms the
    /// flash rather than being swallowed as "the same verdict".
    private struct GuidedFlash: Equatable {
        var ply: Int
        var hit: Bool
    }

    /// The verdict on the most recent user move, if it answered a prompt.
    ///
    /// `GameSession` grades the answering move as it records it and writes the
    /// result onto the move — and, until now, nothing read it back. A pause that
    /// asks a question, is answered, and then says nothing is not asking a
    /// question; the habit cannot be trained without knowing when it worked.
    private func latestGuidedVerdict(_ session: GameSession) -> GuidedFlash? {
        guard let move = session.moves.last(where: \.byUser), let hit = move.guidedPromptHit else {
            return nil
        }
        return GuidedFlash(ply: move.ply, hit: hit)
    }

    /// Long enough to read one sentence, and gone before the position needs the
    /// slot back for the opponent.
    private func expireGuidedFlash() async {
        guard guidedFlash != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        guidedFlash = nil
    }

    private func finishedOutcome(_ session: GameSession) -> GameSession.Outcome? {
        guard case .finished(let outcome) = session.phase else { return nil }
        return outcome
    }

    // MARK: Board

    private func orientation(_ session: GameSession) -> Piece.Color {
        boardFlipped ? session.configuration.userColor.opposite : session.configuration.userColor
    }

    private func interaction(for session: GameSession) -> BoardInteraction {
        switch session.phase {
        case .userToMove:
            break
        // The second-try sheet says the board is still live, and its whole
        // instruction is "find another move" — so playing one straight from the
        // board has to be the answer. It was not: the phase locked the board, so
        // a piece dragged during the pause did nothing at all, no sound and no
        // snap-back, until the user worked out that a button had to be pressed
        // first. Resuming implicitly costs the same as pressing it, including
        // the unrated mark once the refutation has been drawn.
        case .secondTry:
            break
        default:
            return .replay
        }

        return .userMove { from, to in
            // The board asks; GameSession decides. Returning `.rejected` here is
            // exactly how an illegal move snaps back — and how second-try
            // retracts a blunder.
            guard session.board.canMove(pieceAt: from, to: to) else {
                Sound.play(.illegalDrop)
                return .rejected
            }

            // A promoting pawn has to be asked about before the move is played,
            // because the piece it becomes is part of the move. `BoardUI`
            // presents its inline picker over the destination square and calls
            // back with the choice.
            //
            // Underpromotion is reachable on purpose rather than auto-queening:
            // `underPromotion` is in the app's own theme vocabulary, and a
            // board that silently queens cannot express an idea the training
            // side of the app teaches.
            if session.isPromotion(from: from, to: to) {
                return .needsPromotion(complete: { kind in
                    Task {
                        // A no-op in `.userToMove`; the session guards on the
                        // phase. Inside the task rather than inline so the phase
                        // does not change while the board is still handling the
                        // gesture that caused it.
                        session.resumeAfterSecondTry()
                        await session.attemptUserMove(from: from, to: to, promoting: kind)
                    }
                    return .accepted
                })
            }

            Task {
                session.resumeAfterSecondTry()
                await session.attemptUserMove(from: from, to: to)
            }
            return .accepted
        }
    }

    private func highlights(for session: GameSession) -> [SquareHighlight] {
        var result: [SquareHighlight] = []
        if let last = session.lastMove {
            result += SquareHighlight.lastMove(from: last.from, to: last.to)
        }
        if case .secondTry(let state) = session.phase, state.hintLevel >= 1, let square = state.hintSquare {
            result.append(SquareHighlight(square, .hint))
        }
        return result
    }

    private func arrows(for session: GameSession) -> [BoardArrow] {
        guard case .secondTry(let state) = session.phase, state.hintLevel >= 2,
            let arrow = state.refutationArrow
        else { return [] }
        return [BoardArrow(from: arrow.from, to: arrow.to, style: .threat)]
    }
}
