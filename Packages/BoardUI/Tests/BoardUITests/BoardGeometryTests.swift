//
//  BoardGeometryTests.swift
//  BoardUITests
//

import ChessKit
import CoreGraphics
import Testing

@testable import BoardUI

struct BoardGeometryTests {

  private let side: CGFloat = 800  // 100pt squares keeps the arithmetic readable

  // MARK: - Grid mapping

  @Test func whiteOrientationPutsA8TopLeft() {
    let geometry = BoardGeometry(side: side, orientation: .white)
    #expect(geometry.column(of: .a8) == 0)
    #expect(geometry.row(of: .a8) == 0)
    #expect(geometry.column(of: .h1) == 7)
    #expect(geometry.row(of: .h1) == 7)
  }

  @Test func blackOrientationPutsH1TopLeft() {
    let geometry = BoardGeometry(side: side, orientation: .black)
    #expect(geometry.column(of: .h1) == 0)
    #expect(geometry.row(of: .h1) == 0)
    #expect(geometry.column(of: .a8) == 7)
    #expect(geometry.row(of: .a8) == 7)
  }

  @Test(arguments: [Piece.Color.white, .black])
  func gridRoundTripsForEverySquare(orientation: Piece.Color) {
    let geometry = BoardGeometry(side: side, orientation: orientation)
    for square in Square.allCases {
      let column = geometry.column(of: square)
      let row = geometry.row(of: square)
      #expect(geometry.square(column: column, row: row) == square)
    }
  }

  @Test func offBoardGridPositionsHaveNoSquare() {
    let geometry = BoardGeometry(side: side, orientation: .white)
    #expect(geometry.square(column: -1, row: 0) == nil)
    #expect(geometry.square(column: 0, row: 8) == nil)
    #expect(geometry.square(column: 8, row: 8) == nil)
  }

  // MARK: - Square ↔ point

  @Test(arguments: [Piece.Color.white, .black])
  func centreOfEverySquareMapsBackToItself(orientation: Piece.Color) {
    let geometry = BoardGeometry(side: side, orientation: orientation)
    for square in Square.allCases {
      #expect(geometry.square(at: geometry.center(of: square)) == square)
      #expect(geometry.nearestSquare(to: geometry.center(of: square)) == square)
    }
  }

  @Test func framesTileTheBoardExactly() {
    let geometry = BoardGeometry(side: side, orientation: .white)
    #expect(geometry.frame(of: .a8) == CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(geometry.frame(of: .h1) == CGRect(x: 700, y: 700, width: 100, height: 100))
    #expect(geometry.frame(of: .e4) == CGRect(x: 400, y: 400, width: 100, height: 100))
  }

  @Test func flippingOrientationMirrorsCentres() {
    let white = BoardGeometry(side: side, orientation: .white)
    let black = BoardGeometry(side: side, orientation: .black)
    for square in Square.allCases {
      let w = white.center(of: square)
      let b = black.center(of: square)
      #expect(abs((w.x + b.x) - side) < 0.001)
      #expect(abs((w.y + b.y) - side) < 0.001)
    }
  }

  @Test func pointsOutsideTheBoardHaveNoSquare() {
    let geometry = BoardGeometry(side: side, orientation: .white)
    #expect(geometry.square(at: CGPoint(x: -1, y: 10)) == nil)
    #expect(geometry.square(at: CGPoint(x: 10, y: -1)) == nil)
    #expect(geometry.square(at: CGPoint(x: side, y: 10)) == nil)
    #expect(geometry.square(at: CGPoint(x: 10, y: side + 40)) == nil)
  }

  // MARK: - Snapping

  @Test func nearestSquareClampsBeyondEveryEdge() {
    let geometry = BoardGeometry(side: side, orientation: .white)
    #expect(geometry.nearestSquare(to: CGPoint(x: -500, y: -500)) == .a8)
    #expect(geometry.nearestSquare(to: CGPoint(x: 5_000, y: 5_000)) == .h1)
    #expect(geometry.nearestSquare(to: CGPoint(x: -20, y: 750)) == .a1)
    #expect(geometry.nearestSquare(to: CGPoint(x: 5_000, y: -20)) == .h8)
  }

  @Test func nearestSquareClampsBeyondEveryEdgeWhenFlipped() {
    let geometry = BoardGeometry(side: side, orientation: .black)
    #expect(geometry.nearestSquare(to: CGPoint(x: -500, y: -500)) == .h1)
    #expect(geometry.nearestSquare(to: CGPoint(x: 5_000, y: 5_000)) == .a8)
  }

  @Test func nearestSquarePicksTheSquareThePointIsIn() {
    let geometry = BoardGeometry(side: side, orientation: .white)
    // Just inside d5 (column 3, row 3) on every side.
    #expect(geometry.nearestSquare(to: CGPoint(x: 301, y: 301)) == .d5)
    #expect(geometry.nearestSquare(to: CGPoint(x: 399, y: 399)) == .d5)
    // One point over the boundary lands in the neighbour.
    #expect(geometry.nearestSquare(to: CGPoint(x: 401, y: 399)) == .e5)
    #expect(geometry.nearestSquare(to: CGPoint(x: 399, y: 401)) == .d4)
  }

  @Test func degenerateBoardDoesNotDivideByZero() {
    let geometry = BoardGeometry(side: 0, orientation: .white)
    #expect(geometry.square(at: .zero) == nil)
    #expect(geometry.nearestSquare(to: CGPoint(x: 10, y: 10)) == .a8)
  }

  // MARK: - Container fitting

  @Test func boardIsCentredInsideANonSquareContainer() {
    let geometry = BoardGeometry(
      containerSize: CGSize(width: 1_000, height: 800),
      orientation: .white
    )
    #expect(geometry.side == 800)
    #expect(geometry.origin == CGPoint(x: 100, y: 0))
    #expect(geometry.boardPoint(fromContainer: CGPoint(x: 150, y: 50)) == CGPoint(x: 50, y: 50))
  }
}
