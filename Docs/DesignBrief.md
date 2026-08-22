# ChessCoach — Design Brief

Derived from Mobbin research across shipped apps. Chess apps themselves are barely
indexed (no chess.com/lichess/Chessable); **Duolingo Chess** is the exception and is
the closest structural match. The rest comes from fitness/health (Oura, Whoop, Bevel,
Eight Sleep, Strava, The Outsiders), learning (Uxcel, Speak, Quizlet, Mimo), and AI
coaching UIs (NBA Insights, Superpower, Alma, Bloom).

**Register: instrument panel, not arcade.** Oura/Whoop/Bevel, never Duolingo's game layer.

---

## Global conventions

### Typography (system fonts only)
| Use | Style |
|---|---|
| Screen titles | `.largeTitle.bold()` |
| Section headers | `.title3.bold()` |
| Section eyebrows | `.caption.weight(.semibold)` + `.textCase(.uppercase)` + `.tracking(0.6)` + `.secondary` |
| Metric values | `.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()` |
| SAN notation | `.system(.body, design: .monospaced)` |
| Coach prose | `.body`, `.leading(.loose)`, max ~68 chars/line |

**Every clock, eval, rating, and point total gets `.monospacedDigit()`** — jittering
digits in a live clock is the top tell of an unpolished chess app.

Optional: a serif for exactly one editorial line (the coach's verdict headline) and
nowhere else.

### Color
- Ground `Color(.systemBackground)`; cards `.quaternary` fill, **no borders, no shadows**. Design dark-first.
- **One accent** for interactive/brand: desaturated teal or slate blue. **Avoid green as the accent** — it collides with "good move" semantics.
- **Semantic quartet** — used *only* on classification badges and eval deltas:
  - Great/best → accent (not green)
  - Inaccuracy → amber
  - Mistake → orange
  - Blunder → red
- **Board squares: two near-neutral tones ~8% apart in luminance.** Never chess.com's saturated green/buff — it eats every overlay drawn on it.
- The board overlay layer (highlights, hints, arrows) is the **only** place full saturation goes; ≥60% opacity over the square, never replacing the square fill.
- Progress/leak bars: **one color, vary opacity by rank.** Multi-hue bars read as a pie chart of blame.
- Locked/incomplete: `.quaternary` fill + `.secondary` text — never reduce opacity of a whole row.

### Layout invariant
**Exactly one filled button per screen.** Everything else is `.bordered`, plain, or status.

### Focus invariant
**Only a live game hides the tab bar.** `PlayScreen` is the one screen that writes
`AppModel.isPlayingGame` — on appear, whenever `session` becomes nil or non-nil, and on
disappear — and `RootView` hides `MainTabBar` on exactly that flag. Nothing else may write it.

The other two focus behaviours are deliberate and different, and neither is a precedent:

- **Review keeps its stack.** `todayPath` survives a tab switch on purpose, so leaving Review
  and coming back returns you to the same moment rather than to the top of the game.
- **The Train session is a `fullScreenCover`** and so cannot be switched away from at all. That
  is a property of a timed drill run, not a focus rule.

A new screen that wants focus mode takes the Play rule — set and clear one flag, keep the tab
bar reachable the instant the timed thing ends. It does not invent a fourth model.

---

## Screen 1 — Today

`ScrollView`, top to bottom:

1. **Rung header card** — `RoundedRectangle(cornerRadius: 16).fill(.quaternary)`. Eyebrow `RUNG 2`, title `Tactical Vision` (`.title3.bold()`), 6pt `Capsule` progress track. The **weekly focus habit rides here as a `Capsule` chip** (`Focus: check opponent threats`) — it does not get its own card. *(Life Reset level card)*
2. **Streak strip** — small card, `S M T W T F S` as seven fixed-width items: done = filled `Circle` + checkmark, future = `.quaternary`, today = stroked ring. Flame + count top-right at `.subheadline`, **not** a 48pt hero. *(pushr)*
3. **Three steps** — `VStack(spacing: 12)` of `HStack` rows; leading 24pt state glyph drives everything:
   - done → `checkmark.circle.fill` accent, title `.strikethrough()` `.secondary`
   - current → stroked `Circle` with ordinal inside, full-opacity title
   - pending → `Circle().fill(.quaternary)`, `.secondary` title
   
   Trailing progress `"0/3"` in `.footnote.monospacedDigit().secondary`. *(Gymshark Day N/66)*
4. **One CTA** in `.safeAreaInset(edge: .bottom)` over `.regularMaterial`. Label names the *next step and the opponent*: `Play Oscar`, `Review 3 moments` — never a bare `Play`. *(Duolingo Chess names the opponent in the button; Gymshark's SEE MY PROGRESS)*

Steps 1–3 are **status, not buttons** — they may navigate but must not look like CTAs.

---

## Screen 2 — Play

Structure copied from Duolingo Chess's in-game board, minus the cartoon layer.

- **Top bar = three capsules only.** Bare `xmark` glyph (no circle chrome); your clock + opponent clock side by side with the **inactive one dimmed to ~35% opacity** (better active-side indicator than borders or color); right-aligned material/eval capsule `↑ 11` with directional chevron + tint. `Capsule().fill(.quaternary)` + `.monospacedDigit()`.
- **Board edge-to-edge** — no horizontal padding, no border by default (make the border a setting). Low square contrast puts all visual weight on pieces and leaves headroom for highlights.
- **Coordinates are on, always, and are not a setting.** Every coaching sentence in this app names squares, and a reader who cannot decode `f3` has no way to connect the sentence to the board except by being shown, on the board, which square f3 is. They cost no width — the glyphs sit inside the corner squares, not in a gutter — so the price is a little ink and the return is algebraic notation learned by osmosis. Turned on in `BoardAppearance.style`, because it is an app decision and not a package default; `BoardUI`'s own default stays off, which is right for a board built to be *played* on rather than *learned* on.
- **Opponent chip above board, user below.** Compact `HStack`: `Circle` monogram + name + one-line trait. Describe personality in *trait phrases*, not difficulty integers: `Oscar · trades early, hates pressure`. *(Bloom guide picker)*
- **Move feedback is drawn on the square, not in a banner** — concentric expanding rings on the affected square, green + `+9` for a gain, red + `-3` for a loss. Two or three `Circle().stroke()` layers animated with `.scaleEffect` + `.opacity` in the board `ZStack`. This is the eval-delta primitive.
- **Undo/redo as ghost circular buttons** flanking the bottom edge, `.tertiary` when disabled.

### Guided-mode Socratic pause
`.presentationDetents([.height(220)])` + `.presentationBackgroundInteraction(.disabled)`,
**short enough that the relevant board area stays visible**. Question as `.title2.bold()`
(lowercase reads calm), one `.subheadline.secondary` clarifier, two buttons in an `HStack`
(one `.bordered`, one `.borderedProminent`). *(pushr)*

For 3+ options: stacked full-width bordered rows with centered accent text, **plus an
escape row in a distinct color** (`I'm not sure, show me`). Always ship the escape hatch. *(Alan)*

### Blunder → second try → hint ladder
**Mimo's "Almost there!" sheet is the single best match in the library:**
- Soft status pill reading **"Almost there!"** — *not* "Incorrect", *not* red-flooded. Neutral card, colored top edge only.
- Inset grey box restating what the position needs, without the answer.
- **`✨ Get help`** as a small inline text button — deliberately quieter than the primary.
- Primary full-width reads **`Try again`**, not `Continue`. Retry is the default path.

Borrow from Duolingo only its secondary outlined **`EXPLAIN MY MISTAKE`** button placed
*above* the dismiss — that's the coach entry point.

One sheet, one `@State var hintLevel`, content swapping with `.animation(.snappy, value:)`.
L0 text nudge → L1 single slow pulse ring on one square → L2 arrow `Path` overlay.
"Get help" advances one rung, never resets, never skips.

---

## Screen 3 — Review

Skeleton from Bevel's Strain screen: **summary metric → stat pills → verdict → timeline.**

1. **Eval graph** — Swift Charts `AreaMark` with zero baseline. Moments as `PointMark`s in classification colors; tapping scrubs the board. **Label the Y axis with words** (`Winning`/`Equal`/`Losing`) rather than `+2.5`. Dashed-border shaded band for the normal range + `.annotation` tooltip pill on the selected point. *(Strava Relative Effort, The Outsiders)*
2. **Stat pills** — label in small `.secondary` caps, big value, and a **grey comparison chip with a caret below**: `Accuracy 84%` / `▾ your avg 79%`. *(The Outsiders workout stats)*
3. **Verdict card** — lightning glyph + **bold one-line verdict headline** + paragraph truncating at ~3 lines with a corner expand affordance. The game gets a verdict line before any detail, and it is written from the same analysis the graph above is drawn from, so the sentence and the numbers cannot disagree. *(Bevel)*
4. **Moments filmstrip** — horizontal `ScrollView` + `.scrollTargetBehavior(.viewAligned)`, max 3 cards: board thumbnail, `Move 23`, classification badge, one-line stake. Move number as a **numeric badge on the thumbnail corner**. *(Bevel timeline)*
5. **Per-moment coach commentary** — timestamp header (`Move 23 · Nxe5?`), the note for that moment, then **two suggested-question chips as full-width grey rounded rects**, each answered on tap from the stored analysis. **No provenance row and no thumbs pair:** the note names the square, the refuting move and the material at stake because the detector found all three, so there is no authorship to disclose and nothing a rating could tune. *(NBA AI Insights, Mindvalley)*
   - **Arrival:** the note is written while the game is being analysed, so the card is either waiting or complete — reserve its frame with a `.redacted(reason: .placeholder)` 3-line skeleton under a label naming the work, then swap to the text. **Never a spinner in the card center** — the card appears instantly and fills in. Bold inline emphasis on load-bearing numbers. *(Superpower, Alma)*
6. **Move list last**, collapsed in a `DisclosureGroup`. Reference material, not the story. **Badge only the four classifications**, not every move.

---

## Screen 4 — Train

**Queue entry:** filled `Circle` icon, title, two side-by-side picker chips (`Length: 10`,
`Focus: Tactics`), full-width `Start`, then a **"Due today" list with a progress ring on
each row's left** and `Theme · 60% mastered` subtitle. The per-item ring shows decay
without exposing SRS intervals. *(Speak Smart Review)*

**Solve chrome:** `xmark` left, `3 / 10` centered `.monospacedDigit()`, settings right,
thin `ProgressView` beneath. **Small counters at the left/right screen edges** incrementing
as you go — session outcome without a results modal. *(Quizlet)*

**Board area:** task line as plain `.title3` question above the board, board edge-to-edge,
bottom bar with **small outlined lightbulb left + disabled-until-solved primary filling the
rest**. Same component as Play's hint bar — build once. *(Duolingo Chess puzzle)*

**Endgame drills:** own section, `LazyVGrid` 2-up cards: pattern name (`Lucena`), tiny board
thumbnail, mastery ring. **Named patterns, never numbered levels.** *(Uxcel)*

**Wrong answer:** supportive line, wrong choice tinted red with `✕`, correct one in a
**dashed green border** — `StrokeStyle(lineWidth: 1.5, dash: [4])` on the target square is
a distinct "this was the answer" state. *(Quizlet)*

---

## Screen 5 — Profile

### Rating chart
Big current value with grey unit suffix, date, **a plain-language interpretive paragraph
directly under the number**, then range stepper + period `Menu`, then the chart.
Best trick to steal: **period-average segments as horizontal colored bars over the noisy
line, each labeled with value and % delta** (`+10%`, `−7%`) — turns a jagged rating line
into a narrative. Add a `1M/3M/6M/1Y` segmented control below and a highlight ring on the
most recent point. *(The Outsiders Endurance Fitness, Bevel Strength Progression)*

### Curriculum ladder (4 rungs)
Each rung is a `DisclosureGroup`:
- Header: `LEVEL 2` eyebrow + optional `LOCKED` grey `Capsule` + title `.title3.bold()` + chevron
- Body: `VStack` of skill rows — icon, **measurable skill name**, trailing check (filled = met, grey outline = not yet)
- Current rung expanded by default; completed collapse to one line with a check; locked collapse with the chip

*(Uxcel Go — names every sub-skill, which is why it reads as competence rather than points)*

Alternative visual path: left-aligned vertical dashed connector with thumbnail + eyebrow +
title + `See task` pill *(Alan)*. **Do not build the Duolingo zigzag.**

### Rating leak chart (highest-value borrow)
Compose Oura Readiness + Eight Sleep Score Contributors. Section header `RATING LEAKS`.
Each cause is a row, sorted by points lost descending:
- **Line 1:** cause label + grey `Capsule` weight chip + right-aligned value (`−38 pts`)
- **Line 2:** one-line description `.footnote.secondary`
- **Line 3:** full-width 4pt progress bar proportional to points lost — **single accent, opacity by rank**
- Trailing `chevron.right` drilling into Train filtered to that theme — every row tappable is the whole point

Above the rows: big score + status word in accent, headline sentence, short explanatory
paragraph. Consider a **per-leak sparkline** showing 90-day improvement — the single most
motivating element on the screen. *(Bevel Recovery)*

---

## Patterns to avoid

1. **Duolingo zigzag path** with treasure chests, star bubbles, mascot cutouts — reads as a children's product.
2. **Cartoon avatars flanking the board reacting to the position** — charming in a course, corrosive in a training tool.
3. **Red "Incorrect" floods** — trains flinching. Use Mimo's neutral "Almost there!" + `Try again`.
4. **XP, gems, energy, hearts.** One meaningful number (rating) and one streak. Fake currencies dilute both.
5. **Confetti/celebration modals after every session.** Reserve for rung completion at most.
6. **A results modal that blocks return to the board.** Post-game is a screen you can leave.
7. **Big centered ring gauges for non-0–100 values.** Right for readiness, wrong for rating — use a line chart with trend annotation.
8. **Borders and captured-piece trays on by default** — make them settings. Coordinates are the one deliberate exception and are not a setting: see Screen 2.
9. **Spinners inside the coach card** — reserve the frame with a redacted skeleton.
10. **Multiple filled buttons per screen.**
