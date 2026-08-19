# Licensing — the decision this app has to make before it ships

Everything here is inert while ChessCoach is a personal build installed from
Xcode onto one phone. It stops being inert the first time the app is handed to
anyone else, **and TestFlight counts as distribution.**

## The short version

| Component | Licence | Obligation once distributed |
|---|---|---|
| Stockfish 17.1 | **GPL v3** | The *entire app* must be GPL v3-compatible, with complete corresponding source offered to every recipient |
| ChessKit 0.17.0 | MIT | Preserve the copyright + permission notice |
| Lichess puzzle DB | CC0 | None (public domain dedication) |
| Staunty / Cburnett pieces | GPL v2+ / CC BY-SA 3.0 | Attribution; share-alike on the art |

The notices are shipped in-app at **Settings › Acknowledgements**
(`App/Features/Settings/AcknowledgementsScreen.swift`), which satisfies every
row above *except* the Stockfish one. GPL v3 is not a notice requirement. It is
a licensing requirement on the whole work.

## Why Stockfish is the whole decision

Stockfish is compiled **into the app process** — not shelled out to as a
separate binary, not talked to over a socket. `Packages/EngineKit` links 28 C++
sources directly and drives them through an in-process ObjC++ bridge. There is
no arm's-length arrangement here that a "mere aggregation" argument could rest
on: the FSF's position, and the Stockfish team's own repeatedly stated one, is
that this makes the combined program a derivative work.

So distributing ChessCoach as-is means distributing a GPL v3 program.

## Path A — ship GPL v3

Licence ChessCoach itself under GPL v3 and publish its source.

- **Cost:** the app's source becomes public, including the curriculum design,
  the humanizer's rating ladder, and the rules that turn a detector's findings
  into coaching copy — arguably the most original work in the repo.
- **Benefit:** zero engineering work. The engine stays the strongest available,
  the NNUE calibration work stays valid, and nothing in `AnalysisKit` (whose
  thresholds are tuned against Stockfish evals) has to be re-validated.
- **App Store:** GPL v3 and the standard App Store terms are widely treated as
  incompatible (the anti-tivoisation and "no additional restrictions" clauses
  versus Apple's DRM and device limits). GPL apps have been pulled before.
  Practically: Path A means TestFlight for yourself and people you send builds
  to, not a public App Store listing.

## Path B — swap the engine

`EngineKit`'s UCI layer was deliberately kept engine-agnostic for exactly this
(`VENDORED.md` says so). The named candidate is **Caissa** (MIT).

- **Cost:** real, and larger than it looks. Every number in `AnalysisKit` was
  tuned against Stockfish evaluations — the 0.10/0.20/0.30 expected-points
  judgment thresholds, the 150cp missed-tactic floor, the ±200cp result-class
  boundary. A different engine's eval scale means re-validating all of it, plus
  redoing the device node-budget calibration and the NNUE SIMD verification
  (`Scripts/engine-smoke.sh` counts NEON dotprod instructions in Stockfish's
  `network.o` specifically). The humanizer's depth-cap anchors would need
  re-measuring too.
- **Benefit:** the app can be closed-source and App Store-eligible.

## Path C — stay personal (current state)

No obligation is triggered. This is where the project is today and it is a
legitimate place to stay: the app exists to get one person to 2000, and that
goal needs zero distribution.

## The decision: Path A

**ChessCoach ships under GPL v3, with its source published.** Decided
2026-08-19; `LICENSE` is the GPL v3 text and `README.md` states the obligation
at the top.

The reasoning, briefly, so it is not relitigated:

- Path B's cost is the one that grows silently, and it is not the engine swap —
  it is re-validating every number in `AnalysisKit` that was tuned against
  Stockfish evaluations. That is a re-measurement project, not a dependency
  change.
- Path C means no TestFlight, and getting the app onto a phone that is not
  plugged into this Mac was the point.
- Path A costs no engineering at all. The engine stays the strongest available,
  every calibrated threshold stays valid, and the obligation — publish the
  source — is satisfied by a repository that should exist anyway.

What is actually given up is the curriculum design, the humanizer's ladder, and
the rules that turn a detector's findings into coaching copy. That is the most
original work here. It is also work whose value is in having built it, not in
its secrecy: nobody reaching 2000 does it by reading someone else's rung table.

### What this obliges, concretely

1. **Every recipient gets the source.** TestFlight testers included. The
   repository is <https://github.com/LufeMC/chess-coach>, linked in-app from
   Settings › Acknowledgements, and it must contain the *corresponding* source —
   the code the shipped build was actually made from, not a snapshot from some
   other week. Tagging each TestFlight build is the cheap way to keep that true.
2. **Build inputs must be obtainable.** The two large assets are not in git, so
   `README.md` documents how to reproduce both: the NNUE nets are
   content-addressed and checksum-verified by `Scripts/fetch-nnue.sh`, and the
   puzzle database is regenerated deterministically by `Tools/PuzzlePrep` from
   the public Lichess dump. "Corresponding source" that cannot be built is not
   corresponding source.
3. **Derivative work stays GPL v3.** Anyone forking this inherits the same terms.
4. **The App Store is still off the table.** GPL v3's anti-tivoisation and "no
   additional restrictions" clauses are widely treated as incompatible with the
   App Store's terms, and apps have been pulled over it. TestFlight for a known
   set of testers is the shipping target; a public listing would need Path B.

### The risk being accepted

Apple could pull a GPL v3 build from TestFlight if someone complained. For a
personal training app with a handful of testers that is a low-probability,
low-cost outcome — the fallback is installing from Xcode, which is where the
project already was.

## What is already done

- In-app notices for every component (Settings › Acknowledgements).
- `NSHumanReadableCopyright` names Stockfish and ChessKit and points at that
  screen.
- `VENDORED.md` files in both vendored trees pin upstream version and commit and
  state the licence.
- No CloudKit/push entitlement is claimed for a feature that is switched off, so
  the entitlement set describes what the app actually does.
