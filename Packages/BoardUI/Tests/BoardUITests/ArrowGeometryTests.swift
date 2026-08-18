//
//  ArrowGeometryTests.swift
//  BoardUITests
//

import ChessKit
import CoreGraphics
import Testing

@testable import BoardUI

struct ArrowGeometryTests {

  private let geometry = BoardGeometry(side: 800, orientation: .white)

  private func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
  }

  private func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    a.x * b.x + a.y * b.y
  }

  @Test func zeroLengthArrowsAreRejected() {
    #expect(ArrowGeometry.make(from: .e4, to: .e4, in: geometry) == nil)
    #expect(ArrowGeometry.make(from: .e4, to: .e5, in: BoardGeometry(side: 0)) == nil)
  }

  @Test func shaftStartsClearOfTheSourcePiece() throws {
    let arrow = try #require(ArrowGeometry.make(from: .e2, to: .e6, in: geometry))
    let source = geometry.center(of: .e2)
    // The gap has to be big enough to leave the piece readable but must not
    // swallow a whole square.
    #expect(length(arrow.start, source) > geometry.squareSide * 0.25)
    #expect(length(arrow.start, source) < geometry.squareSide * 0.5)
  }

  @Test func tipLandsInsideTheDestinationSquare() throws {
    let arrow = try #require(ArrowGeometry.make(from: .e2, to: .e6, in: geometry))
    #expect(geometry.square(at: arrow.tip) == .e6)
  }

  @Test func straightArrowsRunThroughBothCentres() throws {
    let arrow = try #require(ArrowGeometry.make(from: .a1, to: .a8, in: geometry))
    #expect(!arrow.isCurved)
    let midpoint = CGPoint(x: (arrow.start.x + arrow.tip.x) / 2, y: (arrow.start.y + arrow.tip.y) / 2)
    // With no bow, the control point is the midpoint, so the quadratic
    // degenerates to a straight line.
    #expect(abs(arrow.control.x - midpoint.x) < 0.001)
    #expect(abs(arrow.control.y - midpoint.y) < 0.001)
    #expect(abs(arrow.start.x - geometry.center(of: .a1).x) < 0.001)
  }

  @Test func knightArrowsBow() throws {
    let arrow = try #require(ArrowGeometry.make(from: .g1, to: .f3, in: geometry))
    #expect(arrow.isCurved)
    let midpoint = CGPoint(x: (arrow.start.x + arrow.tip.x) / 2, y: (arrow.start.y + arrow.tip.y) / 2)
    #expect(length(arrow.control, midpoint) > geometry.squareSide * 0.4)
  }

  @Test(arguments: [
    (Square.b1, Square.c3), (.b1, .a3), (.g8, .f6), (.d4, .e6), (.d4, .f5)
  ])
  func everyKnightShapeIsDetected(from: Square, to: Square) throws {
    let arrow = try #require(ArrowGeometry.make(from: from, to: to, in: geometry))
    #expect(arrow.isCurved)
  }

  @Test(arguments: [
    (Square.a1, Square.a2), (.a1, .h8), (.d4, .d8), (.d4, .h4), (.d4, .a7)
  ])
  func nonKnightShapesStayStraight(from: Square, to: Square) throws {
    let arrow = try #require(ArrowGeometry.make(from: from, to: to, in: geometry))
    #expect(!arrow.isCurved)
  }

  @Test func headIsSymmetricAndSquareToTheShaft() throws {
    for (from, to) in [(Square.e2, Square.e6), (.a1, .h8), (.g1, .f3), (.h8, .a1)] {
      let arrow = try #require(ArrowGeometry.make(from: from, to: to, in: geometry))

      let left = length(arrow.headLeft, arrow.shaftEnd)
      let right = length(arrow.headRight, arrow.shaftEnd)
      #expect(abs(left - right) < 0.001, "head corners must be equidistant")

      let across = CGPoint(x: arrow.headLeft.x - arrow.headRight.x, y: arrow.headLeft.y - arrow.headRight.y)
      let along = CGPoint(x: arrow.tip.x - arrow.shaftEnd.x, y: arrow.tip.y - arrow.shaftEnd.y)
      #expect(abs(dot(across, along)) < 0.001, "head base must be perpendicular to the shaft")
    }
  }

  @Test func headPointsAlongTheCurveNotTheChord() throws {
    let arrow = try #require(ArrowGeometry.make(from: .g1, to: .f3, in: geometry))
    let chord = CGPoint(
      x: geometry.center(of: .f3).x - geometry.center(of: .g1).x,
      y: geometry.center(of: .f3).y - geometry.center(of: .g1).y
    )
    let along = CGPoint(x: arrow.tip.x - arrow.shaftEnd.x, y: arrow.tip.y - arrow.shaftEnd.y)
    let chordLength = length(.zero, chord)
    let alongLength = length(.zero, along)
    let cosine = dot(chord, along) / (chordLength * alongLength)
    // Still broadly forward, but visibly rotated away from the straight line.
    #expect(cosine > 0.3)
    #expect(cosine < 0.99)
  }

  @Test func shortArrowsStayWellFormed() throws {
    // One square apart is the tightest case: the nominal insets alone would be
    // longer than the arrow.
    let arrow = try #require(ArrowGeometry.make(from: .e4, to: .e5, in: geometry))
    let span = length(arrow.start, arrow.tip)
    #expect(span > 0)
    #expect(length(arrow.start, arrow.shaftEnd) <= span + 0.001)
    #expect(arrow.shaftWidth > 0)
  }

  @Test func arrowScalesWithTheBoard() throws {
    let small = BoardGeometry(side: 200, orientation: .white)
    let large = BoardGeometry(side: 800, orientation: .white)
    let a = try #require(ArrowGeometry.make(from: .e2, to: .e6, in: small))
    let b = try #require(ArrowGeometry.make(from: .e2, to: .e6, in: large))
    #expect(abs(b.shaftWidth / a.shaftWidth - 4) < 0.001)
  }

  @Test func orientationFlipsTheArrowWithTheBoard() throws {
    let flipped = BoardGeometry(side: 800, orientation: .black)
    let white = try #require(ArrowGeometry.make(from: .e2, to: .e6, in: geometry))
    let black = try #require(ArrowGeometry.make(from: .e2, to: .e6, in: flipped))
    // Same arrow, opposite direction on screen.
    #expect((white.tip.y - white.start.y) * (black.tip.y - black.start.y) < 0)
  }
}
