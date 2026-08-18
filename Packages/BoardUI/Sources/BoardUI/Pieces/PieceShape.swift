//
//  PieceShape.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// The silhouette of a chess piece, drawn as vectors.
///
/// The package ships no image assets on purpose: previews have to render
/// standalone, and a board that depends on a bundled sprite sheet cannot be
/// dropped into a Swift Playground or an Xcode preview from a fresh checkout.
/// Every piece is one closed subpath so that filling is winding-safe — overlapping
/// subpaths under the non-zero rule can punch holes when their directions differ,
/// and a hole in a knight is very obvious.
///
/// Details that are genuinely separate (the knight's eye, the bishop's mitre slit)
/// live in ``PieceDetailShape`` and are drawn in the contrast colour on top.
struct PieceShape: Shape {

  let kind: Piece.Kind

  func path(in rect: CGRect) -> Path {
    PieceGeometry.unitPath(for: kind).applying(PieceGeometry.transform(for: rect))
  }
}

/// Contrast-coloured detail drawn over ``PieceShape``. Empty for most kinds.
struct PieceDetailShape: Shape {

  let kind: Piece.Kind

  func path(in rect: CGRect) -> Path {
    PieceGeometry.unitDetailPath(for: kind).applying(PieceGeometry.transform(for: rect))
  }
}

/// The raw coordinates. Everything is authored in a 100 × 100 box with y
/// pointing down, then scaled into whatever rect the view hands over.
enum PieceGeometry {

  static let designSide: CGFloat = 100

  static func transform(for rect: CGRect) -> CGAffineTransform {
    let side = min(rect.width, rect.height)
    return CGAffineTransform(
      translationX: rect.midX - side / 2,
      y: rect.midY - side / 2
    )
    .scaledBy(x: side / designSide, y: side / designSide)
  }

  static func unitPath(for kind: Piece.Kind) -> Path {
    var path = Path()
    // Every piece shares the same footing, so a rank of mixed pieces sits on one
    // visual line instead of each kind floating at its own height.
    path.move(to: CGPoint(x: 18, y: 92))
    path.addLine(to: CGPoint(x: 82, y: 92))
    path.addLine(to: CGPoint(x: 77, y: 84))
    path.addLine(to: CGPoint(x: 70, y: 82))

    switch kind {
    case .pawn: appendPawn(&path)
    case .rook: appendRook(&path)
    case .knight: appendKnight(&path)
    case .bishop: appendBishop(&path)
    case .queen: appendQueen(&path)
    case .king: appendKing(&path)
    }

    path.addLine(to: CGPoint(x: 30, y: 82))
    path.addLine(to: CGPoint(x: 23, y: 84))
    path.closeSubpath()
    return path
  }

  static func unitDetailPath(for kind: Piece.Kind) -> Path {
    var path = Path()
    switch kind {
    case .knight:
      path.addEllipse(in: CGRect(x: 36.5, y: 30.5, width: 7, height: 7))
    case .bishop:
      // The mitre slit: a thin parallelogram running up-left to down-right.
      path.move(to: CGPoint(x: 44, y: 34))
      path.addLine(to: CGPoint(x: 48.5, y: 29))
      path.addLine(to: CGPoint(x: 58, y: 41))
      path.addLine(to: CGPoint(x: 53.5, y: 46))
      path.closeSubpath()
    case .pawn, .rook, .queen, .king:
      break
    }
    return path
  }

  // MARK: - Per-kind bodies
  //
  // Each body starts at (70, 82) — the right edge of the collar — travels up the
  // right side, across the top, and back down the left side, ending at the point
  // where the shared base resumes.

  private static func appendPawn(_ path: inout Path) {
    path.addCurve(
      to: CGPoint(x: 58, y: 54),
      control1: CGPoint(x: 66, y: 74),
      control2: CGPoint(x: 60, y: 64)
    )
    path.addLine(to: CGPoint(x: 57, y: 44))
    // Head, approximated as a circle of radius 14 centred on (50, 32).
    path.addCurve(
      to: CGPoint(x: 64, y: 32),
      control1: CGPoint(x: 61, y: 40),
      control2: CGPoint(x: 64, y: 38)
    )
    path.addCurve(
      to: CGPoint(x: 50, y: 18),
      control1: CGPoint(x: 64, y: 24),
      control2: CGPoint(x: 58, y: 18)
    )
    path.addCurve(
      to: CGPoint(x: 36, y: 32),
      control1: CGPoint(x: 42, y: 18),
      control2: CGPoint(x: 36, y: 24)
    )
    path.addCurve(
      to: CGPoint(x: 43, y: 44),
      control1: CGPoint(x: 36, y: 38),
      control2: CGPoint(x: 39, y: 40)
    )
    path.addLine(to: CGPoint(x: 42, y: 54))
    path.addCurve(
      to: CGPoint(x: 30, y: 82),
      control1: CGPoint(x: 40, y: 64),
      control2: CGPoint(x: 34, y: 74)
    )
  }

  private static func appendRook(_ path: inout Path) {
    path.addLine(to: CGPoint(x: 66, y: 44))
    path.addLine(to: CGPoint(x: 70, y: 36))
    path.addLine(to: CGPoint(x: 74, y: 36))
    // Battlement: three merlons, two embrasures.
    path.addLine(to: CGPoint(x: 74, y: 12))
    path.addLine(to: CGPoint(x: 63, y: 12))
    path.addLine(to: CGPoint(x: 63, y: 21))
    path.addLine(to: CGPoint(x: 56, y: 21))
    path.addLine(to: CGPoint(x: 56, y: 12))
    path.addLine(to: CGPoint(x: 44, y: 12))
    path.addLine(to: CGPoint(x: 44, y: 21))
    path.addLine(to: CGPoint(x: 37, y: 21))
    path.addLine(to: CGPoint(x: 37, y: 12))
    path.addLine(to: CGPoint(x: 26, y: 12))
    path.addLine(to: CGPoint(x: 26, y: 36))
    path.addLine(to: CGPoint(x: 30, y: 36))
    path.addLine(to: CGPoint(x: 34, y: 44))
    path.addLine(to: CGPoint(x: 34, y: 82))
  }

  private static func appendKnight(_ path: inout Path) {
    // Horse's head in profile, facing left. The right side of the outline is the
    // back of the neck; the left side is the face.
    path.addCurve(
      to: CGPoint(x: 67, y: 48),
      control1: CGPoint(x: 73, y: 70),
      control2: CGPoint(x: 71, y: 58)
    )
    path.addCurve(
      to: CGPoint(x: 56, y: 22),
      control1: CGPoint(x: 64, y: 38),
      control2: CGPoint(x: 62, y: 28)
    )
    path.addLine(to: CGPoint(x: 58, y: 10))
    path.addLine(to: CGPoint(x: 48, y: 20))
    path.addLine(to: CGPoint(x: 43, y: 11))
    path.addLine(to: CGPoint(x: 38, y: 24))
    path.addCurve(
      to: CGPoint(x: 16, y: 46),
      control1: CGPoint(x: 30, y: 28),
      control2: CGPoint(x: 19, y: 34)
    )
    path.addLine(to: CGPoint(x: 20, y: 54))
    path.addCurve(
      to: CGPoint(x: 38, y: 60),
      control1: CGPoint(x: 28, y: 58),
      control2: CGPoint(x: 33, y: 60)
    )
    path.addCurve(
      to: CGPoint(x: 30, y: 82),
      control1: CGPoint(x: 32, y: 68),
      control2: CGPoint(x: 30, y: 74)
    )
  }

  private static func appendBishop(_ path: inout Path) {
    path.addCurve(
      to: CGPoint(x: 60, y: 60),
      control1: CGPoint(x: 68, y: 74),
      control2: CGPoint(x: 63, y: 68)
    )
    path.addLine(to: CGPoint(x: 64, y: 54))
    path.addCurve(
      to: CGPoint(x: 57, y: 26),
      control1: CGPoint(x: 64, y: 42),
      control2: CGPoint(x: 61, y: 32)
    )
    // The finial is part of the outline rather than a floating circle, so the
    // fill stays a single subpath.
    path.addCurve(
      to: CGPoint(x: 50, y: 8),
      control1: CGPoint(x: 55, y: 18),
      control2: CGPoint(x: 56, y: 8)
    )
    path.addCurve(
      to: CGPoint(x: 43, y: 26),
      control1: CGPoint(x: 44, y: 8),
      control2: CGPoint(x: 45, y: 18)
    )
    path.addCurve(
      to: CGPoint(x: 36, y: 54),
      control1: CGPoint(x: 39, y: 32),
      control2: CGPoint(x: 36, y: 42)
    )
    path.addLine(to: CGPoint(x: 40, y: 60))
    path.addCurve(
      to: CGPoint(x: 30, y: 82),
      control1: CGPoint(x: 37, y: 68),
      control2: CGPoint(x: 32, y: 74)
    )
  }

  private static func appendQueen(_ path: inout Path) {
    path.addCurve(
      to: CGPoint(x: 62, y: 58),
      control1: CGPoint(x: 68, y: 72),
      control2: CGPoint(x: 64, y: 64)
    )
    path.addLine(to: CGPoint(x: 66, y: 50))
    // Five-point coronet: tips at y = 14, valleys at y = 34.
    path.addLine(to: CGPoint(x: 78, y: 48))
    path.addLine(to: CGPoint(x: 76, y: 15))
    path.addLine(to: CGPoint(x: 69, y: 34))
    path.addLine(to: CGPoint(x: 63, y: 13))
    path.addLine(to: CGPoint(x: 56, y: 32))
    path.addLine(to: CGPoint(x: 50, y: 11))
    path.addLine(to: CGPoint(x: 44, y: 32))
    path.addLine(to: CGPoint(x: 37, y: 13))
    path.addLine(to: CGPoint(x: 31, y: 34))
    path.addLine(to: CGPoint(x: 24, y: 15))
    path.addLine(to: CGPoint(x: 22, y: 48))
    path.addLine(to: CGPoint(x: 34, y: 50))
    path.addLine(to: CGPoint(x: 38, y: 58))
    path.addCurve(
      to: CGPoint(x: 30, y: 82),
      control1: CGPoint(x: 36, y: 64),
      control2: CGPoint(x: 32, y: 72)
    )
  }

  private static func appendKing(_ path: inout Path) {
    path.addCurve(
      to: CGPoint(x: 62, y: 58),
      control1: CGPoint(x: 68, y: 72),
      control2: CGPoint(x: 64, y: 64)
    )
    path.addLine(to: CGPoint(x: 66, y: 50))
    path.addLine(to: CGPoint(x: 77, y: 47))
    path.addLine(to: CGPoint(x: 70, y: 25))
    path.addLine(to: CGPoint(x: 58, y: 32))
    path.addLine(to: CGPoint(x: 55, y: 21))
    // Surmounting cross.
    path.addLine(to: CGPoint(x: 55, y: 18))
    path.addLine(to: CGPoint(x: 62, y: 18))
    path.addLine(to: CGPoint(x: 62, y: 12))
    path.addLine(to: CGPoint(x: 55, y: 12))
    path.addLine(to: CGPoint(x: 55, y: 6))
    path.addLine(to: CGPoint(x: 45, y: 6))
    path.addLine(to: CGPoint(x: 45, y: 12))
    path.addLine(to: CGPoint(x: 38, y: 12))
    path.addLine(to: CGPoint(x: 38, y: 18))
    path.addLine(to: CGPoint(x: 45, y: 18))
    path.addLine(to: CGPoint(x: 45, y: 21))
    path.addLine(to: CGPoint(x: 42, y: 32))
    path.addLine(to: CGPoint(x: 30, y: 25))
    path.addLine(to: CGPoint(x: 23, y: 47))
    path.addLine(to: CGPoint(x: 34, y: 50))
    path.addLine(to: CGPoint(x: 38, y: 58))
    path.addCurve(
      to: CGPoint(x: 30, y: 82),
      control1: CGPoint(x: 36, y: 64),
      control2: CGPoint(x: 32, y: 72)
    )
  }
}
