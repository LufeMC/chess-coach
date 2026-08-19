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
}

// MARK: - Model

/// Runs one endgame drill family, position by position.
@MainActor
@Observable
final class EndgameDrillModel {

    enum Stage: Equatable {
        case playing
        case verdict(PuzzleSessionModel.Verdict)
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
    var budgetLabel: String {
        guard let run else { return "" }
        return "\(run.userMoveCount) / \(run.moveBudget)"
    }

    var orientation: Piece.Color { run?.drill.userColor ?? .white }

    var position: Position? { run?.board.position }

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
    func resign() async {
        guard var current = run, current.result == .inProgress else { return }
        current.resign()
        run = current
        await settle()
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
            // No legal reply. Either the run's own evaluation has already
            // decided, or the position is terminal; settling reads the verdict
            // either way.
            await settle()
            return
        }
        guard latest.play(uci: move) else {
            await settle()
            return
        }
        run = latest
        if latest.result != .inProgress { await settle() }
    }

    /// Records the finished run and raises the verdict.
    private func settle() async {
        guard let finished = run, finished.result != .inProgress else { return }
        guard !completedRuns.contains(where: { $0.drill.id == finished.drill.id }) else { return }

        completedRuns.append(finished)

        // A KPK *set* is scored as one thing: the family tests telling the won
        // positions from the drawn ones, and passing five of six by pushing
        // every pawn would prove exactly nothing.
        if finished.drill.kind.isSetScored {
            if completedRuns.count == drills.count {
                await recorder?.recordKPKSet(runs: completedRuns)
            }
        } else {
            await recorder?.recordDrill(finished)
        }

        stage = .verdict(EndgameDrillModel.verdict(for: finished))
    }

    func continueAfterVerdict() {
        guard case .verdict = stage else { return }
        index += 1
        guard drills.indices.contains(index), let next = EndgameDrillRun(drill: drills[index]) else {
            stage = .finished
            run = nil
            return
        }
        run = next
        stage = .playing
        // The defending side may be on move in the starting position.
        if !next.isUserToMove {
            Task { await self.playOpponent() }
        }
    }

    /// Kicks off the first position when the engine moves first.
    func begin() async {
        guard let current = run, current.result == .inProgress, !current.isUserToMove else { return }
        await playOpponent()
    }

    // MARK: Verdict copy

    /// The same banner the puzzle session uses, for the same reason: pass and
    /// fail differ by a tint and a glyph and nothing else.
    static func verdict(for run: EndgameDrillRun) -> PuzzleSessionModel.Verdict {
        let passed = run.result == .passed
        return PuzzleSessionModel.Verdict(
            solved: passed,
            message: message(for: run),
            ring: nil,
            answer: nil
        )
    }

    private static func message(for run: EndgameDrillRun) -> String {
        if run.result == .passed {
            switch run.drill.target {
            case .mate: return "Clean — mate in \(run.userMoveCount) moves."
            case .hold: return "Clean — the draw held."
            case .win: return "Clean — the pawn went through."
            case .theoreticalResult: return "Clean — the theoretical result held."
            }
        }
        if run.lostTheoreticalResult {
            return "Missed — the result changed on your move."
        }
        if run.userMoveCount >= run.moveBudget {
            return "Missed — the budget was \(run.moveBudget) moves."
        }
        return "Missed — the technique did not hold."
    }
}

// MARK: - Screen

/// Plays an endgame drill family against the engine.
struct EndgameDrillScreen: View {

    @State private var model: EndgameDrillModel
    @Environment(\.dismiss) private var dismiss

    init(model: EndgameDrillModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let position = model.position {
                BoardView(
                    position: position,
                    orientation: model.orientation,
                    interaction: interaction,
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
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Text(model.budgetLabel)
                    .typeRole(.caption, monospacedDigits: true)
            }
        }
        .task { await model.begin() }
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
                if model.isThinking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    Task { await model.resign() }
                } label: {
                    Text("Give up")
                        .typeRole(.body, appliesForeground: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: ResultBanner.height)

        case let .verdict(verdict):
            ResultBanner(
                verdict: verdict,
                continueTitle: model.index + 1 < model.drillCount ? "Next" : "Finish",
                onContinue: { model.continueAfterVerdict() }
            )
            .frame(minHeight: ResultBanner.height)

        case .finished:
            Button("Done") { dismiss() }
                .buttonStyle(.primaryAction)
                .frame(minHeight: ResultBanner.height)
        }
    }
}
