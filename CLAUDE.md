# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## ♟️ Project Overview

**Limpid Chess** is a 2D single-player mobile chess game built with **Godot 4.6**,
**Android-first** (iOS later). It is made for **chess beginners who freeze each
turn**, not knowing what to play.

The core idea (inspired by *Lazy Chess*): instead of a blank board of 30 legal
moves, **every turn we surface exactly three** — the **best** move, a **"not
bad"** move, and a **blunder** — drawn as interactive arrows. The three are shown
**neutrally** (numbered badges, one colour); the player must *find* the best one.
On their pick we **reveal** the qualities (green / blue / red), award coins,
and explain what the best move was. Errors are the lesson, not the punishment.

> "The move is there, but you must see it." — Tartakower

## 🎯 Core Principles (VERY IMPORTANT)

1. **Calm & encouraging.** Soft "limpid" palette, no clocks, no shame on losing.
   Feedback teaches; it never scolds.
2. **The best move is always on the board.** The whole product is the three-option
   mechanic. Protect it. Don't add a full free-move UI that dilutes the guidance
   (a free mode could be a deliberate future toggle, not a default).
3. **Stay simple & offline.** No backend, no accounts, no ads, no online play. One
   local save file. Premium is a local flag (clock-cheating is explicitly *not*
   worth fighting — see the business model).
4. **Beginner-appropriate AI.** The bot does NOT need to be strong; it needs to be
   *beatable and human-feeling*. A shallow alpha-beta tuned DOWN is correct here.
5. **Performance on mid-range Android.** Search depth is small; keep it that way.
   The board is custom-drawn 2D — cheap. Don't introduce per-frame allocations.

## 🧩 Architecture

Everything is plain GDScript. There is **no native code, no GDExtension, no
Stockfish** (see Licensing — that was a deliberate decision).

```
GameManager (autoload)         scripts/game_manager.gd
  navigation + all persistent state (premium, daily games, coins, stats)

ChessRules (RefCounted)        scripts/chess/chess_rules.gd
  THE source of truth for legality. Board state, legal move generation,
  check/mate/stalemate/draw detection, FEN, UCI, SAN. perft-validated.

ChessBot (RefCounted)          scripts/chess/chess_bot.gd
  negamax + alpha-beta + material/PST eval. Two jobs:
   - choose_move()  → the opponent's (weakened) reply
   - rank_moves() / select_options() / grade_move() → the 3-option mechanic

BotRoster (static data)        scripts/chess/bot_roster.gd
  the cast of opponents (name, avatar, elo, depth, weakness)

Quotes (static data)           scripts/quotes.gd
  Tartakower & friends, for home + game-over

ChessBoard (Control)           scripts/ui/chess_board.gd
  custom _draw: squares, pieces, highlights, the three option arrows + hit-test

Scenes                         scenes/*.tscn  (+ matching scripts/*.gd)
  home · bots · premium · about · game · nav_bar (reusable)
```

Data flow per human turn lives in [`scripts/game.gd`](scripts/game.gd):
`rank_moves → select_options → shuffle → board.set_options → (player taps) →
grade_move → award coins → board.reveal → play → bot replies`.

Keep these layers decoupled: **the UI never decides legality, and the rules
engine never knows about the UI.**

## 🧠 The Chess Engine — rules are sacred

`ChessRules` is perft-validated against 5 canonical positions (start, Kiwipete,
positions 3/5/6) covering castling, en passant, promotion/underpromotion, pins,
and checks.

**If you touch move generation, make/undo, or `is_square_attacked`, you MUST
re-run perft and it MUST still pass before you trust it:**

```
godot --headless --path . -s res://scripts/dev/perft_test.gd
```

Board model: flat 64-cell `PackedByteArray`, index = `rank*8 + file`
(a1 = 0, h8 = 63). Piece code = type (1=pawn … 6=king), +8 for black, 0 empty.
Moves are packed ints: `from(6) | to<<6 | promo<<12 | flag<<15` — always use the
`pack_move` / `move_from` / `move_to` / `move_promo` / `move_flag` helpers.

## 🤖 Bot difficulty & the 3-option ranking

Per-bot config in `BotRoster`: `depth` (plies) and `weakness` (0 = always best …
1 = often drifts to weaker moves + occasional outright blunder). The roster skews
**easy on purpose**.

The three options come from `ChessBot.rank_moves()` (every legal move scored by
the same eval, sorted best→worst) then `select_options()`:
- **best** = top move
- **"not bad"** = a move losing ~20–90 cp vs best (`DECENT_MIN/MAX`)
- **blunder** = a move losing ~120–500 cp — a *believable* trap, not the single
  worst giveaway (`BLUNDER_MIN/MAX`)

Early/forcing positions may legitimately yield fewer than three (no real
blunder exists) — the UI handles 1–3 options.

Grading the player's pick uses centipawn-loss bands
(`Best ≤10 · Great ≤40 · Good ≤90 · Inaccuracy ≤120 · Mistake ≤250 · Blunder`).

> Improvement idea (not yet done): add a small **quiescence** search (captures
> only) so option evals aren't fooled by the horizon. Keep it bounded for mobile.

## 🎨 UI / Design Tokens

Single source of truth:
- [`scripts/ui_constants.gd`](scripts/ui_constants.gd) — `class_name UI`: colour
  palette, board colours, the three move-quality colours, type scale
  (`FONT_DISPLAY 40 → FONT_MICRO 12`), spacing, nav metrics.
- [`assets/default_theme.tres`](assets/default_theme.tres) — OpenDyslexic font +
  default text colour/size (auto-applied via `project.godot`).

Rules:
- **Don't invent colours or font sizes** — pick from `UI`.
- Body labels need no size override (theme default is 20). Override only for
  hierarchy.
- Scenes hosting the nav bar (home, bots, premium, about) leave **136px**
  (`UI.NAV_BOTTOM_GAP`) at the bottom of their main content container.
- The nav bar ([`scenes/nav_bar.tscn`](scenes/nav_bar.tscn)) is reusable —
  instance it, set `current_tab` to `"play" | "bots" | "premium" | "about"`.
- `.tscn` files can't read GDScript constants. If you change a token in
  `ui_constants.gd`, **also update the matching literal** in the affected scenes.
- Top of every page respects the device safe area:
  `max(DisplayServer.get_display_safe_area().position.y, 16)`.

## 📖 Glossary (use these terms consistently)

| Concept | Canonical term |
|---|---|
| The three offered moves | **options** (`best` / `decent` / `blunder`) |
| Quality reveal after a pick | **reveal** |
| Reward currency | **best coin** (gold) and **blunder coin** |
| Opponent | **bot** (from `BotRoster`); never "AI player" |
| Local two-player mode | **Pass & Play** (premium) |
| Engine evaluation unit | **centipawns** (cp) |

Avoid: "Stockfish" (we don't use it), "level" (use **bot** / **tier**),
"energy/lives" (use **daily games**).

## 💸 Business model (keep it generous)

- 3 free games per day (`GameManager.FREE_GAMES_PER_DAY`), tracked locally by date.
- **Premium**: one-time ~$3.99 → unlimited games + Pass & Play. Stored as a local
  flag. Real billing (Google Play Billing / StoreKit) is a TODO in
  [`scripts/premium.gd`](scripts/premium.gd) `_on_get_pressed()`.
- No ads, ever. Don't add them.

## 📜 Licensing & attribution (IMPORTANT — don't break this)

- **No Stockfish / no GPL code.** Stockfish is GPL-3.0; embedding it (mandatory on
  iOS) would force the whole app to be GPL — incompatible with a closed-source paid
  app on the App Store. We use our own permissive engine instead. **Do not add
  Stockfish or any GPL/AGPL engine or chess-rules library.**
- **OpenMoji** (all UI icons + bot avatars) is **CC BY-SA 4.0 → attribution is
  required and ShareAlike applies.** The exact credit lives on the About screen
  ([`scenes/about.tscn`](scenes/about.tscn)) — keep it. If you *modify* an OpenMoji
  SVG, the modified asset must stay CC BY-SA 4.0.
- Chess pieces: JohnPablok improved Cburnett set (CC0). OpenDyslexic font: free.
  Godot: MIT.

## 🛠 Development & validation

Requires Godot 4.6 on `$PATH`. See [HOW_TO.md](HOW_TO.md) for recipes.

```
# Boots project, imports, validates resources/autoloads/scripts, exits.
godot --headless --path . --import          # after adding new assets/scenes
godot --headless --path . --quit            # quick load sanity

# Move-generation correctness (run after ANY rules change):
godot --headless --path . -s res://scripts/dev/perft_test.gd

# Whole-project smoke (instantiates every scene + drives the game pipeline):
godot --headless --path . -s res://scripts/dev/validate.gd

# Visual check (needs a display; renders each scene to /tmp/limpid_*.png):
godot --path . -s res://scripts/dev/screenshot.gd
```

After any non-trivial `.gd` / `.tscn` edit, run `validate.gd` (and `perft_test.gd`
for rules changes) before claiming done. Headless does **not** exercise `_draw()`
or game feel — for those, use the screenshot script or run the app, and say so
explicitly ("layout not visually verified") rather than implying it works.

## ⚠️ Common pitfalls

- **Variant inference is an error here.** `var x := some_dict.get(...)`,
  `var x := untyped_array[i]`, `var x := max(a, b)` all infer `Variant` and the
  GDScript analyser **fails the parse**. Use an explicit type:
  `var x: int = max(a, b)`. (Indexing a `PackedByteArray` is fine — it's typed.)
- **Mirror tokens manually.** Changing a `UI` constant does NOT update `.tscn`
  literals — grep and update them.
- **Don't block the main thread** on long searches. Current depths are fine
  synchronously; if you deepen the bot, move the search to a thread and marshal
  the result back via `call_deferred` / a signal.
- **Don't trust a movegen change without perft.** Subtle bugs (ep discovered
  check, castling through check, underpromotion) hide until perft catches them.

## ✅ Definition of success

A beginner opens the app, taps Play, and on every turn sees three clear moves.
They pick one, learn instantly whether it was best, collect a coin, and slowly
start *seeing* the good moves themselves. Calm, kind, and quietly educational.
