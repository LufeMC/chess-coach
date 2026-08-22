//
//  RoutingTests.swift
//  ChessCoachTests
//

import Foundation
import Testing
import TrainingCore

@testable import ChessCoach

/// The routes that survived the Train tab.
///
/// Nothing covered any of this before: a grep of the suite found no test naming
/// `MainTabBar`, `selectedTab` or `AppModel.Tab`, so every routing consequence of
/// removing a tab was protected by manual testing alone. These are cheap and
/// they are the only automated protection the merge gets.
///
/// The property under test is the one the merge could break silently. `.train`
/// used to select a fourth tab; it is now a *request* that Today consumes to
/// present the session as a cover. A future call site that assumes it still
/// changes tabs would do nothing at all, with no error anywhere.
@Suite("Routing after the Train merge")
@MainActor
struct RoutingTests {

    @Test("Asking for training lands on Home with a request, not on a tab of its own")
    func trainRouteSelectsToday() {
        let model = AppModel()
        model.selectedTab = .profile

        model.navigate(to: .train)

        #expect(model.selectedTab == .today)
        #expect(model.pendingTrainRequest)
    }

    @Test("A leak carries its habit to Home and asks for the set")
    func leakRouteCarriesTheHabit() {
        let model = AppModel()
        model.selectedTab = .profile

        model.navigate(toTrain: .kingSafety)

        #expect(model.selectedTab == .today)
        #expect(model.pendingTrainingHabit == .kingSafety)
        // Without this the leak sets a focus and never opens anything: before
        // the merge the tab switch was what presented the session.
        #expect(model.pendingTrainRequest)
    }

    @Test("Each request is consumed exactly once")
    func requestsAreConsumedOnce() {
        let model = AppModel()

        model.navigate(to: .train)
        #expect(model.consumeTrainRequest())
        #expect(!model.consumeTrainRequest())

        model.navigate(toTrain: .blunderCheck)
        #expect(model.consumeTrainingHabit() == .blunderCheck)
        #expect(model.consumeTrainingHabit() == nil)
    }

    @Test("The training catalogue is a push on the Today stack")
    func trainingListIsPushed() {
        let model = AppModel()
        model.selectedTab = .play

        model.navigate(to: .training)

        #expect(model.selectedTab == .today)
        #expect(model.todayPath == [.training])
    }

    @Test("Play and Profile still change tabs")
    func tabRoutesStillSwitch() {
        let model = AppModel()

        model.navigate(to: .play)
        #expect(model.selectedTab == .play)
        #expect(model.pendingPlayRequest)

        model.navigate(to: .profile)
        #expect(model.selectedTab == .profile)
    }

    @Test("A review replaces the stack rather than stacking identical screens")
    func reviewReplacesTheStack() {
        let model = AppModel()
        let game = UUID()

        model.navigate(to: .review(gameID: game))
        model.navigate(to: .review(gameID: game))

        #expect(model.selectedTab == .today)
        #expect(model.todayPath == [.review(gameID: game)])
    }
}
