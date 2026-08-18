//
//  EvalGraphView.swift
//  BoardUI
//

import Charts
import ChessKit
import SwiftUI

/// One point on the evaluation curve.
public struct EvalPoint: Identifiable, Hashable, Sendable {

  /// Half-move number, 0 being the starting position.
  public var ply: Int
  /// Win percentage for White, 0…100.
  public var winPercent: Double

  public var id: Int { ply }

  public init(ply: Int, winPercent: Double) {
    self.ply = ply
    self.winPercent = winPercent
  }

  /// Distance from equality, −50…+50. The chart plots this so the area has a
  /// real zero baseline instead of a baseline at 50.
  var advantage: Double { min(100, max(0, winPercent)) - 50 }
}

/// The game's evaluation over time, with the review moments called out.
///
/// The Y axis is labelled **Winning / Equal / Losing**, not `+2.5`. Nobody
/// reading their own game needs three decimal places of centipawn; they need to
/// know when it went wrong, and words say that faster than numbers.
public struct EvalGraphView: View {

  private let points: [EvalPoint]
  private let moments: [Int]
  private let classifications: [Int: MoveClassification]
  private let orientation: Piece.Color
  private let style: BoardStyle
  @Binding private var selection: Int?

  @Environment(\.colorScheme) private var colorScheme

  public init(
    points: [EvalPoint],
    moments: [Int],
    selection: Binding<Int?>,
    classifications: [Int: MoveClassification] = [:],
    orientation: Piece.Color = .white,
    style: BoardStyle = .default
  ) {
    self.points = points
    self.moments = moments
    self._selection = selection
    self.classifications = classifications
    self.orientation = orientation
    self.style = style
  }

  public var body: some View {
    Chart {
      // The band the brief calls the "normal range": inside it, nothing
      // interesting happened, which is most of most games.
      RectangleMark(
        xStart: .value("Start", domain.lowerBound),
        xEnd: .value("End", domain.upperBound),
        yStart: .value("Low", -12),
        yEnd: .value("High", 12)
      )
      .foregroundStyle(accent.opacity(0.07))

      ForEach(points) { point in
        AreaMark(
          x: .value("Ply", point.ply),
          y: .value("Advantage", signed(point.advantage))
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(
          .linearGradient(
            colors: [accent.opacity(0.35), accent.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      }

      ForEach(points) { point in
        LineMark(
          x: .value("Ply", point.ply),
          y: .value("Advantage", signed(point.advantage))
        )
        .interpolationMethod(.monotone)
        .lineStyle(StrokeStyle(lineWidth: 1.8))
        .foregroundStyle(accent)
      }

      RuleMark(y: .value("Equal", 0))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .foregroundStyle(.secondary.opacity(0.5))

      ForEach(momentPoints, id: \.ply) { point in
        PointMark(
          x: .value("Ply", point.ply),
          y: .value("Advantage", signed(point.advantage))
        )
        .symbolSize(60)
        .foregroundStyle(
          (classifications[point.ply] ?? .mistake).color(in: style).color(colorScheme)
        )
      }

      if let selection, let point = points.first(where: { $0.ply == selection }) {
        RuleMark(x: .value("Ply", selection))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .foregroundStyle(.secondary.opacity(0.6))
          .annotation(position: .top, overflowResolution: .init(x: .fit, y: .fit)) {
            tooltip(for: point)
          }
      }
    }
    .chartYScale(domain: -50...50)
    .chartXScale(domain: domain)
    .chartYAxis {
      // Three words instead of a numeric scale — see the type doc.
      AxisMarks(position: .leading, values: [-50, 0, 50]) { value in
        AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
        AxisValueLabel {
          Text(axisLabel(for: value.as(Double.self) ?? 0))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
        AxisValueLabel {
          if let ply = value.as(Int.self) {
            Text(verbatim: "\(ply / 2 + 1)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in scrub(to: value.location, proxy: proxy, geometry: geometry) }
              .onEnded { value in scrub(to: value.location, proxy: proxy, geometry: geometry) }
          )
      }
    }
    .animation(.smooth(duration: 0.25), value: selection)
  }

  // MARK: - Helpers

  /// Flips the curve when the board is seen from Black's side, so "up" always
  /// means "you are winning" regardless of which colour the reader played.
  private func signed(_ advantage: Double) -> Double {
    orientation == .white ? advantage : -advantage
  }

  private var domain: ClosedRange<Int> {
    let low = points.map(\.ply).min() ?? 0
    let high = points.map(\.ply).max() ?? 1
    return low...max(low + 1, high)
  }

  private var momentPoints: [EvalPoint] {
    let set = Set(moments)
    return points.filter { set.contains($0.ply) }
  }

  private var accent: Color { style.accent.color(colorScheme) }

  private func axisLabel(for value: Double) -> String {
    switch value {
    case 40...: "Winning"
    case ...(-40): "Losing"
    default: "Equal"
    }
  }

  @ViewBuilder
  private func tooltip(for point: EvalPoint) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: "Move \(point.ply / 2 + 1)")
        .font(.caption2.monospacedDigit())
      if let classification = classifications[point.ply] {
        ClassificationBadge(kind: classification, size: .compact, style: style)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.regularMaterial, in: Capsule())
  }

  private func scrub(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
    guard let plotFrame = proxy.plotFrame else { return }
    let origin = geometry[plotFrame].origin
    let x = location.x - origin.x
    guard let rawPly: Int = proxy.value(atX: x) else { return }
    // Snap to the nearest sampled ply: the curve is defined only at half-moves,
    // and a selection between two of them cannot scrub the board.
    selection = points.min(by: { abs($0.ply - rawPly) < abs($1.ply - rawPly) })?.ply
  }
}

// MARK: - Previews

private func samplePoints() -> [EvalPoint] {
  let shape: [Double] = [
    50, 52, 51, 54, 53, 55, 58, 56, 60, 59, 62, 61, 64, 63, 66, 40, 42, 41,
    44, 43, 46, 45, 30, 32, 31, 34, 33, 36, 12, 14, 13, 16, 15, 18, 17, 8
  ]
  return shape.enumerated().map { EvalPoint(ply: $0.offset, winPercent: $0.element) }
}

#Preview("Eval graph") {
  @Previewable @State var selection: Int? = 28

  VStack(alignment: .leading, spacing: 8) {
    Text("Evaluation")
      .font(.title3.bold())
    EvalGraphView(
      points: samplePoints(),
      moments: [15, 22, 28],
      selection: $selection,
      classifications: [15: .mistake, 22: .inaccuracy, 28: .blunder]
    )
    .frame(height: 190)
    Text(verbatim: "selected ply: \(selection.map(String.init) ?? "none")")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
  }
  .padding()
}

#Preview("Eval graph · from Black's side") {
  @Previewable @State var selection: Int?

  EvalGraphView(
    points: samplePoints(),
    moments: [15, 28],
    selection: $selection,
    classifications: [15: .mistake, 28: .blunder],
    orientation: .black,
    style: .ink
  )
  .frame(height: 190)
  .padding()
}
