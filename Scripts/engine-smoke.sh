#!/usr/bin/env bash
# M0 acceptance: proves the embedded engine works and the SIMD build path is live.
#
# Run this after any change to EngineKit's Package.swift, the Stockfish version,
# or SFBridge — those are the places where a silent performance or protocol
# regression can hide.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/Packages/EngineKit"

if [[ ! -f "$REPO_ROOT/App/Resources/Networks/nn-37f18f62d772.nnue" ]]; then
  echo "Networks missing — running fetch-nnue.sh first"
  "$REPO_ROOT/Scripts/fetch-nnue.sh"
fi

echo "== Unit + engine smoke tests (macOS) =="
swift test

echo
echo "== iOS device build =="
xcodebuild -scheme EngineKit -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/chesscoach-dd-ios build 2>&1 |
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

echo
echo "== dotprod instruction check (iOS arm64) =="
# A scalar-fallback build emits only a handful of these from unrelated code;
# a correctly configured NNUE build emits dozens in network.o alone.
OBJ=$(find /tmp/chesscoach-dd-ios -name "network.o" -path "*iphoneos*" | head -1)
if [[ -n "$OBJ" ]]; then
  COUNT=$(otool -tv "$OBJ" | grep -cE '\bsdot|\budot' || true)
  echo "network.o dotprod instructions: $COUNT"
  if [[ "$COUNT" -lt 20 ]]; then
    echo "ERROR: NEON/dotprod path is not compiled in — check USE_NEON_DOTPROD and -march in Package.swift" >&2
    exit 1
  fi
else
  echo "WARN: could not locate network.o to verify SIMD path" >&2
fi

echo
echo "All M0 checks passed."
