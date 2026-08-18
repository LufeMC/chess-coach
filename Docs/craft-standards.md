# Craft standards

Cross-cutting rules from a Mobbin survey of shipped apps. Per-screen guidance
lives with the screens; this is the shared vocabulary.

Coverage note: Mobbin indexes static frames, so the motion and haptic sections
are derived from iOS convention and from what the indexed flows structurally
imply — not from observed animation. Treat them as a spec to tune.

## Motion

Three springs, no more:

```
.snappy   — response 0.28, damping 0.86   // selection, toggles, button states
.standard — response 0.42, damping 0.82   // sheets, transitions, card entry
.gentle   — response 0.60, damping 0.90   // large-surface moves, board reflow
```

Non-spring durations: 0.15s opacity-only crossfades, 0.25s colour/border, 0.35s
content replacement.

| Animate | Don't |
|---|---|
| Position and opacity of entering content | Text content itself (crossfade, never type-on) |
| Sheet presentation and detent changes | Anything on a per-frame timer (clocks tick, don't animate) |
| Selection state | Layout of persistent chrome |
| Value changes that carry meaning | Decorative background loops |
| Piece movement, capture, check | The board grid itself, ever |

List entry staggers 40ms per row capped at 6 rows; skip the stagger entirely on
re-entry to a screen already seen. `matchedGeometryEffect` is reserved for two
journeys — board → review board, and a mistake row → its detail position.

**The rule that matters most:** motion should communicate where something came
from or what changed. A card that fades in from nowhere teaches nothing.

## Typography

A well-built screen uses 4–6 type styles, not 12.

| Role | Spec | Use |
|---|---|---|
| Display | 44–56pt rounded bold, tracking −0.5 | Clock under pressure, hero stat |
| Title | 28pt bold | Screen titles, result headlines |
| Headline | 17pt semibold | Card titles, checklist steps |
| Body | 17pt regular | Sheet copy, explanations |
| Caption | 13pt regular `.secondary` | Metadata, units |
| Label | 11–12pt semibold **uppercase, +0.6 tracking** `.secondary` | Section headers, stat labels |

Three techniques worth adopting:
1. **The denominator drops a tier** — "72" large, "/100" smaller and grey. Apply
   to `1 of 3`, `3 moments`, streak counts.
2. **Uppercase + tracking on small labels** is the single highest-leverage
   typographic change available.
3. **Section headers carry a right-aligned qualifier** in the same small-caps
   style, dimmer — `TODAY` / `1 OF 3`.

`.monospacedDigit()` is mandatory on clocks and the eval capsule, or the layout
jitters every second. Consider `.rounded` for numerals only.

## Colour

**One accent, rationed to one use per screen** — the primary action and the
current selection. Never decoration, never section headers, never
non-interactive icons. One filled accent button per screen, maximum.

Semantic colours mean one thing each, app-wide. Red = advantage lost. If red
also means "time low" and "destructive" and "error", it means nothing. Route
time pressure through weight plus amber; route destructive actions through a
tinted row inside a sheet.

**Never encode with colour alone** — pair every eval colour with an arrow glyph.

Semantic backgrounds at ~10% alpha, semantic foregrounds at full strength.

**Dark mode is a design, not an inversion.** Cards are *lighter* than the ground
(elevation by lightness, since shadows are invisible on black). Accents
desaturate and brighten. Hairlines become `white.opacity(0.08–0.12)`. Define
tokens with independent light/dark values; never compute dark from light.

## Depth

| Level | Treatment | Use |
|---|---|---|
| 0 Ground | Flat semantic background | Page, the board |
| 1 Raised | Solid fill, 1pt hairline 8–12% alpha, **no shadow** | Cards, rows, tiles |
| 2 Floating | `.regularMaterial` / `.thinMaterial`, no border | Sheets, capsule toolbars |

Material only where content passes behind it. **Hairlines instead of shadows** —
shadows on cards is the most reliable tell of a mid-tier app. Shadows are
reserved for things genuinely lifted by a finger (a dragged piece).

Corner radii, three values: 10pt chips/capsules, 16pt cards, 22pt+ sheets.

## Loading

Grey rounded rectangles matching the final layout's **exact** geometry. No
spinners except inside a button. Zero layout shift is the whole point — a
skeleton whose geometry doesn't match is a worse spinner. Under ~200ms show
nothing. Progressive reveal for staged data: render what's local immediately and
skeleton only what's still arriving.

Fill: `Color.secondary.opacity(0.12)` light / `white.opacity(0.08)` dark.

## Empty states

Art (120–160pt) → bold title → 1–2 line body → one filled pill. What separates
good from generic is entirely the copy: **state the value, not the absence**
("Supplier management starts here", not "No suppliers yet").

Art when the empty state is a destination the user navigated to deliberately.
Text-only when the emptiness is in situ on a screen with other content. **Never
an illustrated empty state for a pending condition** — that's a dashed slot, not
a mascot.

## Haptics

Mark state changes the *user* caused, never ones the app decided. Budget them: a
40-move game that buzzes twice per move feels defective.

| Event | Feedback |
|---|---|
| Piece lifted | `.impact(.light)` |
| Legal drop | `.impact(.medium)` |
| Illegal drop | `.impact(.rigid)` + short shake |
| Capture | `.impact(.heavy)` |
| Check delivered | `.notification(.warning)` |
| Game end | `.notification(.success)` / `.error` by result |
| Checklist step complete | `.notification(.success)` |
| Clock crosses 10s | `.impact(.soft)`, once |
| Sheets, scrolling, navigation | none |

## Micro-interactions

Button press scales to 0.97 with an opacity dip on `.snappy` — never a colour
change alone. **Selection feedback is instantaneous**: animate a highlight's
removal, never its onset, or it feels laggy. Completed checklist rows fill the
check and shift the label to `.secondary` — no strikethrough, which reads as
cancellation rather than achievement.

## What makes an app feel cheap

In rough order of damage:

1. Blurring or hiding the board when a coaching sheet appears
2. A spinner while the opponent thinks — the running clock already says it
3. Confetti after a loss; a mascot expressing disappointment at a missed day
4. A red X or a count of what was lost on a broken streak
5. Clocks that jump or resize on turn change, or lack `.monospacedDigit()`
6. Drop shadows on cards
7. A generic `Continue` CTA — name the step and its cost
8. Skeleton geometry that doesn't match, causing a jump on arrival
9. Twelve type styles; the same 17pt regular for title, body, and metadata
10. Accent colour used decoratively
11. Dark mode as an inversion
12. Haptic on every move
13. An illustrated mascot for a pending condition
14. Capture as instant disappearance — even 0.18s of scale-and-fade helps
15. A `0 day streak` label on first run
16. Looping animation during thinking time
17. **High-contrast brown/cream board squares** — they look like 2004 and make
    every overlay unreadable. Duolingo's board is a 12–15% lightness delta.
18. Two filled buttons on one screen; the destructive option dominant
19. Type-on text animation for coaching copy
20. Coordinates in a gutter, stealing width from the most-looked-at surface
