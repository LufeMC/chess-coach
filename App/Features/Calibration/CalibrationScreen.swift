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
/// ``CalibrationModel/framingLine`` — and every one of the four screens carries
/// the same `Step n of 4` header, because this is the only flow in the app the
/// user cannot leave and the length of it should never be a guess.
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
            store: StoredCalibrationOutcome(settings: database.settings, metrics: database.metrics),
            drafts: DatabaseCalibrationDraftStore()
        )
    }

    var body: some View {
        Group {
            switch flow.stage {
            case .intro:
                SelfAssessmentView(
                    progress: flow.progress,
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
                CalibrationRevealView(
                    progress: flow.progress,
                    estimate: estimate,
                    onStart: onFinish
                )
            }
        }
        .animation(Motion.standard, value: flow.stage)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// This build shipped without the puzzle corpus.
    ///
    /// A pending or degraded condition gets a stated fact and a way forward, not
    /// an illustrated empty state and a `Continue` that names neither the step
    /// nor its cost. The five games already happened; nothing is lost, the
    /// measurement is just shorter than the flow advertised.
    private var noPuzzleCorpus: some View {
        VStack(spacing: 12) {
            CalibrationHeader(progress: flow.progress, step: .puzzles)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 10) {
                Text("Placing you from the games")
                    .typeRole(.headline)

                Text("This build shipped without the puzzle corpus, so your five games carry the whole measurement. Your rating will move faster than usual over the first week as real results come in.")
                    .typeRole(.body, appliesForeground: false)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Show my rating") { flow.finish() }
                    .buttonStyle(.primaryAction)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .elevation(.raised, cornerRadius: CornerRadius.card)
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surfaceGround.dynamic.ignoresSafeArea())
    }
}
