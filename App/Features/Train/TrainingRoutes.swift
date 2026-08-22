//
//  TrainingRoutes.swift
//  ChessCoach
//

import SwiftUI
import TrainingCore

/// Where a training session can go.
///
/// Lives in its own file because it outlived the screen that declared it: the
/// Train tab is gone and the daily set is presented from Today, but the routes
/// themselves are unchanged — a set, the slow set, a drill, one concept replayed.
enum TrainRoute: Identifiable, Hashable {
    case puzzles
    /// The slow set, drawn from a band above the user's rating.
    case calculation
    case drill(EndgameDrillKind)
    /// One concept revisited on its own, from the training list.
    case concept(TrainingConcept)

    var id: String {
        switch self {
        case .puzzles: "puzzles"
        case .calculation: "calculation"
        case let .drill(kind): "drill.\(kind.rawValue)"
        case let .concept(concept): "concept.\(concept.id)"
        }
    }
}

extension View {

    /// A full-screen cover on iPhone, a sheet on Mac.
    ///
    /// Both are the same decision: a solve session takes the whole surface,
    /// because a board with a tab bar under it invites leaving mid-puzzle, and a
    /// half-finished puzzle is scored as a failure.
    @ViewBuilder
    func trainingCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
            fullScreenCover(item: item, content: content)
        #else
            sheet(item: item, content: content)
        #endif
    }
}