//
//  CalibrationScreen.swift
//  ChessCoach
//

import Database
import SwiftUI
import TrainingCore

/// First-run calibration, start to finish.
///
/// One question, five games, twenty puzzles, one reveal. The framing line is
/// said once on the opening screen and never repeated — see
/// ``CalibrationModel/framingLine``.
struct CalibrationScreen: View {

    @Environment(AppModel.self) private var model
    @State private var flow: CalibrationModel

    /// Called when the user leaves the reveal. The caller decides where they
    /// land; this screen only knows that calibration is done.
    let onFinish: () -> Void

    init(flow: CalibrationModel? = nil, onFinish: @escaping () -> Void = {}) {
        self.onFinish = onFinish
        _flow = State(initialValue: flow ?? CalibrationScreen.makeFlow())
    }

    /// Builds the flow against the shared databases, or without a store when
    /// they could not be opened — a user who cannot write settings should still
    /// be able to play the app rather than be stuck on onboarding forever.
    private static func makeFlow() -> CalibrationModel {
        guard let database = AppDatabase.sharedIfAvailable else {
            return CalibrationModel()
        }
        return CalibrationModel(
            store: StoredCalibrationOutcome(settings: database.settings, metrics: database.metrics)
        )
    }

    var body: some View {
        Group {
            switch flow.stage {
            case .intro:
                SelfAssessmentView(
                    selection: flow.experience,
                    onSelect: { flow.select($0) },
                    onContinue: { flow.beginMeasurement() }
                )

            case .games:
                CalibrationGamesView(flow: flow, engineService: model.engineService)

            case .puzzles:
                if let corpus = AppDatabase.sharedIfAvailable?.puzzleQueries {
                    CalibrationPuzzlesView(flow: flow, corpus: corpus)
                } else {
                    // No corpus: the games alone still produce an estimate, with
                    // an honestly wider sigma, which is better than blocking.
                    noPuzzleCorpus
                }

            case let .reveal(estimate):
                CalibrationRevealView(estimate: estimate, onStart: onFinish)
            }
        }
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var noPuzzleCorpus: some View {
        ContentUnavailableView {
            Label("Puzzles unavailable", systemImage: "square.grid.3x3")
        } description: {
            Text("This build shipped without the puzzle corpus, so we'll place you from the games alone.")
        } actions: {
            Button("Continue") { flow.finish() }
                .buttonStyle(.borderedProminent)
        }
    }
}
