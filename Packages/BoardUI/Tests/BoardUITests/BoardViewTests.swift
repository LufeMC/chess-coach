//
//  BoardViewTests.swift
//  BoardUITests
//

import SwiftUI
import Testing

@testable import BoardUI

/// The board's contract with the app around it.
///
/// Right now that is one value: whether the board is allowed to buzz. The app
/// has a Haptics switch whose caption names the board's own feedbacks, so a
/// board that ignored the value would make the settings screen a liar — and
/// that is a bug nobody finds by looking at a screenshot.
@MainActor
struct BoardViewTests {

  @Test("A board with no host defaults to buzzing")
  func hapticsDefaultToOn() {
    // Previews, and any host that has no such setting, must behave the way the
    // board always did. Silence is the opt in, never the default.
    #expect(EnvironmentValues().boardHapticsEnabled)
  }

  @Test("The environment value carries a host's choice")
  func hapticsValueRoundTrips() {
    var environment = EnvironmentValues()
    environment.boardHapticsEnabled = false
    #expect(environment.boardHapticsEnabled == false)
  }

  @Test("Every board event is silent when haptics are off")
  func everyEventIsGated() {
    // All five, one by one: the failure this catches is a new event added to
    // `BoardFeedback` that forgets the gate, which would leave the switch half
    // working — the worst of the three possible states.
    for event in BoardHaptic.allCases {
      #expect(event.feedback(enabled: false) == nil, "\(event) still fires with haptics off")
      #expect(event.feedback(enabled: true) != nil, "\(event) is silent with haptics on")
    }
  }

  @Test("The gate covers the events the settings caption names")
  func theGateCoversTheDocumentedEvents() {
    // Lift, drop, refusal, capture and check are the five the Settings caption
    // promises the switch controls; the count is pinned so a sixth cannot be
    // added to the board without someone rereading that sentence.
    #expect(BoardHaptic.allCases.count == 5)
  }
}
