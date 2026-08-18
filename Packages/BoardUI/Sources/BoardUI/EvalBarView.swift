//
//  EvalBarView.swift
//  BoardUI
//

import ChessKit
import SwiftUI

/// The eval bar that runs alongside the board.
///
/// Takes a **win percentage**, 0…100, from White's point of view — not
/// centipawns. A bar is a proportion, and pawns are not proportional: +9 and +30
/// are the same position to a human and wildly different numbers to an engine.
/// Converting once, at the source, keeps the bar honest.
public struct EvalBarView: View {

  private let score: Double
  private let mate: Int?
  private let orientation: Piece.Color
  private let axis: Axis
  private let thickness: CGFloat
  private let showsLabel: Bool

  @Environment(\.colorScheme) private var colorScheme

  public init(
    score: Double,
    mate: Int? = nil,
    orientation: Piece.Color = .white,
    axis: Axis = defaultAxis,
    thickness: CGFloat = 16,
    showsLabel: Bool = true
  ) {
    self.score = score
    self.mate = mate
    self.orientation = orientation
    self.axis = axis
    self.thickness = thickness
    self.showsLabel = showsLabel
  }

  /// Vertical next to a portrait board on iPhone; horizontal reads better under
  /// a wide board on the Mac.
  public static var defaultAxis: Axis {
    #if os(macOS)
      .horizontal
    #else
      .vertical
    #endif
  }

  public var body: some View {
    GeometryReader { proxy in
      let length = axis == .vertical ? proxy.size.height : proxy.size.width
      let whiteLength = length * whiteFraction

      ZStack(alignment: whiteAlignment) {
        Rectangle().fill(blackFill)
        Rectangle()
          .fill(whiteFill)
          .frame(
            width: axis == .vertical ? nil : whiteLength,
            height: axis == .vertical ? whiteLength : nil
          )
      }
      .overlay(alignment: labelAlignment) {
        if showsLabel {
          Text(label)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(labelColor)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .fixedSize()
            .rotationEffect(.degrees(axis == .vertical ? 0 : 0))
            .padding(2)
        }
      }
    }
    .frame(
      width: axis == .vertical ? thickness : nil,
      height: axis == .vertical ? nil : thickness
    )
    .clipShape(Capsule())
    // One spring for the whole bar. Eval arrives in bursts as the engine
    // deepens, and un-animated jumps make a stable position look chaotic.
    .animation(.smooth(duration: 0.45), value: score)
    .animation(.smooth(duration: 0.45), value: mate)
    .accessibilityElement()
    .accessibilityLabel(Text("Evaluation"))
    .accessibilityValue(Text(accessibilityValue))
  }

  // MARK: - Geometry

  /// White's share of the bar, 0…1. A mate score pins the bar to the mating
  /// side: showing 97% when it is mate in two understates it.
  private var whiteFraction: Double {
    if let mate {
      return mate > 0 ? 1 : 0
    }
    return min(1, max(0, score / 100))
  }

  /// The end of the bar that belongs to White, given the board orientation.
  private var whiteAlignment: Alignment {
    switch (axis, orientation) {
    case (.vertical, .white): .bottom
    case (.vertical, .black): .top
    case (.horizontal, .white): .leading
    case (.horizontal, .black): .trailing
    }
  }

  /// The label sits at the viewer's own end of the bar.
  private var labelAlignment: Alignment {
    switch (axis, orientation) {
    case (.vertical, _): .bottom
    case (.horizontal, _): .leading
    }
  }

  // MARK: - Presentation

  private var label: String {
    if let mate {
      return "M\(abs(mate))"
    }
    return "\(Int(min(100, max(0, score)).rounded()))"
  }

  private var accessibilityValue: String {
    if let mate {
      return mate > 0 ? "Mate in \(abs(mate)) for White" : "Mate in \(abs(mate)) for Black"
    }
    return "White \(Int(score.rounded())) percent"
  }

  private var whiteFill: Color {
    colorScheme == .dark ? Color(hex: 0xE9E8E4) : Color(hex: 0xFAFAF7)
  }

  private var blackFill: Color {
    colorScheme == .dark ? Color(hex: 0x232529) : Color(hex: 0x3A3C41)
  }

  /// The label lives at the viewer's end, so it normally sits on the viewer's
  /// own fill — unless they are being crushed and the other fill has reached it.
  private var labelColor: Color {
    let viewerShare = orientation == .white ? whiteFraction : 1 - whiteFraction
    let viewerFillIsWhite = orientation == .white
    let onWhite = viewerShare > 0.16 ? viewerFillIsWhite : !viewerFillIsWhite
    return onWhite ? blackFill : whiteFill
  }
}

// MARK: - Previews

#Preview("Eval bar · vertical") {
  HStack(spacing: 20) {
    ForEach([0.0, 12.0, 38.0, 50.0, 64.0, 88.0, 100.0], id: \.self) { value in
      EvalBarView(score: value)
        .frame(height: 260)
    }
    EvalBarView(score: 100, mate: 3)
      .frame(height: 260)
    EvalBarView(score: 0, mate: -2)
      .frame(height: 260)
  }
  .padding()
}

#Preview("Eval bar · horizontal, black to bottom") {
  VStack(spacing: 16) {
    EvalBarView(score: 72, axis: .horizontal)
    EvalBarView(score: 72, orientation: .black, axis: .horizontal)
    EvalBarView(score: 50, axis: .horizontal, thickness: 8, showsLabel: false)
  }
  .padding()
}
