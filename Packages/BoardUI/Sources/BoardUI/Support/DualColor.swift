//
//  DualColor.swift
//  BoardUI
//

import SwiftUI

/// A colour with an explicit light-appearance and dark-appearance value.
///
/// The package ships no asset catalog, so there is no `Color("name")` to carry
/// appearance variants. Rolling our own pair keeps every value `Sendable` and
/// lets the same struct be resolved inside a `Canvas` (where `ShapeStyle`
/// resolution is opaque) as easily as in a normal view.
///
/// The design brief is dark-first: the `dark` value is the one that was tuned,
/// and `light` is derived to hold the same relationships.
public struct DualColor: Hashable, Sendable {

  /// The colour used in the light appearance.
  public var light: Color
  /// The colour used in the dark appearance.
  public var dark: Color

  public init(light: Color, dark: Color) {
    self.light = light
    self.dark = dark
  }

  /// Creates a pair from 24-bit RGB hex literals, e.g. `0x4A4E55`.
  public init(light: UInt32, dark: UInt32) {
    self.light = Color(hex: light)
    self.dark = Color(hex: dark)
  }

  /// A pair that uses the same colour in both appearances.
  public init(_ color: Color) {
    self.light = color
    self.dark = color
  }

  /// Resolves the pair for a colour scheme.
  public func color(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? dark : light
  }

  /// Returns the same pair with both members multiplied by `amount`.
  public func opacity(_ amount: Double) -> DualColor {
    DualColor(light: light.opacity(amount), dark: dark.opacity(amount))
  }
}

extension Color {
  /// Builds an sRGB colour from a 24-bit hex literal.
  ///
  /// Internal because the board's palette is expressed as ``DualColor`` pairs;
  /// callers who want a one-off colour should use SwiftUI's own initialisers.
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}
