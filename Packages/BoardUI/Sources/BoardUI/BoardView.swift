//
//  BoardView.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// The chess board.
///
/// `BoardView` renders a position and reports move *attempts*; it never mutates
/// the game. The caller owns the `Position` and answers each attempt with a
/// ``MoveAcceptance``. That split is what makes the training flows possible —
/// a coach can refuse a blunder and the board simply puts the piece back, with
/// no undo stack and no divergence between what is drawn and what is true.
///
/// Layers, back to front:
/// 1. squares (`Canvas`) 2. highlights below pieces 3. arrows 4. pieces
/// 5. highlights above pieces 6. the dragged piece 7. input, which carries the
/// per-square accessibility grid with it 8. promotion picker.
public struct BoardView: View {

  private let position: Position
  private let orientation: Piece.Color
  private let interaction: BoardInteraction
  private let highlights: [SquareHighlight]
  private let arrows: [BoardArrow]
  private let style: BoardStyle

  @State private var model: BoardModel
  @Environment(\.colorScheme) private var colorScheme

  public init(
    position: Position,
    orientation: Piece.Color = .white,
    interaction: BoardInteraction = .locked,
    highlights: [SquareHighlight] = [],
    arrows: [BoardArrow] = [],
    style: BoardStyle = .default
  ) {
    self.position = position
    self.orientation = orientation
    self.interaction = interaction
    self.highlights = highlights
    self.arrows = arrows
    self.style = style
    _model = State(initialValue: BoardModel(position: position, orientation: orientation))
  }

  public var body: some View {
    GeometryReader { proxy in
      let geometry = BoardGeometry(side: min(proxy.size.width, proxy.size.height), orientation: orientation)

      board(geometry)
        .frame(width: geometry.side, height: geometry.side)
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
    // The board is always square; letting it stretch would put the pieces on an
    // oval grid, and every drop target would be wrong.
    .aspectRatio(1, contentMode: .fit)
    .onChange(of: position) { _, newValue in model.update(position: newValue) }
    .onChange(of: orientation) { _, newValue in model.orientation = newValue }
    .modifier(BoardFeedback(model: model))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Chess board"))
  }

  // MARK: - Layers

  @ViewBuilder
  private func board(_ geometry: BoardGeometry) -> some View {
    ZStack(alignment: .topLeading) {
      BoardSquaresLayer(geometry: geometry, style: style)

      BoardHighlightLayer(
        highlights: allHighlights,
        geometry: geometry,
        style: style,
        abovePieces: false
      )

      #if os(macOS)
        // Pointer feedback belongs under the pieces: a ring drawn over a piece
        // reads as a selection, which it is not.
        hoverMark(geometry)
      #endif

      BoardArrowLayer(arrows: arrows, geometry: geometry, style: style)

      BoardPiecesLayer(
        tokens: model.layout.tokens,
        departing: model.departing,
        geometry: geometry,
        style: style,
        // Hidden for the whole drag, the snap-back included: while the ghost is
        // travelling home there must not be a second copy already sitting there.
        draggingTokenID: model.drag?.tokenID
      )

      BoardHighlightLayer(
        highlights: allHighlights,
        geometry: geometry,
        style: style,
        abovePieces: true
      )

      rejectionMark(geometry)

      if let drag = model.drag, let token = model.layout.tokens.first(where: { $0.id == drag.tokenID }) {
        BoardDragLayer(drag: drag, token: token, geometry: geometry, style: style)
      }

      inputSurface(geometry)

      if let pending = model.pendingPromotion {
        PromotionPicker(
          pending: pending,
          geometry: geometry,
          style: style,
          onChoose: { model.choosePromotion($0, geometry: geometry) },
          onCancel: { model.cancelPromotion() }
        )
      }

      rejectionReason(geometry)
    }
    .animation(.snappy(duration: 0.2), value: model.pendingPromotion)
  }

  /// Caller highlights, plus the ones the board owns: selection, legal
  /// destinations and check. The board's own marks come last so a caller can
  /// never accidentally suppress "your king is in check".
  private var allHighlights: [SquareHighlight] {
    var result = highlights
    result.append(contentsOf: model.interactionHighlights())
    if let checked = model.checkedKingSquare {
      result.append(SquareHighlight(checked, .check))
    }
    // De-duplicate while keeping the first occurrence, so a caller-supplied
    // `.hint` on a square is not drawn twice.
    var seen = Set<String>()
    return result.filter { seen.insert($0.id).inserted }
  }

  @ViewBuilder
  private func rejectionMark(_ geometry: BoardGeometry) -> some View {
    if let rejection = model.rejection {
      Rectangle()
        .strokeBorder(
          style.danger.color(colorScheme).opacity(0.85),
          lineWidth: geometry.squareSide * 0.07
        )
        .frame(width: geometry.squareSide, height: geometry.squareSide)
        .position(geometry.center(of: rejection.square))
        .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
        .transition(.opacity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: rejection.token)
    }
  }

  @ViewBuilder
  private func rejectionReason(_ geometry: BoardGeometry) -> some View {
    if let reason = model.rejection?.reason {
      VStack {
        Spacer()
        Text(reason)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.primary)
          .padding(.horizontal, 12)
          .padding(.vertical, 7)
          .background(.regularMaterial, in: Capsule())
          .padding(.bottom, geometry.squareSide * 0.25)
      }
      .frame(width: geometry.side, height: geometry.side)
      .transition(.opacity.combined(with: .move(edge: .bottom)))
      .allowsHitTesting(false)
      .animation(.snappy, value: model.rejection?.token)
    }
  }

  #if os(macOS)
    @ViewBuilder
    private func hoverMark(_ geometry: BoardGeometry) -> some View {
      if let hovered = model.hoveredSquare, interaction.allowsPieceSelection {
        Rectangle()
          .fill(style.accent.color(colorScheme).opacity(0.12))
          .frame(width: geometry.squareSide, height: geometry.squareSide)
          .position(geometry.center(of: hovered))
          .frame(width: geometry.side, height: geometry.side, alignment: .topLeading)
          .allowsHitTesting(false)
          .animation(.easeOut(duration: 0.1), value: hovered)
      }
    }
  #endif

  // MARK: - Input

  /// A transparent surface on top of the board that owns every pointer event.
  ///
  /// The gesture only translates events into board space; what a press *means*
  /// belongs to ``BoardModel`` so it can be tested without a rendered board.
  /// One gesture handles both idioms — a press that never travels is a tap, one
  /// that travels is a drag, and either can finish a move the other started.
  private func inputSurface(_ geometry: BoardGeometry) -> some View {
    ZStack(alignment: .topLeading) {
      Color.clear.contentShape(Rectangle())

      // The squares sit *inside* the gesture's view rather than beside it: they
      // carry no gesture of their own, so touches still reach the drag gesture
      // on their parent, while VoiceOver gets 64 properly-framed elements
      // instead of one board-sized rectangle with nothing to say.
      BoardAccessibilityLayer(model: model, geometry: geometry, interaction: interaction)
        .accessibilityHidden(model.pendingPromotion != nil)
    }
    .frame(width: geometry.side, height: geometry.side)
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
        .onChanged { value in
          model.pressChanged(
            start: value.startLocation,
            location: value.location,
            geometry: geometry,
            interaction: interaction
          )
        }
        .onEnded { value in
          model.pressEnded(
            start: value.startLocation,
            location: value.location,
            geometry: geometry,
            interaction: interaction
          )
        }
    )
    #if os(macOS)
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case let .active(point):
          model.hoveredSquare = geometry.square(at: point)
        case .ended:
          model.hoveredSquare = nil
        @unknown default:
          model.hoveredSquare = nil
        }
      }
    #endif
  }
}

// MARK: - Haptics

/// Sensory feedback, isolated so `BoardView.body` does not sprout `#if os` forks.
private struct BoardFeedback: ViewModifier {

  let model: BoardModel

  func body(content: Content) -> some View {
    #if os(iOS)
      content
        // Three distinguishable taps: a quiet click when a piece lands, a
        // heavier one when something comes off the board, and a warning pulse
        // for check — the one event a player must never miss.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: model.placementTicks)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.9), trigger: model.captureTicks)
        .sensoryFeedback(.warning, trigger: model.checkTicks)
    #else
      content
    #endif
  }
}

// MARK: - Previews

private let midgameFEN = "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 6 5"
private let promotionFEN = "8/3P2k1/8/8/8/8/6K1/8 w - - 0 1"
private let checkFEN = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"

#Preview("Start position") {
  BoardView(position: .standard)
    .padding()
}

#Preview("Midgame · highlights + arrows") {
  BoardView(
    position: Position(fen: midgameFEN)!,
    orientation: .white,
    highlights: SquareHighlight.lastMove(from: .c1, to: .c4)
      + [
        SquareHighlight(.f7, .hint),
        SquareHighlight(.e5, .momentSquare)
      ],
    arrows: [
      BoardArrow(from: .f3, to: .g5, style: .best),
      BoardArrow(from: .c4, to: .f7, style: .alternative),
      BoardArrow(from: .c5, to: .f2, style: .threat)
    ]
  )
  .padding()
}

#Preview("Black orientation · coordinates") {
  BoardView(
    position: Position(fen: midgameFEN)!,
    orientation: .black,
    style: .ink.showingCoordinates()
  )
  .padding()
}

#Preview("Check") {
  BoardView(position: Position(fen: checkFEN)!)
    .padding()
}

#Preview("Interactive · tap-tap and drag") {
  @Previewable @State var position = Position.standard

  // Both idioms, side by side in the same board: tap a piece then tap a
  // destination, or drag it there. Either finishes a move the other started.
  BoardView(
    position: position,
    interaction: .userMove { from, to in
      var board = Board(position: position)
      guard board.move(pieceAt: from, to: to) != nil else { return .rejected }
      position = board.position
      return .accepted
    },
    style: .default.showingCoordinates()
  )
  .padding()
}

#Preview("Contrast · light and dark") {
  // A white piece is barely a shade away from a light square, so the outline is
  // what makes the shape legible rather than the fill. Both appearances go here
  // side by side because that outline is the thing most easily lost when the
  // palette is retuned. Increased contrast cannot be forced from a preview —
  // `colorSchemeContrast` is read-only — so it is checked in Accessibility
  // Inspector or with Settings › Accessibility › Increase Contrast on.
  HStack(spacing: 12) {
    ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
      BoardView(
        position: Position(fen: midgameFEN)!,
        style: .default.showingCoordinates()
      )
      .padding(8)
      .background(scheme == .dark ? Color.black : Color.white)
      .environment(\.colorScheme, scheme)
    }
  }
  .padding()
}

#Preview("Interactive · rejects every capture") {
  @Previewable @State var position = Position(fen: midgameFEN)!

  BoardView(
    position: position,
    interaction: .userMove { from, to in
      // Stands in for the "second try" coach: refuse the move, the piece
      // travels back, the user tries again.
      if position.piece(at: to) != nil {
        return .rejected(reason: "Look for a quieter move first.")
      }
      var board = Board(position: position)
      guard board.move(pieceAt: from, to: to) != nil else { return .rejected }
      position = board.position
      return .accepted
    }
  )
  .padding()
}

#Preview("Promotion picker") {
  @Previewable @State var position = Position(fen: promotionFEN)!

  BoardView(
    position: position,
    interaction: .userMove { from, to in
      var board = Board(position: position)
      guard let move = board.move(pieceAt: from, to: to) else { return .rejected }
      if case .promotion = board.state {
        return .needsPromotion(complete: { kind in
          board.completePromotion(of: move, to: kind)
          position = board.position
          return .accepted
        })
      }
      position = board.position
      return .accepted
    }
  )
  .padding()
}

#Preview("Themes") {
  VStack(spacing: 12) {
    ForEach(BoardStyle.builtIn) { theme in
      BoardView(position: .standard, style: theme.showingCoordinates())
        .frame(height: 170)
    }
  }
  .padding()
}
