# Humanizer calibration — what the opponent ratings are worth

The opponent ladder labels five profiles 800 through 2200. Those labels are not
decoration: `OpponentLadder` picks the next opponent from the user's rating,
`EloLadder` updates the user's rating from the result, and the Profile screen
draws a year of progress from the number that comes out. Every rating-derived
signal in the app inherits whatever error is in these five labels.

They were originally chosen by reasoning about depth caps and error rates. This
document records what happened when they were measured instead.

## How the measurement works

`AppTests/HumanizerSelfPlay.swift` plays adjacent anchors against each other,
alternating colours, and inverts the score into an Elo gap:

```
gap = -400 · log10(1/score - 1)
```

Two profiles labelled 400 apart should score about 91% / 9%. If they score
60/40, the labels are lying and the ladder is compressed.

It is opt-in, because it is hundreds of real engine games rather than the ~3
seconds the rest of the suite takes:

```bash
CHESSCOACH_SELF_PLAY=1 TEST_RUNNER_CHESSCOACH_SELF_PLAY=1 TEST_RUNNER_CHESSCOACH_SELF_PLAY_GAMES=30 TEST_RUNNER_CHESSCOACH_SELF_PLAY_PAIRING=0 TEST_RUNNER_CHESSCOACH_SELF_PLAY_OUT=/tmp/sp-0.csv xcodebuild test -scheme ChessCoach -only-testing:ChessCoachTests/HumanizerSelfPlay -skipMacroValidation -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`CHESSCOACH_SELF_PLAY_PAIRING` selects one adjacent pair so the four can run as
separate processes on separate simulators. Run them that way: a serial run
spends nearly all its wall clock on the deepest pair and often never reaches it.
Boot the simulators **before** launching, and stagger the launches — four cold
simulators starting at once reliably fails with `Application failed preflight
checks`.

## The measurement was broken before any of the numbers below

Three rounds of numbers were published from this harness before anyone checked
whether its game loop could finish a game. It could not.

ChessKit's `Board.move(pieceAt:to:)` does **not** promote. A pawn reaching the
last rank sets `state = .promotion(move:)` and returns from `updateState`
*before* looking for checkmate or draw, leaving the pawn a pawn. The harness
never called `completePromotion`, so from the first promotion onward its board
diverged from the move list it was feeding the engine, the next move failed to
apply, and the game fell out of the loop — and was scored **half a point to
each side**.

The bias is not random. The side that promotes is almost always the side that is
winning, so every promotion turned one of the stronger profile's wins into a
draw. The measured gaps were therefore **too small**, and the "compression" the
first two rounds diagnosed was substantially an artefact of the harness rather
than a property of the ladder.

The only visible symptom was a draw rate nobody questioned: 13 draws in 20 games
at the top pairing, 6 in 30 at the bottom. After the fix, the same pairings play
**200 games with zero draws**.

The same bug was live in the app — see `GameSession.completePromotionIfNeeded`
and `AppTests/GameSessionTests.swift`'s promotion suite, which is where it was
actually caught.

Two guards now exist so this class of failure cannot hide again:

- The harness scores an unfinishable game as `aborted`, never as a draw, and
  reports the count in its CSV.
- The suite fails outright when aborts exceed 5% of a pairing.

## What each lever is actually worth

Measured against the fixed harness, and the reason the ladder's steps are not
uniform:

| Change | Measured |
|---|---|
| +2 plies of depth, temperature ×0.65 | **clean sweep** (>800) |
| +2 plies of depth, temperature ×0.68 | **clean sweep** (>800) |
| +3 plies of depth, temperature ×0.55 | **+632** |
| Temperature ×0.50 at **fixed** depth | **+512** |
| Temperature ×0.58 at **fixed** depth | **+408** |

Depth is a very steep axis at these settings — a two-ply step swept 20 games
outright, twice — so it is not the lever to reach for when a step is a few
hundred points out. Temperature is: it moves strength smoothly and without
collapsing into sweeps. MultiPV is neither; it is a *floor* on how badly a
profile can play, because the sampler can only choose among the lines the search
returned.

### The temperature rule, and its test

The two fixed-depth measurements fit

> **Elo ≈ 512 · log₂(1 / r)**, where `r` is the ratio of the two temperatures.

That was derived from the ×0.5 point, then used to *predict* the ×0.58 point
before measuring it: the rule said +400, the games said **+408** over 23 decisive
games. One confirmed prediction is not a law, but it is the difference between a
tuning dial and a guess — and it is the only relationship in this file that has
been tested rather than fitted.

To move one step by N Elo, multiply that anchor's temperature by `2^(-N/512)`.

### …and where the rule stops working

The obvious next move is to fit a depth term too, invert the whole system, and
solve for the temperatures that make every step land on its label. That was
tried. The fit looked convincing — three of the four steps put the depth
contribution at **61, 57 and 71 Elo per ply**, which is about as consistent as
this kind of measurement gets — and it produced a tidy ladder holding depth
fixed and letting temperature carry the remainder.

Measured, the solved ladder's bottom step was a **clean sweep**: worse than what
it replaced, and in the *opposite direction* to the prediction. Raising the 1200
anchor's temperature from 6.0 to 8.17 should have narrowed the 800 → 1200 gap
and instead it widened past measurability.

The lesson is about the shape of the model, not the arithmetic. The 512 figure
was measured at depth 8 with MultiPV 12, between temperatures 9 and 4.5. It
describes strength *in that neighbourhood*. Temperature, depth and MultiPV are
not separable terms that can be added up — MultiPV bounds how much damage a
given temperature can do at all, so the same ratio is worth different amounts at
different widths and horizons.

So: use the rule to nudge a step that is already close, in the regime it was
measured in. Do not use it to solve the ladder in one shot. And measure every
candidate — the tooling makes a round cheap, which is exactly why there is no
excuse for shipping a set that was only reasoned about.

## What the ladder measures now

Numbers below are from the fixed harness. Everything measured before it is
discarded rather than corrected: the bias depends on how many games reached a
promotion, which was never recorded.

| Pairing | Claimed | Measured | Games |
|---|---|---|---|
| 800 → 1200 | +400 | **+632** | 39 |
| 1200 → 1600 | +400 | **+470** | 40 |
| 1600 → 2000 | +400 | **+512** | 20 |
| 2000 → 2200 | +200 | **+372** | 19 |

Every step is over-spread: the ladder delivers about **1986 Elo across labels
claiming 1400**, or 1.4× too wide. The intervals at this sample size are also
very wide — the two seeds for each of the first two pairings disagreed enough
that a 95% interval spans several hundred points. Read the table as "the right
order of magnitude, still loose", not as a calibration.

What it is *not* any more is broken. Every step is measurable and decisive; none
of them sweeps. That is the difference between a ladder that is too wide by a
knowable amount and one whose top half returns no information at all, which is
where both previous versions were.

The 1600 → 2000 step measured as a **clean sweep** with the original depth-13 /
temperature-2.0 anchor — the one place the ladder was unambiguously broken.
Softening it to depth 12 / temperature 3.0 brought it to +512 with all 20 games
decisive, which is why the shipped 2000 and 2200 anchors differ from the
originals.

### One loose end: the abort rate

Some runs report 1–2 aborted games in 20. The harness now counts them and the
suite fails above 5%, so they are visible rather than silently scored as draws —
but nothing yet distinguishes the two causes: a move that would not apply, and
the 300-ply cap. In a lopsided pairing the stronger side wins quickly, so a
300-ply game is the less likely explanation, which makes the remaining aborts
worth a look before the next calibration round is trusted at the margin. Splitting
`aborted` into `abortedUnplayable` and `abortedPlyCap` is a five-line change.

### What is left to do here

Closing the remaining 20–60% is a bounded job, and the tooling for it now exists:

- `CHESSCOACH_SELF_PLAY_PROFILES` measures a candidate ladder without a rebuild,
  so a round is a measurement rather than a build-and-measure.
- `Scripts/self-play-pool.py` pools seeded runs into one number with a real
  between-run interval.
- Temperature is the lever to move, and the rule above says by how much; depth
  should stay where it is.

Applying the rule to the current table would mean multiplying temperature by
`2^(-232/512)` ≈ 0.73 at the 1200 anchor, `2^(-70/512)` ≈ 0.91 at 1600, and
`2^(-112/512)` ≈ 0.86 at 2000 — but each of those also moves the *next* step, so
it is an iteration, not a one-shot edit.

There is also a design question worth settling first, and it is not a technical
one. A ladder spaced purely by temperature is a ladder whose profiles differ
only in how often they pick a worse move — which is close to the "engine chess
with noise stirred in" that this whole type exists to avoid (see the comment at
the top of `Humanizer`). Depth is what makes a weak opponent miss things
*structurally*, and it is too steep to space a ladder with. Those two facts are
in tension, and the resolution — narrower rating span, non-linear labels, or
accepting sampling noise as the spacing mechanism — is a product decision.

The one structural caveat: this is a *chain* of adjacent measurements, so
narrowing one step widens its neighbour. Converging properly means placing all
five profiles against a single fixed reference rather than against each other.

### The harness searches slightly harder than the app does

`HumanizerSelfPlay` searches with a plain `.depth(profile.depth)`. The app uses
`.depthWithin(depth:milliseconds:)`, because in a real game the opponent is on a
clock and an unbounded search can flag it — see
`GameSession.opponentMoveBudgetMs`. The ceiling is a share of the opponent's
remaining time, capped at 8 seconds.

So the measured numbers describe the profile's strength with the horizon it
asked for, which is an **upper bound** on what it plays at in the app. The gap
should be nil in practice: the ceiling is set high enough that ordinary
positions finish on depth. The one place to watch is 2200, where depth 18 is
genuinely expensive — if that profile starts hitting the ceiling on a real
device, its shipped strength drifts below this table and the top of the ladder
needs re-measuring under the cap.

## What this measurement cannot tell you

Self-play measures the **spacing** between anchors and nothing else. A ladder can
be perfectly spaced and uniformly 300 points mislabelled, and these games would
look identical either way — every opponent is being compared only to its
neighbour.

That matters because the absolute number is the one the user reads. Anchoring it
needs an external reference, and the cheap honest one is a rated site: play
enough games on Lichess or Chess.com to get a stable rapid rating, and compare it
to the rating this app reports. A consistent offset means the anchors need
shifting as a block, which is a one-line change to the five `rating:` labels and
does not disturb the spacing this document measures.

Until that comparison is done, treat the app's rating as a **self-consistent
progress metric** — it moves the right way by the right amount — rather than as a
number that is comparable to a rating from anywhere else.

## If the anchoring says the scale is off, what actually moves

The rating scale is not only in the humanizer, so "shift the anchors" is not by
itself a correct fix. Everything below is denominated in the same units:

| Where | What | File |
|---|---|---|
| Humanizer anchors | the five `rating:` labels | `App/Services/Humanizer.swift` |
| Opponent ladder | the `800...2200` clamp | `App/Services/Humanizer.swift` |
| Calibration | `gameRatingRange = 700...1900` | `TrainingCore/DomainTuning.swift` |
| Curriculum | rung bands `0...999`, `1000...1399`, `1400...1799`, `1800...2000` | `TrainingCore/Curriculum/Curriculum.swift` |

The curriculum bands and the goal are the fixed reference, and the humanizer
labels are the knob. That ordering is the whole point: "get to 2000" means 2000
in the human sense that a rating on a real site would report, and the rungs were
written against that same human meaning — *Board Vision* is what a sub-1000
player is missing, not what a sub-1000 ChessCoach-scale player is missing. So a
finding that the app's scale runs, say, 250 points hot is corrected by moving the
five humanizer labels down 250, **not** by moving the rungs and the goal up.

The one thing that must move with the anchors is `gameRatingRange`, since it
clamps a calibration estimate derived from games against those same opponents.

## Two rules the profiles hold at every rating

Both are in `Humanizer.choose`, and both exist because the alternative corrupts
training rather than merely being unrealistic:

1. **A forced mate that is in the candidate list gets played.** The depth cap is
   what makes a weak opponent miss mates — at depth 3 a mate in 2 is at the edge
   of what the search returns at all. But a mate the search *did* return is one
   the model claims the opponent calculated, and there is no rating at which a
   player calculates a forced mate and then plays something else.
2. **A line the search scored as mate-against is dropped before sampling.** Same
   reasoning, mirrored. Leaving those in made the loosest profile walk into mate
   on ~3.6% of the moves where one was available.

Both matter for the user's training signal specifically: escaping a lost position
because the opponent flipped a coin teaches nothing that can be repeated.
