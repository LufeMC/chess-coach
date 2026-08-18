// swift-tools-version: 6.0

import PackageDescription

// BoardUI is the visible surface of the app: the board itself plus the review
// chrome that sits next to it. It depends only on ChessKit — no engine, no
// database — so previews render standalone and the board can be dropped into
// any screen without dragging a stack of services behind it.
let package = Package(
  name: "BoardUI",
  platforms: [
    .iOS(.v18),
    .macOS(.v15)
  ],
  products: [
    .library(name: "BoardUI", targets: ["BoardUI"])
  ],
  dependencies: [
    .package(path: "../ChessKit")
  ],
  targets: [
    .target(
      name: "BoardUI",
      dependencies: ["ChessKit"],
      resources: [.process("Resources/Pieces.xcassets")],
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "BoardUITests",
      dependencies: ["BoardUI"],
      swiftSettings: [.swiftLanguageMode(.v6)]
    )
  ]
)
