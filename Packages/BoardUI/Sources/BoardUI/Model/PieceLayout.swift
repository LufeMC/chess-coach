//
//  PieceLayout.swift
//  BoardUI
//

import ChessKit

/// One piece on screen, with an identity that survives a move.
///
/// ChessKit identifies a piece by (kind, colour, square), so a knight that moves
/// looks to SwiftUI like one knight disappearing and a different knight
/// appearing — which pops instead of sliding. The token's `id` is what gives
/// SwiftUI a stable identity to animate between.
public struct PieceToken: Identifiable, Equatable, Sendable {
  public let id: Int
  public var kind: Piece.Kind
  public var color: Piece.Color
  public var square: Square

  public var piece: Piece { Piece(kind, color: color, square: square) }
}

/// Assigns and maintains stable identities for the pieces on the board.
///
/// Pure value logic with no SwiftUI in sight, so the matching rules — the part
/// that decides whether a move slides, pops, or slides the *wrong* piece — can
/// be unit-tested directly.
public struct PieceLayout: Equatable, Sendable {

  public private(set) var tokens: [PieceToken] = []
  private var nextID = 0

  public init() {}

  public init(pieces: [Piece]) {
    apply(pieces: pieces)
  }

  public init(position: Position) {
    apply(pieces: position.pieces)
  }

  /// Reconciles the current tokens against a new set of pieces.
  public mutating func apply(position: Position) {
    apply(pieces: position.pieces)
  }

  /// Reconciles the current tokens against a new set of pieces.
  ///
  /// Matching runs in three passes, cheapest and most certain first:
  /// 1. pieces that did not move keep their token;
  /// 2. remaining pieces adopt the nearest unused token of the same kind and
  ///    colour — that is the move, and it is what makes the piece slide;
  /// 3. a piece arriving on a promotion rank adopts an adjacent leftover pawn,
  ///    so a promotion slides in and changes shape instead of teleporting.
  ///
  /// Anything still unmatched is new (board reset, position jump) and gets a
  /// fresh identity; anything left over was captured and simply disappears.
  public mutating func apply(pieces: [Piece]) {
    var available = tokens
    var matched = [PieceToken?](repeating: nil, count: pieces.count)

    // Pass 1 — unchanged squares.
    for (index, piece) in pieces.enumerated() {
      if let slot = available.firstIndex(where: {
        $0.square == piece.square && $0.kind == piece.kind && $0.color == piece.color
      }) {
        matched[index] = available.remove(at: slot)
      }
    }

    // Pass 2 — same piece, new square: the nearest candidate wins.
    for (index, piece) in pieces.enumerated() where matched[index] == nil {
      let candidates = available.indices.filter {
        available[$0].kind == piece.kind && available[$0].color == piece.color
      }
      guard
        let slot = candidates.min(by: {
          let lhs = Square.distance(available[$0].square, piece.square)
          let rhs = Square.distance(available[$1].square, piece.square)
          // Ties break on raw value so the same board always yields the same
          // assignment — otherwise two identical rooks can swap identities
          // between renders and both slide across the board.
          return lhs == rhs
            ? available[$0].square.rawValue < available[$1].square.rawValue
            : lhs < rhs
        })
      else { continue }
      var token = available.remove(at: slot)
      token.square = piece.square
      matched[index] = token
    }

    // Pass 3 — promotions.
    for (index, piece) in pieces.enumerated() where matched[index] == nil {
      guard piece.kind != .pawn else { continue }
      let promotionRank = piece.color == .white ? 8 : 1
      guard piece.square.rankNumber == promotionRank else { continue }
      guard
        let slot = available.firstIndex(where: {
          $0.kind == .pawn && $0.color == piece.color
            && Square.distance($0.square, piece.square) <= 1
        })
      else { continue }
      var token = available.remove(at: slot)
      token.square = piece.square
      token.kind = piece.kind
      matched[index] = token
    }

    // Pass 4 — genuinely new pieces.
    var result: [PieceToken] = []
    result.reserveCapacity(pieces.count)
    for (index, piece) in pieces.enumerated() {
      if let token = matched[index] {
        result.append(token)
      } else {
        result.append(
          PieceToken(id: nextID, kind: piece.kind, color: piece.color, square: piece.square)
        )
        nextID += 1
      }
    }

    // Stable ordering keeps `ForEach` diffs minimal and tests deterministic.
    tokens = result.sorted { $0.id < $1.id }
  }

  /// The token currently occupying a square, if any.
  public func token(at square: Square) -> PieceToken? {
    tokens.first { $0.square == square }
  }
}
