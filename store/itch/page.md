# itch.io page: Limpid Chess

Versioned source for the itch.io page, https://lone-bee.itch.io/limpid-chess, as `store/<locale>/`
is for the Play listing. The itch version is a funnel to the Android app: the same free tier, and
nothing sold in itch's frame. What the itch build changes, and why some settings must never move,
is in [web/README.md, "itch.io build"](../../web/README.md#itchio-build).

## Create new project (top of the form)

| Field | Value |
|---|---|
| Title | Limpid Chess |
| Project URL | `limpid-chess` (so lone-bee.itch.io/limpid-chess) |
| Short description or tagline | Smooth chess: every turn shows three moves. Find the best one. |
| Classification | Games |
| Kind of project | HTML |
| Release status | Released |
| Pricing | No payments (not "$0 or donate": the terms and privacy pages say nothing is paid on itch.io) |

## Uploads

`build/limpid-chess-itch-<version>.zip` from `web/build_web.sh --itch`. Tick **This file will be
played in the browser**. One upload only: to update, upload the new zip and delete the old one (or
switch to butler, never both).

## Embed options

| Field | Value |
|---|---|
| Embed | Embed in page, viewport 500 × 900 |
| Mobile friendly | On, orientation **Portrait** |
| Automatically start on page load | Off (Click to play: the first load is about 18 MB) |
| Fullscreen button | On |
| Enable scrollbars | Off |
| SharedArrayBuffer support | **Off, always** (it moves the game to another origin and strands every save) |

## Details

| Field | Value |
|---|---|
| Description | the text at the end of this file |
| Genre | Strategy |
| Tags | chess, board game, puzzle, educational, singleplayer, turn-based, touch-friendly, relaxing, casual, brain training |
| App store links | Google Play: `https://play.google.com/store/apps/details?id=game.limpidchess&utm_source=itch.io&utm_campaign=badge` |
| Platforms | none ticked (no download; Android is the badge above, not a platform) |
| AI generation disclosure | Lucien's call. The field covers code and text written with an LLM "even if you hand-edited it" (categories: Graphics, Sound, Text & Dialog, Code). It is mandatory only for asset pages; Yes lists the game under "AI Assisted", which players can filter out |
| Community | Comments |
| Visibility & access | Draft while testing, then Public once |

Metadata:

| Field | Value |
|---|---|
| Code license | GNU General Public License v3.0 (GPL) |
| Asset license | empty (OpenMoji is CC BY-SA, the pieces and puzzles CC0, the font its own: all credited in the description) |
| Links | Homepage `https://limpidchess.lonebee.games/`, Source code `https://github.com/Hatscat/limpidchess` |
| Languages | English, French, Spanish, Portuguese, German, Italian, Russian, Turkish, Polish, Indonesian, Vietnamese, Ukrainian, Greek (exactly these: wrong ones can get a page delisted) |
| Inputs | Mouse, Touchscreen, Smartphone |
| Accessibility | Color-blind friendly (every revealed move also gets a check, dash or cross) |
| Average session | A few minutes |
| Multiplayer | none (Face to Face is Premium, which is not sold on itch) |

## Media

- **Cover image**: `store/itch/cover_630x500.png`. Without a cover, itch never lists the page. Regenerate
  with the command in `scripts/dev/shot_feature.gd`'s header (`LIMPID_FEAT_LAYOUT=stacked`).
- **Screenshots**, in this order: `docs/img/Screenshot_before_move_x3.png`,
  `Screenshot_after_move_x3.png`, `Screenshot_review_x3.png`, `Screenshot_moves_review_x3.png`,
  `Screenshot_puzzle_x3.png`. Not Face to Face: it is Premium-only here.
- **Trailer**: optional, the Play listing's YouTube URL if there is one.

## Theme (the "Edit theme" button on the page)

- Layout, Screenshots: **Sidebar** (otherwise itch hides the screenshots of a page that has a game).
- Colors, from `scripts/ui_constants.gd`: background `#171A1F`, inner column `#21242B`, text
  `#FFFFFF`, links and buttons `#66BDD9`.
- Embed background (shown behind "Run game" before the click): `store/itch/play_background_500x900.png`,
  the "before move" screenshot fitted to the 500 × 900 embed.

## Description (paste as is)

```text
Free software under GPL-3.0. Source code: https://github.com/Hatscat/limpidchess

A smooth chess game where every turn shows three moves. Your job: find the best one.

A blank board with thirty legal moves can make anyone freeze. Here, every turn draws three arrows in one color: the best move, a "not bad" move and a blunder. Pick one and the colors reveal how you did, with a grade and the best move explained. Mistakes are the lesson, never a punishment. Made for beginners, and a relaxed way to play for everyone else.

Free to play right here, in your browser:
• 3 games a day against 7 friendly bots, plus 2 bonus games to start
• Puzzles: 1 run a day, plus 2 bonus runs to start
• 1 move-by-move game review a day
• No ads, no account, no clock

Premium is a one-time purchase (no subscription) in the Android app on Google Play, or on the website: unlimited games, Puzzles and reviews, all 14 bots, and Face to Face for two players on one device. It isn't sold here on itch.io.

Good to know: this page keeps its own progress, separate from the website and the Android app. Safari, and every browser on iPhone and iPad, forgets it when the browser quits. For progress that lasts, play in the Android app, or at limpidchess.lonebee.games (on iPhone, add it to your Home Screen). The first load is about 18 MB.

13 languages, all in the dyslexia-friendly OpenDyslexic font. Every revealed move also gets a symbol (check, dash, cross), so colors are never needed.

Credits: chess engine Stockfish (GPL-3.0). Icons and bot avatars: OpenMoji (CC BY-SA 4.0). Chess pieces: JohnPablok's improved Cburnett set (CC0). Puzzles: Lichess open database (CC0). Font: OpenDyslexic. Made with Godot.

Also by Lone Bee: Draw my Code (https://lone-bee.itch.io/draw-my-code)
Privacy: https://limpidchess.lonebee.games/privacy.html · Terms: https://limpidchess.lonebee.games/terms.html
```

Keep it in sync like the Play listing: when a feature, the free tier, the languages or what Premium
includes changes, update this text and the page.
