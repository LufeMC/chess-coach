#!/usr/bin/env python3
"""Pool `HumanizerSelfPlay` runs into one measurement with an interval.

    python3 Scripts/self-play-pool.py /tmp/sp-*.csv

Each row a run appends is:

    strongerRating,weakerRating,strongerScore,games,decisive,measuredGap,aborted

## Why this is not just "add up the games"

The harness reports a point estimate and nothing else, and a point estimate from
30 games is a number people over-trust. Worse, the top of the ladder draws most
of its games — two strong profiles agreed 13 times out of 20 in the first run —
so the score there is built from a handful of decisive results and its interval
is far wider than the sample size suggests at a glance.

So the same pairing gets split across several processes with different seed
offsets, and this pools them. The spread *between* runs is the honest estimate
of the noise: each run is an independent sample of the same quantity, so their
standard error needs no assumption about how draws are distributed. With only a
few runs that is a small sample of variances, hence the t-multiplier below
rather than 1.96.

The Elo conversion is applied to the score bounds, not to the score — the
transform is non-linear, so a symmetric interval in score is an asymmetric one
in Elo, and reporting `gap ± something` would misstate which direction is
better constrained.
"""

from __future__ import annotations

import math
import sys
from collections import defaultdict
from pathlib import Path

# Two-sided 95% t-multipliers, indexed by degrees of freedom (n - 1).
# Only small n matters here; anything larger falls back to the normal value.
T_95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
        8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179}


def elo(score: float) -> float:
    """Standard Elo inversion, clamped away from a clean sweep (unbounded)."""
    score = min(max(score, 0.001), 0.999)
    return -400 * math.log10(1 / score - 1)


def main(paths: list[str]) -> None:
    runs: dict[tuple[int, int], list[tuple[float, int, int, int]]] = defaultdict(list)

    for path in paths:
        text = Path(path).read_text().strip()
        if not text:
            continue
        for line in text.splitlines():
            parts = line.split(",")
            if len(parts) < 5:
                continue
            stronger, weaker = int(parts[0]), int(parts[1])
            score, games, decisive = float(parts[2]), int(parts[3]), int(parts[4])
            # Older rows have six columns; treat a missing abort count as zero
            # rather than skipping the row.
            aborted = int(parts[6]) if len(parts) > 6 else 0
            runs[(stronger, weaker)].append((score, games, decisive, aborted))

    if not runs:
        print("no results found")
        return

    print(f"{'pairing':>14}  {'claimed':>8}  {'measured':>9}  {'95% interval':>18}  "
          f"{'score':>7}  {'games':>6}  {'draws':>6}  {'abort':>6}  {'runs':>5}")
    print("-" * 104)

    for (stronger, weaker), samples in sorted(runs.items()):
        total_games = sum(g for _, g, _, _ in samples)
        total_points = sum(s * g for s, g, _, _ in samples)
        total_decisive = sum(d for _, _, d, _ in samples)
        total_aborted = sum(a for _, _, _, a in samples)
        pooled = total_points / total_games if total_games else 0.5

        claimed = stronger - weaker

        if len(samples) > 1:
            # Between-run spread. Each run is weighted equally, which is right
            # when the runs are the same length and close enough otherwise.
            scores = [s for s, _, _, _ in samples]
            mean = sum(scores) / len(scores)
            variance = sum((s - mean) ** 2 for s in scores) / (len(scores) - 1)
            standard_error = math.sqrt(variance / len(scores))
            multiplier = T_95.get(len(scores) - 1, 1.96)
            margin = multiplier * standard_error
            low, high = elo(pooled - margin), elo(pooled + margin)
            interval = f"{low:+.0f} … {high:+.0f}"
        else:
            # One run says nothing about its own noise. Fall back to the
            # binomial standard error on the score, which assumes draws behave
            # like half-points and understates the spread — flagged with a `~`
            # so nobody reads it as the real thing.
            standard_error = math.sqrt(max(pooled * (1 - pooled), 1e-6) / total_games)
            margin = 1.96 * standard_error
            interval = f"~{elo(pooled - margin):+.0f} … {elo(pooled + margin):+.0f}"

        draws = total_games - total_decisive
        # An abort is a game the harness could not finish. Anything above a
        # percent or two means the game loop is broken and the row is fiction,
        # so it is printed next to the number it would invalidate.
        flag = "  <-- ABORTS" if total_aborted > max(1, total_games // 20) else ""
        print(f"{stronger:>6} → {weaker:<5}  {claimed:>+8}  {elo(pooled):>+9.0f}  "
              f"{interval:>18}  {pooled * 100:>6.1f}%  {total_games:>6}  "
              f"{draws:>6}  {total_aborted:>6}  {len(samples):>5}{flag}")

    print()
    ladder = sorted(runs.keys(), key=lambda k: k[1])
    measured_total = 0.0
    claimed_total = 0
    for stronger, weaker in ladder:
        samples = runs[(stronger, weaker)]
        total_games = sum(g for _, g, _, _ in samples)
        if not total_games:
            continue
        pooled = sum(s * g for s, g, _, _ in samples) / total_games
        measured_total += elo(pooled)
        claimed_total += stronger - weaker
    if claimed_total:
        span = f"{ladder[0][1]} → {ladder[-1][0]}"
        share = measured_total / claimed_total * 100
        print(f"{span}: {measured_total:+.0f} Elo delivered against {claimed_total:+d} claimed "
              f"({share:.0f}%)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
