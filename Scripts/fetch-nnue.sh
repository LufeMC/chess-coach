#!/usr/bin/env bash
# Downloads the NNUE networks Stockfish 17.1 expects.
#
# The nets are not in git: the big net is ~71MB and both are content-addressed
# by the Stockfish project, so re-downloading is reproducible and cheap.
# Net names must match EvalFileDefaultNameBig/Small in Stockfish's evaluate.h.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/App/Resources/Networks"
BASE_URL="https://tests.stockfishchess.org/api/nn"

SMALL_NET="nn-37f18f62d772.nnue"
BIG_NET="nn-1c0000000000.nnue"

mkdir -p "$DEST"

fetch() {
  local name="$1"
  local path="$DEST/$name"

  if [[ -f "$path" ]]; then
    # Stockfish names each net after the leading bytes of its SHA-256, so the
    # filename is the checksum — verify rather than trust an existing file.
    local expected="${name#nn-}"
    expected="${expected%.nnue}"
    local actual
    actual="$(shasum -a 256 "$path" | cut -c1-${#expected})"
    if [[ "$actual" == "$expected" ]]; then
      echo "✓ $name (cached, verified)"
      return
    fi
    echo "✗ $name checksum mismatch — refetching"
    rm -f "$path"
  fi

  echo "↓ $name"
  curl -fL --progress-bar -o "$path" "$BASE_URL/$name"

  local expected="${name#nn-}"
  expected="${expected%.nnue}"
  local actual
  actual="$(shasum -a 256 "$path" | cut -c1-${#expected})"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $name failed checksum (got $actual, want $expected)" >&2
    rm -f "$path"
    exit 1
  fi
  echo "✓ $name"
}

fetch "$SMALL_NET"
fetch "$BIG_NET"

echo
echo "Networks ready in $DEST"
ls -lh "$DEST"
