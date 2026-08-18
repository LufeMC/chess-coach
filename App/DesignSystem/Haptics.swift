//
//  Haptics.swift
//  ChessCoach
//
//  Design system — Haptics.
//

import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Every haptic the app is allowed to fire, and nothing else.
///
/// ## Why this is centralised
///
/// The rule is *mark state changes the user caused, never ones the app decided*,
/// and the budget is what makes it real: a 40-move game that buzzes twice a move
/// feels defective, and no individual call site ever thinks it is the one over
/// budget. A closed enum makes the whole budget auditable in one file — you can
/// read the eight cases and know exactly what the app can do to a hand.
///
/// Scrolling, sheet presentation and navigation are absent on purpose. They are
/// the app moving, not the user changing something.
enum Haptics {

    /// The sanctioned events. Adding a case is a design decision, which is
    /// exactly the friction wanted.
    enum Event: Hashable {
        case pieceLifted
        case legalDrop
        case illegalDrop
        case capture
        case checkDelivered
        case gameEnd(won: Bool)
        case stepCompleted
        /// Fires **once** as the clock crosses ten seconds, not per tick.
        case clockWarning
    }

    /// The platform-independent description of a feedback, so the mapping can
    /// be tested without a taptic engine — which no simulator and no test host
    /// has.
    enum Feedback: Hashable {
        case impact(Impact)
        case notification(Notification)

        enum Impact: Hashable { case light, medium, heavy, soft, rigid }
        enum Notification: Hashable { case success, warning, error }
    }

    /// The map from the craft standards, as a pure function.
    static func feedback(for event: Event) -> Feedback {
        switch event {
        case .pieceLifted: .impact(.light)
        case .legalDrop: .impact(.medium)
        // Rigid rather than heavy: the point is that the move *stopped*, and
        // rigid is the sharpest "no" the API offers. The accompanying shake is
        // the view's job.
        case .illegalDrop: .impact(.rigid)
        case .capture: .impact(.heavy)
        // Warning rather than success: check is information, not an
        // achievement, and it is equally likely to be against the user.
        case .checkDelivered: .notification(.warning)
        case .gameEnd(let won): .notification(won ? .success : .error)
        case .stepCompleted: .notification(.success)
        // Soft, because the clock crossing ten seconds is a fact the user
        // should feel without being startled into a blunder.
        case .clockWarning: .impact(.soft)
        }
    }

    /// Master switch, mirroring the `hapticsOn` app setting.
    ///
    /// Cached rather than read from the database per event: a taptic call has a
    /// deadline measured in a frame, and a SQLite round trip inside a drag
    /// gesture is exactly how a board starts stuttering.
    @MainActor static var isEnabled = true

    /// Fires the feedback for an event.
    @MainActor
    static func play(_ event: Event) {
        guard isEnabled else { return }
        perform(feedback(for: event))
    }

    @MainActor
    private static func perform(_ feedback: Feedback) {
        #if canImport(UIKit)
            switch feedback {
            case .impact(let impact):
                UIImpactFeedbackGenerator(style: impact.uiStyle).impactOccurred()
            case .notification(let notification):
                UINotificationFeedbackGenerator().notificationOccurred(notification.uiType)
            }
        #endif
    }
}

#if canImport(UIKit)
    private extension Haptics.Feedback.Impact {
        var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: .light
            case .medium: .medium
            case .heavy: .heavy
            case .soft: .soft
            case .rigid: .rigid
            }
        }
    }

    private extension Haptics.Feedback.Notification {
        var uiType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
        }
    }
#endif
