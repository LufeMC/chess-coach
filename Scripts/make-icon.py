#!/usr/bin/env python3
"""Draw the app icon.

Run from anywhere:

    python3 Scripts/make-icon.py

Checked in for the same reason as `make-sounds.py`: the PNG in the asset
catalogue is the only copy of this artwork, and a binary asset whose recipe was
lost is an asset nobody can adjust. Every number that shapes the mark is below.

## The mark

Three by three squares of a board, with one square lit in the app's accent.
That is the whole idea of the app in one shape — a position, and the one square
in it that is worth talking about. It also survives being 40 points wide, which
a chess piece silhouette does not: a knight at that size is a grey smudge, and
every chess app on the store is already a knight.

## Why it is drawn rather than eyeballed

The first version of this icon put a 3x3 grid across 60% of the canvas, which
looked balanced at 1024 and read as a small fuzzy smudge floating in a dark
field on a home screen. iOS then rounds the corners and shrinks it to 60pt, so
the numbers that matter are the ones below, not how the artwork looks at full
size in a preview pane:

- **`MARGIN`** — the mark fills 78% of the canvas. Enough that it reads as a
  shape rather than a speck, inside the ~10% that corner rounding can eat.
- **No gradient inside the squares.** The original had a faint gradient across
  each square. At icon size that reads as a compression artefact, not as depth.
- **The accent square is off-centre.** Dead centre reads as a target or a
  record button. Right-of-centre reads as a position with something happening
  in it.
"""

from pathlib import Path

from PIL import Image, ImageDraw

# Canvas ---------------------------------------------------------------------

SIZE = 1024
MARGIN = 0.11          # fraction of the canvas left clear on each side

# Colour ---------------------------------------------------------------------
#
# Taken from App/DesignSystem/Palette.swift. The ground is the dark surface the
# app uses behind cards; the accent is `Palette.accent`'s dark variant, which is
# the one that has to hold up against a dark ground.

GROUND = (0x14, 0x16, 0x1A)
LIGHT_SQUARE = (0x5A, 0x60, 0x6B)
DARK_SQUARE = (0x3C, 0x41, 0x4A)
ACCENT = (0x63, 0xB5, 0xCE)

# Which cell is lit, as (column, row) from the top left.
ACCENT_CELL = (2, 1)

CELLS = 3


def draw() -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE), GROUND)
    canvas = ImageDraw.Draw(image)

    origin = SIZE * MARGIN
    span = SIZE * (1 - 2 * MARGIN)
    cell = span / CELLS

    for row in range(CELLS):
        for column in range(CELLS):
            if (column, row) == ACCENT_CELL:
                fill = ACCENT
            else:
                # Standard board parity, so the fragment reads as cut from a
                # real board rather than as an arbitrary grid.
                fill = LIGHT_SQUARE if (row + column) % 2 == 0 else DARK_SQUARE

            left = origin + column * cell
            top = origin + row * cell
            # `round` on the far edge rather than adding `cell`, so adjacent
            # squares share an exact boundary and no seam of ground colour
            # shows through between them.
            canvas.rectangle(
                [
                    round(left),
                    round(top),
                    round(origin + (column + 1) * cell) - 1,
                    round(origin + (row + 1) * cell) - 1,
                ],
                fill=fill,
            )

    return image


def main() -> None:
    destination = (
        Path(__file__).resolve().parent.parent
        / "App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    )
    image = draw()
    # No alpha: iOS rejects an icon with a transparent channel.
    image.convert("RGB").save(destination, "PNG", optimize=True)
    print(f"wrote {destination} ({destination.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
