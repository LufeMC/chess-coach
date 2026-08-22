//
//  EndgameDrillScreen.swift
//  ChessCoach
//

import BoardUI
import ChessKit
import EngineKit
import SwiftUI
import TrainingCore

// MARK: - Recording

/// Where a finished drill run is written.
///
/// `TrainingService` owns the streak bookkeeping — and, through
/// `EndgameDrillRun`, the pass criteria themselves. This protocol exists only so
/// the screen can be driven without one.
@MainActor
protocol DrillOutcomeRecorder: AnyObject {
    @discardableResult
    func recordDrill(_ run: EndgameDrillRun) async -> Double
    @discardableResult
    func recordKPKSet(runs: [EndgameDrillRun]) async -> Double
}

extension TrainingService: DrillOutcomeRecorder {}

// MARK: - Engine opponent

/// The engine, playing the defending (or attacking) side of a drill.
///
/// Full strength and no humanising. A drill asks whether the user knows a
/// technique, and a technique is only proven against best defence — an opponent
/// that occasionally wanders would let a user pass Lucena without ever building
/// the bridge.
struct EngineDrillOpponent: DrillOpponent {

    let engine: EngineService
    /// Short: the user is waiting, and these positions are trivial to search.
    var movetimeMs: Int = 300

    func reply(fen: String) async throws -> String? {
        let device = await engine.deviceProfile
        await engine.acquire(
            .play,
            configuration: EngineService.Configuration(
                multiPV: 1,
                threads: device.threads,
                hashMB: device.hashMB
            )
        )
        defer { Task { await engine.release(.play) } }
        let result = try await engine.search(.fen(fen, moves: []), limit: .movetime(movetimeMs))
        return result.bestMove
    }

    /// Longer than a reply, because this one is a verdict.
    ///
    /// The move budget of a hold is over by the time this runs, so nobody is
    /// waiting on a board — and the number decides whether the user is told
    /// they held the draw. A move chosen a little too quickly costs a tempo; a
    /// score read a little too quickly costs a clean run the user earned.
    var rulingMovetimeMs: Int { 1_000 }

    func score(fen: String) async throws -> Int? {
        let device = await engine.deviceProfile
        let lease = await engine.acquire(.probe, configuration: .probe(device: device))
        defer { Task { await engine.release(lease) } }
        let result = try await engine.search(
            .fen(fen, moves: []),
            limit: .movetime(rulingMovetimeMs),
            lease: lease
        )
        // A search somebody else stopped carries whatever the first few
        // milliseconds found, and here that number would fail a drill. No
        // opinion is the only honest reading of it.
        guard !result.wasTruncated, let score = result.principal?.score else { return nil }
        return PuzzleEvaluation(score: score).centipawns
    }
}

// MARK: - Model

/// Runs one endgame drill family, position by position.
@MainActor
@Observable
final class EndgameDrillModel {

    enum Stage: Equatable {
        case playing
        case verdict(PuzzleSessionModel.Verdict)
        /// The engine stopped answering mid-run.
        ///
        /// Its own stage rather than a silent stall: the spinner vanished, the
        /// board looked live, and every drag was refused because it was not the
        /// user's move. The only exits were an xmark that saved nothing and
        /// "Give up", which recorded a failure and reset the clean streak for
        /// something that was not the user's doing.
        case engineUnavailable
        /// Every position in the family has been played.
        case finished
    }

    let family: DrillFamilyPresentation

    private(set) var stage: Stage = .playing
    private(set) var run: EndgameDrillRun?
    private(set) var isThinking = false
    private(set) var completedRuns: [EndgameDrillRun] = []
    private(set) var index = 0

    private let drills: [EndgameDrill]
    private let opponent: any DrillOpponent
    private let recorder: (any DrillOutcomeRecorder)?
    /// Whether the run on screen ended because the user stopped it.
    private var didResign = false

    init(
        kind: EndgameDrillKind,
        opponent: any DrillOpponent,
        recorder: (any DrillOutcomeRecorder)? = nil
    ) {
        self.family = DrillFamilyPresentation.all.first { $0.kind == kind }
            ?? DrillFamilyPresentation.all[0]
        self.drills = EndgameDrill.drills(kind: kind)
        self.opponent = opponent
        self.recorder = recorder
        self.run = drills.first.flatMap { EndgameDrillRun(drill: $0) }
    }

    var drillCount: Int { drills.count }

    /// `Move 7 of 25`, the budget the pass criteria are written in.
    ///
    /// Written out, because `7 / 25` means opposite things in two drills and
    /// nothing on screen told them apart: in the rook mate it is a deadline —
    /// 24 of 25 means one move from failing — and in Philidor it is the length
    /// of the test, so 24 of 25 means one move from passing.
    var budgetLabel: String {
        guard let run else { return "" }
        let verb = run.drill.target == .hold ? "Held" : "Move"
        return "\(verb) \(run.userMoveCount) of \(run.moveBudget)"
    }

    /// What this position asks for, and what counts as passing it.
    ///
    /// The drill screen used to carry the family name and a bare counter, so a
    /// user dropped into "Philidor" with Black to move had no way to know they
    /// were defending, and the two KPK positions where they defend look exactly
    /// like the four where they attack.
    var taskLine: String {
        guard let run else { return "" }
        let goal: String
        switch run.drill.target {
        case .mate: goal = "Mate in \(run.moveBudget) moves or fewer."
        case .win: goal = "Win it: get the pawn through."
        case .hold: goal = "Hold the draw for \(run.moveBudget) moves."
        case .theoreticalResult:
            goal = "Play it out without changing the result — a win has to be won, a draw held."
        }
        return "\(run.drill.title). \(goal)"
    }

    /// `Position 3 of 6`, for a family that ships more than one.
    var positionLabel: String? {
        guard drillCount > 1 else { return nil }
        return "Position \(index + 1) of \(drillCount)"
    }

    /// True once a KPK set can no longer be clean.
    ///
    /// The set is scored as one thing, so after the first miss the remaining
    /// positions cannot earn the streak. Saying so is the difference between
    /// practice the user chose and four more positions played for a reset they
    /// could not avoid.
    var setIsSpent: Bool {
        guard let kind = drills.first?.kind, kind.isSetScored else { return false }
        return completedRuns.contains { !$0.isClean }
    }

    var orientation: Piece.Color { run?.drill.userColor ?? .white }

    var position: Position? { run?.board.position }

    /// The squares the last move touched, whoever played it.
    ///
    /// The drill board carried no marks at all, so the engine's reply — which
    /// arrives 300ms after the user's own move, with no animation to follow —
    /// was invisible. The puzzle session has marked its opponent's move since it
    /// shipped; a drill that runs for up to sixty plies needs it more, not less.
    /// Any last move rather than only the engine's, the way a real board does
    /// it: for the 300ms before the reply lands it is the user's own move that
    /// is showing, which is the correct thing for a board to say.
    var highlights: [SquareHighlight] {
        guard let move = run?.lastMove else { return [] }
        return SquareHighlight.lastMove(from: move.start, to: move.end)
    }

    // MARK: Input

    func attemptMove(from: Square, to: Square, promotion: Piece.Kind? = nil) -> MoveAcceptance {
        guard stage == .playing, !isThinking, let current = run, current.result == .inProgress else {
            return .rejected
        }
        guard current.isUserToMove else { return .rejected }

        if promotion == nil, isPromotion(from: from, to: to, in: current.board.position) {
            return .needsPromotion(complete: { [weak self] kind in
                self?.attemptMove(from: from, to: to, promotion: kind) ?? .rejected
            })
        }

        let uci = from.notation + to.notation + (promotion.map { $0.rawValue.lowercased() } ?? "")
        var probe = current
        guard probe.play(uci: uci) else { return .rejected }

        run = probe
        Task { await self.afterUserMove() }
        return .accepted
    }

    private func isPromotion(from: Square, to: Square, in position: Position) -> Bool {
        guard let piece = position.piece(at: from), piece.kind == .pawn else { return false }
        return to.rank.value == 8 || to.rank.value == 1
    }

    /// Ends the run early. Counted as a failure, which is what it is.
    ///
    /// Tracked separately from the run so the verdict can say what happened:
    /// "the technique did not hold" is not true of a run the user stopped, and
    /// telling them their method failed when they simply left is the sort of
    /// small untruth that makes the rest of the coaching harder to believe.
    func resign() async {
        guard var current = run, current.result == .inProgress else { return }
        didResign = true
        current.resign()
        run = current
        await settle()
    }

    /// Replays the position from the start.
    ///
    /// A drill is knowledge, and marking it wrong without letting the user try
    /// the method they were just shown teaches nothing. The retry does not undo
    /// the recorded run — the streak has already been reset, which is what the
    /// curriculum gates on — it only lets the technique be practised now, while
    /// the miss is still in front of them.
    func retryPosition() {
        guard case .verdict = stage, drills.indices.contains(index),
            let fresh = EndgameDrillRun(drill: drills[index])
        else { return }
        completedRuns.removeAll { $0.drill.id == drills[index].id }
        didResign = false
        run = fresh
        stage = .playing
        if !fresh.isUserToMove {
            Task { await self.playOpponent() }
        }
    }

    private func afterUserMove() async {
        guard let current = run else { return }
        guard current.result == .inProgress else {
            await settle()
            return
        }
        await playOpponent()
    }

    private func playOpponent() async {
        guard let current = run, current.result == .inProgress, !current.isUserToMove else { return }

        isThinking = true
        defer { isThinking = false }

        let fen = FENParser.convert(position: current.board.position)
        // Double-optional flattened: the call both throws and returns an
        // optional, and "the engine failed" and "there is no move" want the same
        // handling here.
        let reply = (try? await opponent.reply(fen: fen)) ?? nil

        // Re-read: the run is a value and an `await` is a suspension point, so
        // the state that was current before the search is not necessarily the
        // state now.
        guard var latest = run, latest.result == .inProgress else { return }
        guard let move = reply else {
            // Either the position is terminal — in which case settling reads
            // the verdict — or the engine failed, which is not a thing to score
            // the user for.
            await settle()
            if case .playing = stage { stage = .engineUnavailable }
            return
        }
        guard latest.play(uci: move) else {
            await settle()
            if case .playing = stage { stage = .engineUnavailable }
            return
        }
        run = latest
        if latest.result != .inProgress { await settle() }
    }

    /// Records the finished run and raises the verdict.
    private func settle() async {
        guard var finished = run, finished.result != .inProgress else { return }
        guard !completedRuns.contains(where: { $0.drill.id == finished.drill.id }) else { return }

        // A hold that survived the budget with the material still on the board
        // is not yet a draw, and the board cannot finish the sentence: rook
        // passive, king on the edge, pawn on the seventh counts the same as a
        // textbook third-rank defence. Asking the engine before the run is
        // recorded is what stops "Solved — the draw held" being printed over a
        // lost position and counted toward `r3.rookEndings`.
        if finished.needsHoldRuling {
            isThinking = true
            let fen = FENParser.convert(position: finished.board.position)
            let score = (try? await opponent.score(fen: fen)) ?? nil
            isThinking = false
            finished.applyHoldRuling(centipawns: score)
            run = finished
        }

        completedRuns.append(finished)

        // A KPK *set* is scored as one thing: the family tests telling the won
        // positions from the drawn ones, and passing five of six by pushing
        // every pawn would prove exactly nothing.
        if finished.drill.kind.isSetScored {
            if completedRuns.count == drills.count {
                cleanStreak = Int(await recorder?.recordKPKSet(runs: completedRuns) ?? 0)
            }
        } else {
            cleanStreak = Int(await recorder?.recordDrill(finished) ?? 0)
        }

        Haptics.play(.gameEnd(won: finished.isClean))
        stage = .verdict(verdict(for: finished))
    }

    func continueAfterVerdict() {
        guard case .verdict = stage else { return }
        index += 1
        guard drills.indices.contains(index), let next = EndgameDrillRun(drill: drills[index]) else {
            // The board stays. Clearing it left the last screen of the drill as
            // an empty surface with one button on it, which is a worse ending
            // than the position the user just played.
            stage = .finished
            return
        }
        didResign = false
        run = next
        stage = .playing
        // The defending side may be on move in the starting position.
        if !next.isUserToMove {
            Task { await self.playOpponent() }
        }
    }

    /// How the family went, once every position has been played.
    ///
    /// The streak is what the curriculum gates on, and it was computed, written
    /// and thrown away: the finished screen said "Done" and nothing else, so a
    /// user one clean run from clearing "Basic mates" had no way to know it.
    var finishedSummary: String {
        let required = DomainTuning.default.curriculum.drillCleanStreakRequired
        guard drills.first?.kind.isSetScored == true else {
            return streakLine(cleanStreak, required)
        }
        // A set is one result. Saying how many positions were clean without
        // saying that it only counts if all of them were is the same trap the
        // set has always had.
        let clean = completedRuns.filter(\.isClean).count
        let head = "\(clean) of \(completedRuns.count) positions clean"
        return clean == completedRuns.count
            ? "\(head) — the set counts. \(streakLine(cleanStreak, required))"
            : "\(head) — a set counts only if every position does."
    }

    private func streakLine(_ streak: Int, _ required: Int) -> String {
        if streak >= required { return "\(family.title): cleared." }
        let left = required - streak
        return "\(family.title): \(streak) of \(required) clean — \(left) more to clear it."
    }

    /// The clean streak after this visit, as the recorder computed it.
    private(set) var cleanStreak = 0

    /// Asks the engine again after it failed to answer.
    func retryEngineMove() async {
        guard case .engineUnavailable = stage, let current = run, current.result == .inProgress else {
            return
        }
        stage = .playing
        await playOpponent()
    }

    /// Kicks off the first position when the engine moves first.
    func begin() async {
        guard let current = run, current.result == .inProgress, !current.isUserToMove else { return }
        await playOpponent()
    }

    // MARK: Verdict copy

    /// The same banner the puzzle session uses, for the same reason: pass and
    /// fail differ by a tint and a glyph and nothing else.
    func verdict(for run: EndgameDrillRun) -> PuzzleSessionModel.Verdict {
        PuzzleSessionModel.Verdict(
            solved: run.result == .passed,
            message: message(for: run),
            ring: nil,
            answer: nil
        )
    }

    /// What happened, and — on a miss — the first step of the method that would
    /// have stopped it.
    ///
    /// "The technique did not hold" names neither the technique nor what went
    /// wrong, which is the outcome-only shape the coaching rule exists to
    /// forbid. The run knows how the position ended and the family knows its
    /// own cue, so both are said.
    private func message(for run: EndgameDrillRun) -> String {
        // "Solved", not "Clean": the puzzles say Solved, and one word for one
        // idea is worth more than a second vocabulary for the same event.
        if run.result == .passed {
            switch run.drill.target {
            case .mate: return "Solved — mate in \(run.userMoveCount) moves, inside \(run.moveBudget)."
            case .hold: return "Solved — the draw held for \(run.userMoveCount) moves."
            case .win:
                // Which of the two ways it was won, because the drill teaches
                // the bridge and the bridge ends with a queen, not with mate.
                guard let queened = run.queenedOnMove else {
                    return "Solved — mate in \(run.userMoveCount) moves."
                }
                return "Solved — the pawn queened on move \(queened), and the queen is safe."
            case .theoreticalResult:
                // Which result it was, not just that it was kept. The whole
                // lesson of the set is telling the won positions from the drawn
                // ones, and a user who has just played one out still has to be
                // told which kind it was to learn anything from having held it.
                switch run.startingKPKOutcome {
                case .win: return "Solved — a won pawn ending, converted: mate in \(run.userMoveCount)."
                case .draw: return "Solved — a drawn pawn ending, and you held it."
                case nil: return "Solved — you kept the result the position started with."
                }
            }
        }

        if didResign {
            return "Stopped — this run does not count as clean. \(cue)"
        }

        // King and pawn is graded against the bitbase on every move, so the run
        // knows the move the result went on *and* a move that would have kept
        // it. Saying both is the difference between a score and a lesson: a user
        // who lost the opposition on move 3 and then played twenty more moves
        // was told "Missed — the result changed on your move" and nothing else.
        if let lapse = run.lapse {
            let lost = run.drawReason == .stalemate
                ? "was stalemate"
                : (lapse.was == .win ? "let the win go" : "gave the draw away")
            guard let keeps = lapse.keeps else {
                return "Missed — move \(lapse.moveNumber), \(lapse.played) \(lost). \(cue)"
            }
            let held = lapse.was == .win ? "keeps the win" : "holds the draw"
            return "Missed — move \(lapse.moveNumber), \(lapse.played) \(lost); \(keeps) \(held)."
        }

        // "It ended in a draw" is the outcome, not the mistake. Stalemate, a
        // threefold repetition and the fifty-move rule are three different
        // errors with three different fixes, and the board recorded which one
        // it was — a queen mate thrown away by stalemate used to be reported in
        // the same words as one that simply ran out of moves.
        if let reason = run.drawReason {
            return "Missed — \(Self.drawSentence(reason, onMove: run.userMoveCount)) \(cue)"
        }
        // Surviving is not holding. The budget ran out with everything still on
        // the board and the engine says the defence has already collapsed —
        // which is a different miss from running out of moves, and the only one
        // where the user has to be told the position is lost before they will
        // believe the cue.
        if run.holdRuledLost {
            return "Missed — \(run.moveBudget) moves survived, but the engine rates the position lost. \(cue)"
        }
        if run.userMoveCount >= run.moveBudget {
            return "Missed — \(run.moveBudget) moves used and it is not done. \(cue)"
        }
        return "Missed — \(cue)"
    }

    /// The draw, named in the words a player uses for it.
    ///
    /// Kept to a clause rather than a sentence, and that is a real constraint
    /// rather than terseness for its own sake: the cue follows it into the same
    /// banner, `ConceptSchedulerTests` holds the longest cue to 76 characters,
    /// and the banner shows four lines and cuts the rest. An explanation of the
    /// stalemate rule would push the method off the bottom of the card, and the
    /// method is the half the user needs next game. The rule itself is in the
    /// lesson, where there is a screen for it.
    private static func drawSentence(_ reason: Board.State.DrawReason, onMove move: Int) -> String {
        switch reason {
        case .stalemate: return "stalemate on move \(move)."
        case .repetition: return "the position repeated three times."
        case .fiftyMoves: return "the fifty-move rule ended it."
        case .insufficientMaterial: return "nothing was left to mate with."
        case .agreement: return "it was drawn on move \(move)."
        }
    }

    /// The first sentence of the family's own "what to look for".
    ///
    /// Quoted from the lesson rather than written again here, so the drill and
    /// the lesson say the idea the same way both times — which is the only
    /// reason a cue survives to the next game.
    private var cue: String {
        TrainingConcept.catalogue
            .first { concept in
                if case let .drill(kind) = concept.exercise { return kind == family.kind }
                return false
            }?
            .teaching.cue ?? family.teaches
    }
}

// MARK: - Screen

/// Plays an endgame drill family against the engine.
struct EndgameDrillScreen: View {

    @State private var model: EndgameDrillModel
    @State private var isConfirmingExit = false
    @State private var isConfirmingResign = false
    @Environment(\.dismiss) private var dismiss

    init(model: EndgameDrillModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 12) {
            // The task, above the board, the way the puzzle session states its
            // own. Without it a user dropped into "Philidor" with Black to move
            // has no way to know they are defending, and the KPK positions
            // where they must hold a draw look exactly like the ones they must
            // win.
            if !model.taskLine.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.taskLine)
                        .typeRole(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let positionLabel = model.positionLabel {
                        Text(positionLabel).typeRole(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }

            if let position = model.position {
                CapturedTrayRow(perspective: model.orientation, position: position)
                    .padding(.horizontal, 16)

                BoardView(
                    position: position,
                    orientation: model.orientation,
                    interaction: interaction,
                    highlights: model.highlights,
                    style: BoardAppearance.shared.style
                )
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)

            footer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
        .navigationTitle(model.family.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { requestExit() } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close the drill")
            }
            ToolbarItem(placement: .primaryAction) {
                Text(model.budgetLabel)
                    .typeRole(.caption, monospacedDigits: true)
                    .accessibilityLabel(model.budgetLabel)
            }
        }
        // A half-finished set is recorded as nothing at all — the KPK set is
        // written only when every position has been played — so leaving five
        // clean positions in throws them away. The puzzle session warns nobody
        // because a half-finished puzzle is at least *scored*; this is not.
        .confirmationDialog(
            "Leave the drill?",
            isPresented: $isConfirmingExit,
            titleVisibility: .visible
        ) {
            Button("Leave — this run is not saved", role: .destructive) { dismiss() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text(exitWarning)
        }
        .confirmationDialog(
            "Give up this position?",
            isPresented: $isConfirmingResign,
            titleVisibility: .visible
        ) {
            Button("Give up", role: .destructive) { Task { await model.resign() } }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("It is recorded as a miss and your clean streak goes back to zero.")
        }
        .task { await model.begin() }
    }

    /// The xmark asks first, but only while there is something to lose.
    private func requestExit() {
        guard case .playing = model.stage, model.position != nil else {
            dismiss()
            return
        }
        isConfirmingExit = true
    }

    private var exitWarning: String {
        guard let positionLabel = model.positionLabel else {
            return "This position is not recorded either way."
        }
        return "\(positionLabel), and the set is only recorded once every position has been played."
    }

    private var interaction: BoardInteraction {
        guard case .playing = model.stage, !model.isThinking else { return .replay }
        return .userMove { from, to in
            model.attemptMove(from: from, to: to)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.stage {
        case .playing:
            HStack {
                Spacer()
                // No spinner while the engine thinks. It searches for 300ms,
                // which is a flicker rather than a wait, and the craft rules
                // name "a spinner while the opponent thinks" as the second
                // thing that makes an app feel cheap.
                Button { isConfirmingResign = true } label: {
                    Text("Give up · counts as missed")
                        .typeRole(.caption, appliesForeground: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isThinking)
            }
            .frame(minHeight: ResultBanner.height)

        case .engineUnavailable:
            VStack(spacing: 10) {
                Text("The engine stopped replying. This run will not count either way.")
                    .typeRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ask the engine again") { Task { await model.retryEngineMove() } }
                    .buttonStyle(.secondaryAction)
            }
            .frame(minHeight: ResultBanner.height)

        case let .verdict(verdict):
            VStack(spacing: 10) {
                ResultBanner(
                    verdict: verdict,
                    continueTitle: model.index + 1 < model.drillCount ? "Next position" : "Finish",
                    onContinue: { model.continueAfterVerdict() }
                )

                // A drill is knowledge, and marking it wrong without a way to
                // play the method through is the case the lesson screen's own
                // doc calls out: there was nothing in the position to work it
                // out from, so failing it teaches nothing on its own.
                if !verdict.solved {
                    Button("Play this position again") { model.retryPosition() }
                        .buttonStyle(.secondaryAction)
                }

                if model.setIsSpent {
                    Text("This set will not count as clean — the rest is practice.")
                        .typeRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: ResultBanner.height)

        case .finished:
            VStack(spacing: 10) {
                Text(model.finishedSummary)
                    .typeRole(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Back to Train") { dismiss() }
                    .buttonStyle(.primaryAction)
            }
            .frame(minHeight: ResultBanner.height)
        }
    }
}
