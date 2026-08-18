# Design conventions

Derived from a Mobbin survey of shipped apps. Mobbin indexes no chess.com /
lichess / Chessable; the only chess reference is Duolingo's chess course, which
is indexed well. Everything else comes from adjacent domains (fitness,
finance, learning, AI assistants).

## Cross-cutting

**Classification colour.** Four levels, but colour carries only two. Blunder and
mistake get colour (red / orange); inaccuracy gets neutral grey-brown; "great"
gets the accent. Everything else is `.secondary`. Precedent: Yuka's additives
list (word + 6pt dot, no bars), Redfin's climate risk (severity is part of the
label text, icon monochrome).

**Only classified moves get a chip.** A game where 4 of 60 moves carry a chip
reads as diagnosis; one where all 60 carry colour reads as a heat map, which is
noise.

**Numbers.** Monospaced digits everywhere. Value in primary weight, delta
adjacent in a smaller weight and in the semantic colour — never both coloured,
or the row loses its anchor.

**Prose in cards, data in rows.** Apple Weather does this: chart in the open,
then the summary paragraph inside a filled rounded rect. That separation is the
rule for coach text vs engine numbers.

## Streaming AI text without layout jump

1. **Reserve space first.** Wabi renders the finished card's skeleton while
   generating — avatar placeholder, title bar, three rows of grey capsules at
   the width the real rows will occupy. The container never resizes.
2. **Fixed collapsed height, opt-in depth.** Strava's Athlete Intelligence:
   bordered card, small glyph + label, exactly three lines of prose, then a
   `Say More` pill. Bounded height makes layout jump structurally impossible.
3. **Name the work in the placeholder.** Not a bouncing dot — `Analyzing move
   23…` in the exact leading position the real content will occupy.

## Patterns to avoid

1. Winding-path level maps (Duolingo, Life Reset, Ahead) — huge vertical cost,
   no information a numbered accordion lacks, unmistakably a game.
2. Blanket severity chips where every row has one (Cleo AI's four identical red
   `Hurting` chips) — a badge on 100% of rows conveys tone, not data.
3. Saturated full-width bars for diagnostic breakdowns (Ultrahuman) — reads as
   alarm; ordering plus a number does the same job.
4. Consolation copy on failure (Revolut's "Don't worry, you got this!") —
   reassurance implies the result warranted distress. State the fact, name the
   concept: `Missed — the pin was on the f-file.`
5. Celebration screens with confetti and stars. Take Uxcel Go's result *rows*;
   leave the stars.
6. A mascot delivering analysis. Fine for a 12-move teaching puzzle, intolerable
   across 60 moves of real analysis.
7. Donut/ring charts for accuracy — decoration around a number that reads faster
   alone.
8. One undifferentiated progress bar across a long multi-phase flow.
9. Chart-junk zone legends. If a leak needs a paragraph, it goes behind the
   row's chevron.
