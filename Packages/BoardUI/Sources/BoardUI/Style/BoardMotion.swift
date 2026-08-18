//
//  BoardMotion.swift
//  BoardUI
//

import SwiftUI

/// The three springs the whole app moves on.
///
/// Named rather than written inline so a retune lands everywhere at once, and
/// so the board cannot quietly grow a fourth curve. The values come from the
/// craft standards: anything that needs a different feel is asking the wrong
/// question about the interaction, not about the spring.
///
/// The grid itself is never animated with any of them — squares are painted in
/// a `Canvas` with no animatable state precisely so that stays true.
extension Animation {

  /// Selection, toggles, button states.
  static let boardSnappy = Animation.spring(response: 0.28, dampingFraction: 0.86)

  /// Sheets, transitions, card entry.
  static let boardStandard = Animation.spring(response: 0.42, dampingFraction: 0.82)

  /// Large-surface moves and board reflow — including the snap-back, whose
  /// slight overshoot at this damping is the "no, not that one" gesture.
  static let boardGentle = Animation.spring(response: 0.60, dampingFraction: 0.90)
}
