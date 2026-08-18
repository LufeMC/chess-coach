# Vendored Stockfish

Source: https://github.com/official-stockfish/Stockfish
Version: sf_17.1
Commit:  03e27488f3d21d8ff4dbf3065603afa21dbd0ef3

Vendored (not a submodule) so the exact tree is pinned in this repo and builds
are reproducible without network access.

## Licensing

Stockfish is **GPL v3**. This app is a personal build installed via Xcode and is
not distributed, so the GPL's distribution obligations are not triggered. If it
is ever distributed, either the whole app must be GPL-compatible or the engine
must be swapped for a permissively-licensed one — the UCI layer in EngineKit is
deliberately engine-agnostic so Caissa (MIT, ~3750 CCRL) can drop in.

## Local modifications

None. `main.cpp` is excluded from the build (see Package.swift) and the UCI loop
is driven by SFBridge instead. Everything else is upstream, unmodified.
