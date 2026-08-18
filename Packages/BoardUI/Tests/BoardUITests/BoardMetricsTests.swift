//
//  BoardMetricsTests.swift
//  BoardUITests
//

import ChessKit
import CoreGraphics
import Testing

@testable import BoardUI

/// The numbers the board's overlays are drawn from.
///
/// These are worth testing for the same reason they are worth centralising:
/// they are the values that drift. A dot that creeps from 22% to 30% of the
/// square, a capture ring that loses its inset, a piece that goes full-bleed —
/// none of it breaks a build, none of it fails a snapshot anybody looks at, and
/// all of it is the difference between a board that reads and a board that
/// smears.
struct BoardMetricsTests {

  /// 100pt squares keep the arithmetic readable: every fraction is a percentage.
  private let side: CGFloat = 100

  // MARK: - Pieces

  @Test func piecesSitWellInsideTheirSquares() {
    // A full-bleed piece makes a dense middlegame read as a solid block and
    // leaves a capture ring nowhere to go.
    #expect(BoardMetrics.pieceScale >= 0.82)
    #expect(BoardMetrics.pieceScale <= 0.88)
  }

  @Test func thePieceInsetProducesThePieceScale() {
    let inset = BoardMetrics.pieceInset(squareSide: side)
    #expect(abs((side - inset * 2) - side * BoardMetrics.pieceScale) < 0.001)
  }

  @Test func aDegenerateSquareNeverProducesANegativeInset() {
    #expect(BoardMetrics.pieceInset(squareSide: 0) == 0)
  }

  // MARK: - Legal moves

  @Test func theLegalMoveDotIsAFifthOfTheSquare() {
    #expect(BoardMetrics.legalMoveDotDiameter(squareSide: side) == 22)
    // Scale-invariant: a thumbnail draws the same board, smaller.
    #expect(BoardMetrics.legalMoveDotDiameter(squareSide: 40) == 8.8)
  }

  @Test func theCaptureRingIsInsetFromTheSquareAndStrokedAtATenth() {
    let ring = BoardMetrics.legalCaptureRing(squareSide: side)
    #expect(ring.inset == 6)
    #expect(ring.lineWidth == 10)
    #expect(ring.outerDiameter == 88)
    #expect(ring.innerDiameter == 68)
  }

  @Test func theCaptureRingFramesThePieceRatherThanCoveringIt() {
    // The whole argument for a ring over a wash: what is standing on the square
    // has to stay visible, or a capture stops being legible as a capture.
    let ring = BoardMetrics.legalCaptureRing(squareSide: side)
    #expect(ring.outerDiameter > side * BoardMetrics.pieceScale)
    // The artwork inside a piece box carries its own margin, so the hole does
    // not have to clear the full piece frame — but it must clear most of it.
    #expect(ring.innerDiameter > side * 0.6)
  }

  @Test func increasedContrastThickensTheRingWithoutMovingIt() {
    let standard = BoardMetrics.legalCaptureRing(squareSide: side)
    let increased = BoardMetrics.legalCaptureRing(squareSide: side, increasedContrast: true)
    #expect(increased.lineWidth > standard.lineWidth)
    #expect(increased.inset == standard.inset)
    #expect(increased.outerDiameter == standard.outerDiameter)
  }

  @Test func increasedContrastRaisesHintOpacityRatherThanChangingTheHue() {
    #expect(BoardMetrics.moveHintOpacity(increasedContrast: false) == BoardMetrics.moveHint)
    #expect(
      BoardMetrics.moveHintOpacity(increasedContrast: true) > BoardMetrics.moveHint,
      "a reader who asked for contrast must not get the same 22% wash back"
    )
  }

  @Test func theOverlayAlphaLadderReadsTopToBottom() {
    // Selection beats the last move, which stays quiet enough that a board
    // wearing it still reads as a position rather than as noise.
    #expect(BoardMetrics.selectionFill > BoardMetrics.moveHint)
    #expect(BoardMetrics.moveHint > BoardMetrics.lastMoveFill)
    #expect(BoardMetrics.lastMoveFill <= 0.15)
  }

  // MARK: - Rings

  @Test func theDropTargetRingSitsInsideTheSquare() {
    let ring = BoardMetrics.dropTargetRing(squareSide: side)
    #expect(ring.inset > 0)
    #expect(ring.outerDiameter == side - ring.inset * 2)
    #expect(ring.innerDiameter > 0)
  }

  @Test func ringsDegradeGracefullyOnAZeroSizedBoard() {
    let ring = BoardMetrics.legalCaptureRing(squareSide: 0)
    #expect(ring.outerDiameter == 0)
    #expect(ring.innerDiameter == 0)
  }

  // MARK: - Check

  @Test func theCheckGlowRunsOffTheSquareButNotIntoTheDiagonalNeighbours() {
    let radius = BoardMetrics.checkGlowRadius(squareSide: side)
    // Past the edge midpoints, so the falloff is never a visible circle drawn
    // inside the square…
    #expect(radius > side / 2)
    // …and short of the half-diagonal, so it does not bleed into the corners.
    #expect(radius < side * 0.7071)
  }

  @Test func theCheckPulseHappensOnceAndSettlesDimmer() {
    #expect(BoardMetrics.checkGlowBloomScale > 1)
    #expect(BoardMetrics.checkGlowRestOpacity < 1)
    #expect(BoardMetrics.checkPulseDuration == 0.4)
  }

  // MARK: - Capture

  @Test func aCapturedPieceGetsAtLeastAnEighthOfASecondToLeave() {
    #expect(BoardMetrics.captureFadeDuration >= 0.18)
    #expect(BoardMetrics.captureFadeScale < 1)
  }

  @Test func flourishRingsRadiateOutwardAndStagger() {
    var previousScale: CGFloat = 1
    var previousDelay = -1.0
    for ring in 0..<BoardMetrics.captureFlourishRings {
      let scale = BoardMetrics.captureFlourishScale(ring: ring)
      let delay = BoardMetrics.captureFlourishDelay(ring: ring)
      #expect(scale > previousScale, "each ring has to clear the one before it")
      #expect(delay > previousDelay, "rings that start together read as one thick ring")
      previousScale = scale
      previousDelay = delay
    }
  }

  // MARK: - Drag

  @Test func theShadowMatchesTheSpecAtAPhoneSizedSquare() {
    let shadow = BoardMetrics.dragShadow(squareSide: BoardMetrics.referenceSquareSide)
    #expect(shadow.radius == 12)
    #expect(shadow.offsetY == 6)
    #expect(shadow.opacity == 0.25)
  }

  @Test func theShadowScalesWithTheBoard() {
    let big = BoardMetrics.dragShadow(squareSide: BoardMetrics.referenceSquareSide * 2)
    #expect(big.radius == 24)
    #expect(big.offsetY == 12)
  }

  @Test func theFingerOffsetIsTwentyFourPointsOnAPhoneAndClampsOnAThumbnail() {
    #expect(BoardMetrics.fingerOffset(squareSide: 45) == 24)
    #expect(BoardMetrics.fingerOffset(squareSide: 120) == 24, "it is a fingertip, not a board")
    // A 12pt square is a filmstrip thumbnail; lifting 24pt there would throw
    // the piece two ranks clear of the finger.
    #expect(BoardMetrics.fingerOffset(squareSide: 12) == 12 * 0.55)
  }

  @Test func aPressedPieceStaysCentredInItsSquare() {
    // The bug this prevents: pressing near a square's edge yanking the piece
    // sideways under the finger before the drag has even started.
    let origin = CGPoint(x: 250, y: 250)
    let presentation = BoardMetrics.dragPresentation(
      squareSide: side,
      originCenter: origin,
      touch: CGPoint(x: 297, y: 203),
      isActive: false,
      isReturning: false
    )
    #expect(presentation.position == origin)
    #expect(presentation.scale == BoardMetrics.dragLiftScale)
    #expect(presentation.ghostOpacity == 0, "nothing to ghost — the piece has not left")
    #expect(presentation.shadowRadius > 0, "it is lifted, so it casts")
  }

  @Test func aTravellingPieceRidesAboveTheFingerAndLeavesAGhost() {
    let touch = CGPoint(x: 310, y: 260)
    let presentation = BoardMetrics.dragPresentation(
      squareSide: side,
      originCenter: CGPoint(x: 250, y: 250),
      touch: touch,
      isActive: true,
      isReturning: false
    )
    #expect(presentation.position.x == touch.x)
    #expect(presentation.position.y == touch.y - BoardMetrics.fingerOffset(squareSide: side))
    #expect(presentation.position.y < touch.y, "the square under the finger has to stay visible")
    #expect(presentation.ghostOpacity == BoardMetrics.dragGhost)
    #expect(presentation.scale == BoardMetrics.dragLiftScale)
  }

  @Test func aPointerGetsNoFingerOffset() {
    // A mouse cursor occludes nothing, so lifting the piece away from it would
    // just leave the piece hovering mysteriously above the pointer.
    let touch = CGPoint(x: 310, y: 260)
    let presentation = BoardMetrics.dragPresentation(
      squareSide: side,
      originCenter: CGPoint(x: 250, y: 250),
      touch: touch,
      isActive: true,
      isReturning: false,
      liftsAboveFinger: false
    )
    #expect(presentation.position == touch)
  }

  @Test func aReturningPieceLandsFlatOnItsOriginWithNoGhostUnderIt() {
    let origin = CGPoint(x: 250, y: 250)
    let presentation = BoardMetrics.dragPresentation(
      squareSide: side,
      originCenter: origin,
      touch: CGPoint(x: 700, y: 90),
      isActive: true,
      isReturning: true
    )
    #expect(presentation.position == origin)
    #expect(presentation.scale == 1, "it is being put back down, not held up")
    #expect(presentation.shadowOpacity == 0)
    #expect(presentation.ghostOpacity == 0, "a ghost under an arriving piece reads as a fault")
  }

  // MARK: - Deselection stagger

  @Test func theOriginSquareLeavesFirst() {
    #expect(BoardMetrics.staggerDelay(from: .e4, to: .e4) == 0)
  }

  @Test func marksLeaveInRingsRadiatingFromTheOrigin() {
    // A rook on a1: a2 is one ring out, a3 two, a8 seven.
    #expect(BoardMetrics.staggerDelay(from: .a1, to: .a2) == 0)
    #expect(abs(BoardMetrics.staggerDelay(from: .a1, to: .a3) - 0.020) < 0.0001)
    #expect(abs(BoardMetrics.staggerDelay(from: .a1, to: .a8) - 0.120) < 0.0001)
    // Diagonals are the same ring as files and ranks — king-move distance is
    // the metric a chess board actually radiates in.
    #expect(BoardMetrics.staggerDelay(from: .a1, to: .c3) == BoardMetrics.staggerDelay(from: .a1, to: .a3))
  }

  @Test func theStaggerIsMonotonicInDistance() {
    let origin = Square.d4
    for square in Square.allCases where square != origin {
      for other in Square.allCases where other != origin {
        guard Square.distance(origin, square) < Square.distance(origin, other) else { continue }
        #expect(
          BoardMetrics.staggerDelay(from: origin, to: square)
            < BoardMetrics.staggerDelay(from: origin, to: other)
        )
      }
    }
  }

  @Test func everyKnightDestinationLeavesTogether() {
    // All eight are equidistant, so radiating out from the origin means they go
    // at once. That is correct, not a missing stagger.
    let delays = [Square.f3, .f5, .e2, .e6, .c2, .c6, .b3, .b5]
      .map { BoardMetrics.staggerDelay(from: .d4, to: $0) }
    #expect(Set(delays).count == 1)
  }

  @Test func theWholeStaggerFitsInsideATenthOfASecondAndABit() {
    // Longer than this and putting a piece down starts to feel like waiting.
    let worst = Square.allCases.map { BoardMetrics.staggerDelay(from: .a1, to: $0) }.max() ?? 0
    #expect(worst <= 0.15)
  }

  @Test func noOriginMeansNoStagger() {
    // Marks that are not part of a selection — a coach hint, a review moment —
    // have nothing to radiate from and simply leave.
    #expect(BoardMetrics.staggerDelay(from: nil, to: .h8) == 0)
  }

  // MARK: - Coordinates

  @Test func coordinatesAreAboutNinePointsOnAPhoneBoard() {
    let size = BoardMetrics.coordinateFontSize(squareSide: 45)
    #expect(size == 9)
  }

  @Test func coordinatesGrowWithDynamicTypeButNeverSwallowTheirSquare() {
    let huge = BoardMetrics.coordinateFontSize(squareSide: 45, typeScale: 3)
    #expect(huge > 9)
    #expect(huge <= 45 * 0.30)
  }

  @Test func coordinatesStayLegibleOnAThumbnail() {
    #expect(BoardMetrics.coordinateFontSize(squareSide: 20) >= 6)
  }
}
