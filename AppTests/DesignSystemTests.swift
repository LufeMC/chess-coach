//
//  DesignSystemTests.swift
//  ChessCoachTests
//

import EngineKit
import Foundation
import SwiftUI
import Testing

@testable import ChessCoach

@Suite("Design system — denominator composition")
struct DenominatorTests {

    @Test("The prose form reads as a step tally")
    func prose() {
        let denominator = Denominator.of(1, 3)
        #expect(denominator.value == "1")
        #expect(denominator.denominator == "of 3")
        #expect(denominator.accessibilityText == "1 of 3")
    }

    @Test("The slash form keeps the separator on the demoted half")
    func slash() {
        let denominator = Denominator.over(72, 100)
        #expect(denominator.value == "72")
        #expect(denominator.denominator == "/100")
        // VoiceOver gets a phrase, not two numbers with a slash between them.
        #expect(denominator.accessibilityText == "72 out of 100")
    }

    @Test("The noun form pluralises")
    func nounPluralises() {
        #expect(Denominator.count(1, singular: "moment").denominator == "moment")
        #expect(Denominator.count(3, singular: "moment").denominator == "moments")
        #expect(Denominator.count(0, singular: "moment").denominator == "moments")
    }

    @Test("An irregular plural can be supplied")
    func irregularPlural() {
        #expect(Denominator.count(2, singular: "loss", plural: "losses").denominator == "losses")
    }

    @Test("A zero streak is unrepresentable, not rendered as zero")
    func zeroStreakIsSuppressed() {
        // `0 day streak` on first run is a score for a game the user has not
        // been allowed to play yet. Returning nil makes it impossible to draw.
        #expect(Denominator.streak(0) == nil)
        #expect(Denominator.streak(-1) == nil)
    }

    @Test("A real streak reads in days")
    func streakReadsInDays() {
        #expect(Denominator.streak(1)?.accessibilityText == "1 day")
        #expect(Denominator.streak(12)?.accessibilityText == "12 days")
    }
}

@Suite("Design system — typography")
struct TypographyTests {

    @Test("There are exactly six roles")
    func sixRoles() {
        #expect(TypeRole.allCases.count == 6)
    }

    @Test("The denominator always lands on a smaller role")
    func demotionShrinks() {
        for role in TypeRole.allCases where role != .label {
            let shrinks = role.demoted.size < role.size
            #expect(shrinks, "\(role) should demote to something smaller")
        }
        // Label is already the floor; there is nowhere below it.
        #expect(TypeRole.label.demoted == .label)
    }

    @Test("Labels are uppercase with positive tracking")
    func labelTreatment() {
        #expect(TypeRole.label.isUppercase)
        #expect(TypeRole.label.tracking == 0.8)
        #expect(TypeRole.label.prefersSecondaryForeground)
    }

    @Test("Only labels are uppercased")
    func onlyLabelsAreUppercased() {
        let uppercased = TypeRole.allCases.filter { $0.isUppercase }
        #expect(uppercased == [TypeRole.label])
    }

    @Test("Display sets tighter, as large bold text must")
    func displayTracking() {
        #expect(TypeRole.display.tracking == -0.5)
        #expect(TypeRole.display.design == .rounded)
    }

    @Test("Metadata roles default to secondary; content roles do not")
    func secondaryScope() {
        #expect(TypeRole.caption.prefersSecondaryForeground)
        #expect(!TypeRole.body.prefersSecondaryForeground)
        #expect(!TypeRole.headline.prefersSecondaryForeground)
        #expect(!TypeRole.title.prefersSecondaryForeground)
    }

    @Test("Sizes match the specification")
    func sizes() {
        #expect(TypeRole.display.size == 44)
        #expect(TypeRole.title.size == 28)
        #expect(TypeRole.headline.size == 17)
        #expect(TypeRole.body.size == 17)
        #expect(TypeRole.caption.size == 13)
        #expect(TypeRole.label.size == 11)
    }

    @Test("Headline and body share a size but not a weight")
    func headlineVsBody() {
        #expect(TypeRole.headline.size == TypeRole.body.size)
        #expect(TypeRole.headline.weight != TypeRole.body.weight)
    }
}

@Suite("Design system — motion")
struct MotionTests {

    @Test("Stagger adds 40ms a row")
    func staggerStep() {
        #expect(Motion.staggerDelay(index: 0) == 0)
        #expect(abs(Motion.staggerDelay(index: 1) - 0.040) < 0.0001)
        #expect(abs(Motion.staggerDelay(index: 3) - 0.120) < 0.0001)
    }

    @Test("Stagger caps at six rows")
    func staggerCaps() {
        let cap = Motion.staggerDelay(index: Motion.staggerCap)
        #expect(Motion.staggerDelay(index: 7) == cap)
        #expect(Motion.staggerDelay(index: 40) == cap)
        #expect(abs(cap - 0.240) < 0.0001)
    }

    @Test("A negative index is clamped rather than producing a negative delay")
    func staggerClampsLow() {
        #expect(Motion.staggerDelay(index: -3) == 0)
    }

    @Test("The non-spring durations are the three specified")
    func durations() {
        #expect(Motion.crossfadeDuration == 0.15)
        #expect(Motion.colorShiftDuration == 0.25)
        #expect(Motion.contentSwapDuration == 0.35)
    }
}

@Suite("Design system — haptics budget")
struct HapticsTests {

    @Test("The event map matches the standards table")
    func eventMap() {
        #expect(Haptics.feedback(for: .pieceLifted) == .impact(.light))
        #expect(Haptics.feedback(for: .legalDrop) == .impact(.medium))
        #expect(Haptics.feedback(for: .illegalDrop) == .impact(.rigid))
        #expect(Haptics.feedback(for: .capture) == .impact(.heavy))
        #expect(Haptics.feedback(for: .checkDelivered) == .notification(.warning))
        #expect(Haptics.feedback(for: .stepCompleted) == .notification(.success))
        #expect(Haptics.feedback(for: .clockWarning) == .impact(.soft))
    }

    @Test("Game end is routed by result")
    func gameEndByResult() {
        #expect(Haptics.feedback(for: .gameEnd(won: true)) == .notification(.success))
        #expect(Haptics.feedback(for: .gameEnd(won: false)) == .notification(.error))
    }

    @Test("A capture is felt more than a legal drop")
    func captureOutweighsDrop() {
        #expect(Haptics.feedback(for: .capture) != Haptics.feedback(for: .legalDrop))
    }
}

@Suite("Design system — loading and depth")
struct LoadingAndDepthTests {

    @Test("Nothing is shown under the 200ms threshold")
    func skeletonThreshold() {
        #expect(SkeletonPolicy.minimumVisibleDelay == .milliseconds(200))
        #expect(!SkeletonPolicy.shouldShow(isLoading: true, elapsed: .milliseconds(120)))
        #expect(SkeletonPolicy.shouldShow(isLoading: true, elapsed: .milliseconds(200)))
        #expect(SkeletonPolicy.shouldShow(isLoading: true, elapsed: .seconds(1)))
    }

    @Test("A finished load never shows a skeleton, however long it took")
    func loadedNeverSkeletons() {
        #expect(!SkeletonPolicy.shouldShow(isLoading: false, elapsed: .seconds(5)))
    }

    @Test("Three corner radii, and they are the three")
    func cornerRadii() {
        #expect(CornerRadius.chip == 12)
        #expect(CornerRadius.card == 16)
        #expect(CornerRadius.sheet == 24)
    }

    @Test("Elevation has three levels")
    func threeLevels() {
        let levels: [Elevation] = [.ground, .raised, .floating]
        #expect(levels.count == 3)
    }
}

@Suite("Design system — colour tokens")
struct PaletteTests {

    @Test("Dark is designed, never a copy of light")
    func darkIsIndependent() {
        // The Feather rule: brand *fills* stay saturated in both appearances
        // (the green is the green, day or night) — but every surface, line and
        // text-weight colour is tuned per appearance. If any of these tokens'
        // two halves are equal, somebody forgot to tune one.
        let tokens = [
            Palette.evalPositive,
            Palette.evalNegative,
            Palette.caution,
            Palette.surfaceGround,
            Palette.surfaceRaised,
            Palette.surfaceSunken,
            Palette.hairline,
            Palette.hairlinePending,
            Palette.inactiveMark,
            Palette.skeleton
        ]
        for token in tokens {
            let isIdentical = token.light == token.dark
            #expect(!isIdentical)
        }
    }

    @Test("The chunky edges are darker than their fills")
    func edgesAreDarker() {
        // The 3D illusion is a fill sitting on its own shadow. An edge that
        // matches its fill flattens every button in the app at once.
        #expect(Palette.accentEdge != Palette.accent)
        #expect(Palette.blueEdge != Palette.blue)
        #expect(Palette.goldEdge != Palette.gold)
        #expect(Palette.lockedEdge != Palette.lockedFill)
    }

    @Test("Advantage colours are distinct from the accent and from each other")
    func semanticColoursDoNotCollide() {
        #expect(Palette.evalPositive != Palette.evalNegative)
        #expect(Palette.evalNegative != Palette.caution)
        #expect(Palette.evalNegative != Palette.accent)
        #expect(Palette.caution != Palette.accent)
    }

    @Test("Ground, raised and sunken are three distinct dark surfaces")
    func darkSurfacesAreDistinct() {
        #expect(Palette.surfaceRaised.dark != Palette.surfaceGround.dark)
        #expect(Palette.surfaceSunken.dark != Palette.surfaceRaised.dark)
    }
}

// MARK: - Boot failure

/// What the app says when the engine will not start.
///
/// This is the first screen a bad install can reach, and it used to render
/// `String(describing: error)` — a Swift enum case, with nothing to tap. The
/// mapping is pure, so it can be pinned without a Stockfish process.
@MainActor
@Suite("Boot failure copy")
struct BootFailureCopyTests {

    @Test("A missing network names the fix rather than the file")
    func missingNetwork() {
        let message = AppModel.explain(EngineError.missingNetwork("nn-1c0000000000.nnue"))
        #expect(message.contains("installing it again"))
        #expect(!message.contains("nnue"))
    }

    @Test("A handshake that timed out says a retry is worth having")
    func timeout() {
        let message = AppModel.explain(EngineError.handshakeTimeout)
        #expect(message.contains("did not start in time"))
    }

    /// An error from outside `EngineKit` still has to produce a sentence: the
    /// screen has no other content, and a blank description under a warning
    /// triangle is the dead end this replaced.
    @Test("An unrecognised failure still gets a sentence")
    func unknownError() {
        struct Odd: Error {}
        #expect(!AppModel.explain(Odd()).isEmpty)
    }

    /// The raw case is kept, because it is the only part of this worth pasting
    /// into a bug report.
    @Test("The raw error is carried alongside the sentence")
    func detailIsKept() {
        let failure = AppModel.BootFailure(
            message: AppModel.explain(EngineError.handshakeTimeout),
            detail: String(describing: EngineError.handshakeTimeout)
        )
        #expect(failure.detail == "handshakeTimeout")
        #expect(failure.message != failure.detail)
    }
}
