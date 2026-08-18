//
//  BoardGeometry.swift
//  BoardUI
//

import ChessKit
import CoreGraphics

/// Pure square ↔ point conversion for a board of a given size and orientation.
///
/// Every layer (squares, highlights, arrows, pieces, drag) derives its
/// coordinates from this one value, so a rounding change lands everywhere at
/// once. It has no SwiftUI dependency, which is what makes it unit-testable.
///
/// Coordinates are in the board's own space: `(0, 0)` is the top-left of the
/// **board**, not of the container. ``origin`` records where that corner sits
/// inside the container when the container is not square.
public struct BoardGeometry: Equatable, Sendable {

  /// The edge length of the board in points.
  public let side: CGFloat

  /// Top-left corner of the board inside its container.
  public let origin: CGPoint

  /// Which colour is at the bottom of the board.
  public let orientation: Piece.Color

  /// Fits the largest centred square board inside `containerSize`.
  public init(containerSize: CGSize, orientation: Piece.Color) {
    let fitted = max(0, min(containerSize.width, containerSize.height))
    self.side = fitted
    self.origin = CGPoint(
      x: (containerSize.width - fitted) / 2,
      y: (containerSize.height - fitted) / 2
    )
    self.orientation = orientation
  }

  /// Creates a geometry directly. Mostly used by tests and previews.
  public init(side: CGFloat, origin: CGPoint = .zero, orientation: Piece.Color = .white) {
    self.side = max(0, side)
    self.origin = origin
    self.orientation = orientation
  }

  /// The edge length of one square.
  public var squareSide: CGFloat { side / 8 }

  // MARK: - Square → grid

  /// Column index, 0 at the left edge of the board as drawn.
  public func column(of square: Square) -> Int {
    orientation == .white ? square.fileNumber - 1 : 8 - square.fileNumber
  }

  /// Row index, 0 at the top edge of the board as drawn.
  public func row(of square: Square) -> Int {
    orientation == .white ? 8 - square.rankNumber : square.rankNumber - 1
  }

  /// The square at a grid position, or `nil` if the position is off the board.
  public func square(column: Int, row: Int) -> Square? {
    guard (0...7).contains(column), (0...7).contains(row) else { return nil }
    let file = orientation == .white ? column + 1 : 8 - column
    let rank = orientation == .white ? 8 - row : row + 1
    return Square.at(file: file, rank: rank)
  }

  // MARK: - Square → point

  /// The rect a square occupies, in board space.
  public func frame(of square: Square) -> CGRect {
    CGRect(
      x: CGFloat(column(of: square)) * squareSide,
      y: CGFloat(row(of: square)) * squareSide,
      width: squareSide,
      height: squareSide
    )
  }

  /// The centre point of a square, in board space.
  public func center(of square: Square) -> CGPoint {
    let f = frame(of: square)
    return CGPoint(x: f.midX, y: f.midY)
  }

  // MARK: - Point → square

  /// The square containing `point`, or `nil` when the point is off the board.
  ///
  /// Used for hit-testing where landing outside the board should cancel rather
  /// than snap — for example a drag that leaves the board entirely.
  public func square(at point: CGPoint) -> Square? {
    guard squareSide > 0 else { return nil }
    guard point.x >= 0, point.y >= 0, point.x < side, point.y < side else { return nil }
    return square(
      column: Int(point.x / squareSide),
      row: Int(point.y / squareSide)
    )
  }

  /// The square whose centre is nearest to `point`, clamped to the board.
  ///
  /// Drop targets use this rather than ``square(at:)``: a finger that overshoots
  /// the edge by a few points still means "the edge square", and a dropped piece
  /// must always land somewhere.
  public func nearestSquare(to point: CGPoint) -> Square {
    guard squareSide > 0 else { return orientation == .white ? .a8 : .h1 }
    let column = clampToBoard(Int((point.x / squareSide).rounded(.down)))
    let row = clampToBoard(Int((point.y / squareSide).rounded(.down)))
    // `square(column:row:)` cannot fail after clamping; the fallback keeps the
    // API non-optional for callers that must produce a destination.
    return square(column: column, row: row) ?? (orientation == .white ? .a8 : .h1)
  }

  private func clampToBoard(_ value: Int) -> Int {
    min(7, max(0, value))
  }

  // MARK: - Container conversion

  /// Converts a point in the container's coordinate space to board space.
  public func boardPoint(fromContainer point: CGPoint) -> CGPoint {
    CGPoint(x: point.x - origin.x, y: point.y - origin.y)
  }
}
