# ChessCoach

An iPhone chess trainer built around one loop: **play a game, study the moments
you got wrong, drill the pattern.** It plays you against a depth-capped opponent
sized to your rating, analyses the game locally with Stockfish, and turns your
own mistakes into spaced-repetition cards.

Everything runs on the device. There is no account, no server, and no network
call at runtime — the analysis, the coaching text, and the ratings are all
computed locally.

## Licence

**GPL v3.** See [LICENSE](LICENSE). Source: <https://github.com/LufeMC/chess-coach>

This is not a preference, it is an obligation, and it is worth understanding
before you fork: ChessCoach links Stockfish **into its own process**, so the
combined program is a derivative work of a GPL v3 program. Distributing the app
in any form — including TestFlight — means distributing GPL v3 software, and the
complete corresponding source has to be available to everyone who receives it.
That is what this repository is for.

The consequence for anyone building on it: your version is GPL v3 too.

| Component | Licence |
|---|---|
| ChessCoach | GPL v3 |
| Stockfish 17.1 | GPL v3 |
| ChessKit 0.17.0 (vendored) | MIT |
| Lichess puzzle database | CC0 |
| Staunty / Cburnett piece art | GPL v2+ / CC BY-SA 3.0 |

In-app notices live at **Settings › Acknowledgements**.

## Building it

Requires Xcode 26 or later and an iPhone (or simulator) on iOS 18+.

Two build inputs are **not** in git, because one is 71MB and the other is
derived from a 900MB dump. Both are reproducible; neither is a blob you have to
take on trust — but **both are required**, and steps 1 and 2 have to happen
before the first build.

### 1. The neural networks

```bash
./Scripts/fetch-nnue.sh
```

Downloads the two NNUE files Stockfish 17.1 expects. Stockfish names each net
after the leading bytes of its own SHA-256, so **the filename is the checksum** —
the script verifies rather than trusts, and re-verifies files it finds cached.

### 2. The puzzle database

Download the Lichess puzzle dump (CC0) to `Tools/PuzzlePrep/data/`:

```bash
curl -L -o Tools/PuzzlePrep/data/lichess_db_puzzle.csv.zst \
  https://database.lichess.org/lichess_db_puzzle.csv.zst
```

Then build the curated subset:

```bash
cd Tools/PuzzlePrep && swift run PuzzlePrep
```

No arguments needed: the input and output paths default relative to the tool's
own source location, so it behaves the same from anywhere in the checkout.
`--input`, `--output`, `--target`, `--min-popularity`, `--min-plays`,
`--max-rating-dev` and `--seed` override them.

The curation is deterministic — a fixed seed, no system RNG — so the same dump
in gives a byte-identical database out, and two people who run this get the same
120,000 puzzles.

### 3. Generate the project and build

`ChessCoach.xcodeproj` is generated; `project.yml` is the source of truth.

```bash
xcodegen generate
xcodebuild build -scheme ChessCoach -skipMacroValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`-skipMacroValidation` is required because the build uses Swift macros that
Xcode otherwise prompts to trust interactively.

**If you skip steps 1 or 2** the build fails at the resource-copy phase, and a
pre-build check tells you which script to run. (`optional: true` in
`project.yml` only keeps *project generation* from failing on a missing file; it
does not make the resource optional at build time.)

Separately, if a net goes missing at *runtime* — the app also looks in
Application Support, so a build can outlive its assets — the engine refuses to
boot with a `missingNetwork` error surfaced on screen. `EngineService.boot`
checks both nets exist before sending any UCI command, because Stockfish calls
`exit(EXIT_FAILURE)` from `Network::load` when a net is missing, and in-process
that takes the whole app down with no crash report.

## Tests

```bash
xcodebuild test -scheme ChessCoach -skipMacroValidation \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ChessCoachTests
```

1,263 tests across the app and six local packages. The app suite runs in about
three seconds; it is meant to be run constantly.

Two suites are opt-in because they are measurements rather than regression
tests, and cost minutes to hours:

- `HumanizerSelfPlay` — plays the opponent profiles against each other to check
  what their rating labels are actually worth. See
  [Docs/humanizer-calibration.md](Docs/humanizer-calibration.md).
- `EngineIntegrationTests` — the only test that boots Stockfish.

## Layout

```
App/              the iOS app: features, design system, services
Packages/
  AnalysisKit     move judgment, mistake detection, coaching text
  BoardUI         the board view, piece rendering, board feedback
  ChessKit        vendored chess rules (MIT) + local additions
  Database        GRDB/SQLiteData schema and repositories
  EngineKit       UCI layer and vendored Stockfish
  TrainingCore    FSRS scheduling, ratings, curriculum
Tools/PuzzlePrep  builds the curated puzzle database
Docs/             design and calibration notes
Scripts/          asset fetching, sound and icon generation
```

## Docs worth reading first

- [Docs/humanizer-calibration.md](Docs/humanizer-calibration.md) — what the
  opponent ratings are worth, how they were measured, and the two times the
  measurement was wrong. The most useful file in the repo if you touch the
  opponent.
- [Docs/craft-standards.md](Docs/craft-standards.md) — the design system's
  rules, and when breaking them is allowed.
- [Docs/licensing.md](Docs/licensing.md) — the full licensing reasoning.
