# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## ♟️ Project Overview

**Limpid Chess** is a 2D single-player mobile chess game built with **Godot 4.6**,
**Android-first** (iOS later). It is **beginner-first but fun at any level**: a smooth,
relaxing take on chess that needs less focus and calculation than a full game. Beginners
who freeze each turn, not knowing what to play, get unstuck; stronger players get a chill
way to play.

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
2. **Smooth & frictionless.** The one friction we kill is choice overload: a blank
   board of 30 legal moves makes a beginner freeze. Surfacing exactly three keeps them
   moving. Keep the whole flow smooth: fast turns, few taps, no dead-ends.
3. **The best move is always on the board.** The whole product is the three-option
   mechanic. Protect it. Don't add a full free-move UI that dilutes the guidance
   (a free mode could be a deliberate future toggle, not a default).
4. **Stay simple & offline.** No backend, no accounts, no ads, no online play. One
   local save file. Premium is a local flag (clock-cheating is explicitly *not*
   worth fighting — see the business model).
5. **Beginner-appropriate AI.** The opponent is Stockfish dialled DOWN (low Skill
   Level + short movetime) so it's *beatable and human-feeling*. Don't crank it up.
6. **Keep the per-turn wait short.** The options analysis runs Stockfish each human
   turn — tune `ANALYSIS_DEPTH_SF` / MultiPV so it stays ~sub-second. The board is
   custom-drawn 2D — cheap. Don't introduce per-frame allocations.

> **Headline word: "smooth."** In all user-facing / marketing copy (landing site,
> Play listing, taglines) the word that qualifies the experience is **smooth**, not
> "calm". Calm / kind / no-shame are real values but supporting notes; lead with smooth.

## 🧩 Architecture

The **rules layer is plain GDScript**; the **brain is Stockfish** (driven over
UCI), with the GDScript engine kept as a fallback when Stockfish is unavailable.

```
GameManager (autoload)         scripts/game_manager.gd
  navigation + all persistent state (premium, daily games, coins, stats)

ChessRules (RefCounted)        scripts/chess/chess_rules.gd
  THE source of truth for legality. Board state, legal move generation,
  check/mate/stalemate/draw detection, FEN, UCI, SAN. perft-validated.
  Stockfish does NOT replace this — it can't cleanly report draws/SAN, and we
  don't want a subprocess round-trip on every tap.

StockfishEngine (Node)         scripts/chess/stockfish_engine.gd   ← the brain
  Launches Stockfish as a child process, speaks UCI on a worker thread so a
  search never blocks the UI. analyse(fen, multipv, depth) → ranked moves;
  best_move(fen, {skill, movetime}) → the bot's reply. Desktop only via
  subprocess; Android needs a native build (see Licensing / HOW_TO).

ChessBot (RefCounted)          scripts/chess/chess_bot.gd   ← fallback + helpers
  - static select_options() / grade_move() / cp bands → the 3-option mechanic
    (used by BOTH engines — they operate on a {move, score} ranked list)
  - negamax + alpha-beta + PST eval → only used if Stockfish is absent

BotRoster (static data)        scripts/chess/bot_roster.gd
  opponents: name, avatar, elo, sf_skill/movetime (Stockfish) + depth/weakness (fallback)

Quotes (static data)           scripts/quotes.gd       Tartakower & friends
ChessBoard (Control)           scripts/ui/chess_board.gd  custom _draw + hit-test
Scenes                         scenes/*.tscn (+ scripts/*.gd)
  home · bots · premium · about · game · nav_bar (reusable)
```

Data flow per human turn lives in [`scripts/game.gd`](scripts/game.gd):
`analyse (Stockfish MultiPV, or fallback rank_moves) → select_options → shuffle →
board.set_options → (player taps) → grade_move → award coins → board.reveal →
play → bot replies`. Every game: **random player colour**, and **White's first
move is an auto-chosen random good opening** (so positions stay fresh).

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

Per-bot config in `BotRoster`: `sf_skill` (Stockfish Skill Level 0–20) + `movetime`
(ms) for the Stockfish path, and `depth`/`weakness` for the fallback. The roster
skews **easy on purpose**. The bot's move uses the bot's skill; the **options
analysis pass always runs at full strength** (`analyse()` sets Skill Level 20 +
MultiPV = legal-move count, depth `ANALYSIS_DEPTH_SF`) so the teaching eval is honest.

The three options are built from the ranked `{move, score}` list (Stockfish
centipawns, or fallback eval) via `ChessBot.select_options()`:
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
- **Every button carries an icon** (left of its label, from `assets/icons`) so actions
  read at a glance. Reuse the shared set: `check.png` for a confirm / continue / "yes"
  action, `close.png` for cancel / dismiss / "back". The two confirmation dialogs (bot
  game + Puzzle Rush) must stay identical: a `[Cancel ✕] [Confirm ✓]` pair, same text
  and icons — never a mode-specific verb like "Leave" on the confirm button.
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
| Local two-player mode | **Face to Face** (premium; code identifier stays `pass_and_play`) |
| Engine evaluation unit | **centipawns** (cp) |

Avoid: "level" (use **bot** / **tier**), "energy/lives" (use **daily games**).

## 💸 Business model (keep it generous)

- 3 free games per day (`GameManager.FREE_GAMES_PER_DAY`), tracked locally by date.
- **Premium**: one-time ~$3.99 → unlimited games + Face to Face. Entitlement is a local
  flag (`GameManager.is_premium`), granted by the [`Billing`](scripts/billing.gd) autoload
  (Google Play Billing) on a successful buy / restore / promo-code redemption. The price is
  read live from Play (localized). Remaining setup (plugin install + Play Console product)
  is documented in HOW_TO.md under "In-app purchase".
- No ads, ever. Don't add them.
- **GPL is fine for a paid Android game** — GPL lets you sell the binary; you just
  must also offer the source. (We target Google Play, not the Apple App Store,
  which is the only place GPL is genuinely blocked.)

## 📜 Licensing & attribution (IMPORTANT — don't break this)

This project is **free software under GPL-3.0** ([`LICENSE`](LICENSE)) because it
ships **Stockfish** (GPL-3.0). This was a deliberate reversal of the earlier
"avoid GPL" plan once iOS was dropped from scope.

- **Stockfish is the engine** and is GPL-3.0. Obligations we MUST keep (GPL is
  triggered at the first public release, i.e. the Play Store APK — not later):
  (1) publish the full corresponding source (the whole game + the exact Stockfish
  build) at a public repo; (2) point users to it + the GPL-3.0 licence. The
  About screen carries a low-key "Source & licenses" link and a "Stockfish
  (GPL-3.0)" credit (keep them), and the Play listing must repeat the source
  link (GPLv3 §6(d): clear directions next to the download). No open-source
  *marketing* is required. Public source repo: `github.com/Hatscat/limpidchess`.
- Because we link/bundle Stockfish, **the whole app is GPL-3.0** — keep it that
  way; don't add proprietary-only code paths that would violate it.
- **OpenMoji** (UI icons + bot avatars) is **CC BY-SA 4.0 → attribution required,
  ShareAlike applies.** Credit lives on the About screen — keep it. Modified
  OpenMoji SVGs must stay CC BY-SA 4.0.
- Chess pieces: JohnPablok improved Cburnett set (CC0). OpenDyslexic: free. Godot: MIT.

### Shipping Stockfish per platform
[`StockfishEngine`](scripts/chess/stockfish_engine.gd) has two transports, picked
automatically by `start()`: the native **`StockfishGD` GDExtension** (`ext`, polled
each frame) and a **subprocess** (`pipe`, worker thread). Neither → GDScript fallback.
- **Desktop / dev:** uses the system / bundled Stockfish subprocess (resolved via
  `CANDIDATES` / the `LIMPID_STOCKFISH` env var).
- **Android:** can't spawn a subprocess (W^X), so Stockfish is compiled in via the
  GDExtension under [`native/`](native/NATIVE_BUILD.md) — a godot-cpp binding
  embedding **Stockfish 11** (classical, no NNUE net → tiny). Build with
  `cd native && ./build.sh`. **Authored but not yet compiled/tested** (no toolchain
  or device on the dev box). If `StockfishGD` is absent, Android uses the GDScript
  fallback. Don't put the `.gdextension` in `addons/` until the `.so` exists — it
  errors on every run; `build.sh` generates it post-build (template in `native/`).

## 🛠 Development & validation

> **Committing is the maintainer's job.** Lucien commits code and assets himself, so
> do NOT run `git commit` / `git push` unless explicitly asked. You ARE encouraged to
> go the other way on verification: run the headless checks below liberally and do
> adversarial self-reviews of your own changes, especially to catch **regressions**
> before handing work back.

Requires Godot 4.6 on `$PATH`. See [HOW_TO.md](HOW_TO.md) for recipes.

```
# Boots project, imports, validates resources/autoloads/scripts, exits.
godot --headless --path . --import          # after adding new assets/scenes
godot --headless --path . --quit            # quick load sanity

# Move-generation correctness (run after ANY rules change):
godot --headless --path . -s res://scripts/dev/perft_test.gd

# Whole-project smoke (instantiates every scene + drives the game pipeline):
godot --headless --path . -s res://scripts/dev/validate.gd

# Stockfish integration (UCI pipe, threaded analyse/best_move, and full self-play):
godot --headless --path . -s res://scripts/dev/test_engine.gd
godot --headless --path . -s res://scripts/dev/test_selfplay.gd

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
start *seeing* the good moves themselves. Smooth, kind, and quietly educational.
