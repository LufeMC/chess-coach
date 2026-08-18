// swift-tools-version: 6.0

import PackageDescription

// Vendored fork of chesskit-app/chesskit-swift 0.17.0 (MIT).
// See VENDORED.md for the rationale and the list of local changes.
let package = Package(
  name: "ChessKit",
  platforms: [
    .iOS(.v18),
    .macOS(.v15)
  ],
  products: [
    .library(name: "ChessKit", targets: ["ChessKit"])
  ],
  targets: [
    .target(name: "ChessKit"),
    .testTarget(name: "ChessKitTests", dependencies: ["ChessKit"])
  ]
)
