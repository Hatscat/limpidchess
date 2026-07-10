# HOW_TO

Local dev recipes for Limpid Chess. Paths assume Lucien's Linux machine.

## Open the editor

```bash
godot --path ~/limpid-chess
```

## Headless checks (run before claiming a change works)

```bash
# Import new assets/scenes + build the script-class cache:
godot --headless --path ~/limpid-chess --import

# Quick load sanity (autoloads, main scene, resources):
godot --headless --path ~/limpid-chess --quit

# Move-generation correctness — MANDATORY after any ChessRules change:
godot --headless --path ~/limpid-chess -s res://scripts/dev/perft_test.gd
#   → expect ">>> PERFT: ALL TESTS PASSED"

# Whole-project smoke test (instantiates every scene, plays a few plies):
godot --headless --path ~/limpid-chess -s res://scripts/dev/validate.gd
```

Headless uses a dummy renderer, so it does **not** run `_draw()` or show layout.

## Visual check (screenshots)

Needs a real display (`$DISPLAY` set). Renders each scene to `/tmp/limpid_*.png`:

```bash
godot --path ~/limpid-chess -s res://scripts/dev/screenshot.gd
```

## Promo / store video (scripted gameplay recording)

[`scripts/dev/promo_video.gd`](scripts/dev/promo_video.gd) plays the REAL app hands-free
(scripted taps drawn as touch ripples) while Godot's Movie Maker records exact-30fps PNG
frames + a WAV of the game sounds. One segment per run, on a display, against a sandboxed
save (never the real one):

```bash
XDG_DATA_HOME=/tmp/promo_save PROMO_SEG=game godot --path ~/limpid-chess \
  --resolution 540x960 --write-movie /tmp/promo/game/f.png --fixed-fps 30 \
  res://scripts/dev/promo_video.tscn
```

- `PROMO_SEG`: `game` (home → bots → Biscuit → win → moves review) · `puzzles` (a rapid
  streak) · `facetoface` (premium, the piece flip) · `endcard` (static outro).
- **`--resolution 540x960` matters**: the WM clamps a 720×1280 window on a 1080p screen,
  which silently stretches the canvas and shifts every scripted tap. Same 9:16 aspect at
  540×960 keeps the canvas exactly 720×1280 (the driver also maps taps through the
  viewport's final transform).
- Stitch/trim/music/captions with ffmpeg: the cut list + full pipeline used for the 2026
  store video live in `~/Videos/limpid_promo_sources/assemble2.py` (raw segment archives,
  caption strips and the final video sit next to it / in `~/Videos/`). Music: Roa "Haru"
  (chosic.com, credit required in the YouTube description).

## Upgrade Godot

Single binary behind a symlink — upgrading = swapping the binary file.

| Path | Role |
|------|------|
| `~/.local/bin/godot` | symlink on `$PATH` — **don't touch** |
| `~/.local/opt/godot/godot` | the actual binary — **replace this** |

```bash
unzip -o ~/Downloads/Godot_vX.Y.Z-stable_linux.x86_64.zip -d /tmp/godot-new
mv /tmp/godot-new/Godot_vX.Y.Z-stable_linux.x86_64 ~/.local/opt/godot/godot
chmod +x ~/.local/opt/godot/godot
godot --version
```

If `godot: command not found`, recreate the symlink:
`ln -sf ~/.local/opt/godot/godot ~/.local/bin/godot`

### Bumping to Godot 4.7 (do it on a branch, after the current release)

4.7 is a polish release; nothing in it is required, so ship the current Play release on 4.6.3 first.
The pure-Godot side is low risk (no `.tscn`/`.tres` format bump, `config_version` unchanged, the
GDScript is clean). The real cost is the native + Android layer. Keep 4.6.3 installed alongside 4.7
until the branch is verified, and read the official guide first:
`https://docs.godotengine.org/en/4.7/tutorials/migrating/upgrading_to_godot_4.7.html`

The one hard blocker: **InappReview v5.2 is capped at Godot 4.6.3** (see
`addons/GMPShared/menu/gmp.json`), so 4.7 *requires* swapping it.

Order of operations:

1. New git branch.
2. Swap the Android plugins to their 4.7 builds, and replace the staged copies under `android/plugins/` too:
   - **InappReview v5.2 → v5.3** (mandatory; `min_godot` 4.7).
   - **GodotGooglePlayBilling**: refresh the `.aar` to the 4.7 build (v3.2.0 is listed 4.7-compatible).
   - **NotificationScheduler v6.0**: already the 4.7-targeted build per the registry; just confirm on device.
3. Reinstall the Android build template from the 4.7 editor (Project > Install Android Build Template).
   This **overwrites `android/build/`**, so diff/back it up first and re-apply any local gradle edits.
   Keep **JDK 17**.
4. Open the project in 4.7 (it rewrites `features` to "4.7"), then `godot --headless --path . --import`.
5. Run the full suite under 4.7: `perft_test.gd`, `validate.gd`, `test_engine.gd`, `test_selfplay.gd`.
6. Native Stockfish GDExtension: it is forward-compatible, so the 4.5-built `.so`
   (`compatibility_minimum=4.5`) should load as-is, and `stockfish_engine.gd` falls back gracefully if
   not. Confirm `ClassDB.class_exists("StockfishGD")` is true. Only if it is false, rebuild:
   `cd native && GODOT_CPP_BRANCH=4.7 ./build.sh` (delete `native/godot-cpp` first so it re-clones).
7. Eyeball two 4.7 visual changes: CanvasItem no longer adds the antialiasing feather on lines (the
   custom board + option arrows in `chess_board.gd`), and the font-hinting import default changed 1 to 3
   (OpenDyslexic glyphs).
8. Full arm64 AAB export, then an on-device smoke test: billing, reviews, notifications, gameplay, render.

## Asset pipeline

### Chess pieces (JohnPablok / Cburnett, CC0)

Source set on disk: `~/Pictures/JohnPablok Cburnett Chess-v2/.../PNGs/With Shadow/256px`.
Copied + renamed to `assets/pieces/{w,b}_{king,queen,rook,bishop,knight,pawn}.png`.
The board control loads them by that exact naming.

### OpenMoji icons & bot avatars (CC BY-SA 4.0 — attribution required)

Source zips on disk: `~/Pictures/openmoji-svg-color.zip` (and the 72px PNG zip).
Glyphs are named by Unicode codepoint (e.g. `1F451.svg` = crown). To add an icon,
extract its SVG and rasterize with Inkscape (note: **zsh needs `setopt shwordsplit`**
to word-split a `name=codepoint` list in a loop):

```bash
setopt shwordsplit 2>/dev/null
ZIP=~/Pictures/openmoji-svg-color.zip
unzip -o -j "$ZIP" "1F451.svg" -d /tmp/om
inkscape /tmp/om/1F451.svg --export-type=png \
  --export-filename=assets/icons/crown.png -w 128 -h 128
# avatars are rendered at 256px into assets/avatars/
```

Current icons live in `assets/icons/`, avatars in `assets/avatars/`. After adding,
run `--import`. Keep the OpenMoji credit on the About screen.

> Upgrade path for avatars: the research recommended **Open Peeps** (CC0,
> hand-drawn faces, no attribution) at openpeeps.com if you want friendlier,
> attribution-free bot portraits. Drop PNGs into `assets/avatars/` and update
> `BotRoster`.

## Stockfish (the chess brain)

The game drives Stockfish over UCI via
[`scripts/chess/stockfish_engine.gd`](scripts/chess/stockfish_engine.gd). On
desktop it's a **child process**; if none is found it falls back to the built-in
GDScript engine.

Binary lookup order (`CANDIDATES`): `user://stockfish`, then `/usr/games/stockfish`,
`/usr/bin/stockfish`, `/usr/local/bin/stockfish`. Override with an env var:

```bash
LIMPID_STOCKFISH=/path/to/stockfish godot --path ~/limpid-chess

# Test the integration:
godot --headless --path . -s res://scripts/dev/test_engine.gd     # UCI + threading
godot --headless --path . -s res://scripts/dev/test_selfplay.gd   # full game pipeline
```

This dev box already has Stockfish 17.1 at `/usr/games/stockfish` (76 MB, dual NNUE).

### Embedding Stockfish on Android — see [`native/`](native/NATIVE_BUILD.md)

You can't spawn a subprocess on modern Android (W^X), so Stockfish is compiled
**into the app** as a GDExtension. The whole thing is scaffolded under
[`native/`](native/): a godot-cpp binding (`StockfishGD`) that embeds Stockfish 11
(classical eval → tiny, no NNUE net) and a one-command build:

```bash
cd native && ./build.sh      # downloads NDK + SCons + godot-cpp + Stockfish, builds the arm64 .so
```

`StockfishEngine` auto-detects the `StockfishGD` class and uses it on Android,
polling each frame; on desktop it keeps using the subprocess; with neither it
falls back to the GDScript engine. **Not yet compiled/tested** (this box has no
toolchain or device) — read `native/NATIVE_BUILD.md` before building.

- **Desktop builds:** either build the desktop `.so` too (`build.sh` does this if
  a host compiler is present → consistent embedded engine everywhere), or bundle a
  Stockfish binary (extract to `user://stockfish`, `chmod +x`) for the subprocess.

## Android build (APK/AAB)

Android SDK (`~/Android/Sdk`) + JDK (`~/android-studio/jbr`) are present.
Export config: [`export_presets.cfg`](export_presets.cfg) — arm64-v8a, AAB,
min SDK 24, package `game.limpidchess`.

1. In the editor: Project → Export → install the Android build template; set a
   keystore for release signing.
2. Headless once templates/keystore are set:

```bash
godot --headless --path ~/limpid-chess --export-release "Android" ../limpid-chess.aab
```

The first export installs the gradle build template into `android/` (git-ignored).
Note: a release AAB will run the **fallback** engine until the native Stockfish
build above is wired in.

## Save data (and resetting it)

All persistent state lives in ONE plain-text ConfigFile: `user://limpid_chess.cfg`
(written by [`scripts/game_manager.gd`](scripts/game_manager.gd)). It holds the
premium flag, chosen language (`""` = follow the device), sound on/off, the daily
free-games counter, and lifetime stats. There is no backend, no accounts: this file
is the entire save.

Where `user://` resolves (project name is "Limpid Chess"):
- Linux:   `~/.local/share/godot/app_userdata/Limpid Chess/limpid_chess.cfg`
- Windows: `%APPDATA%\Godot\app_userdata\Limpid Chess\limpid_chess.cfg`
- macOS:   `~/Library/Application Support/Godot/app_userdata/Limpid Chess/limpid_chess.cfg`
- Android: the app's private storage (wiped by uninstalling the app)

To reset to a fresh, non-premium first launch:
- **Debug build:** Settings (gear on Home) → "Reset save (dev)" (only shown when
  `OS.is_debug_build()` is true, so it never appears in a release export).
- **Delete the file:** `rm "$HOME/.local/share/godot/app_userdata/Limpid Chess/limpid_chess.cfg"`
- **Edit it** (plain text): set `is_premium=false` under `[player]` to drop premium
  but keep your stats.
- **From the editor:** Project menu → "Open User Data Folder".

The UI language defaults to the **device language** (`OS.get_locale_language()`) if
it's one we ship (en / fr / es), else English; the in-game picker overrides + saves it.

## License (GPL-3.0)

The project is GPL-3.0 (it ships Stockfish). [`LICENSE`](LICENSE) holds the full
text; the About screen discloses Stockfish + the licence in-app. When you publish,
make the source and the exact Stockfish build you ship available.

## TODOs wired but not implemented

- **Android-native Stockfish** — see above; the main remaining task.
- **In-app purchase**: done in code. The `GodotGooglePlayBilling` v3.x addon (a `BillingClient`
  node, under [`addons/GodotGooglePlayBilling/`](addons/GodotGooglePlayBilling/)) is installed, and
  the [`Billing`](scripts/billing.gd) autoload wraps it (buy / restore / acknowledge / promo codes,
  localized price, grant-only). Remaining: create + activate the `premium_unlock` managed product in
  Play Console, then ship a new AAB. On desktop/dev (no Play singleton) the buy flow is a local grant
  in a debug build, otherwise a no-op. (Reset for testing via the dev "Reset save" button, above.)
- **In-app review + daily-reset notification**: done in code. [`Reviews`](scripts/reviews.gd) asks
  for a Play rating once after the 2nd non-loss game; [`Notifications`](scripts/notifications.gd)
  schedules a "your free games are back" reminder for tomorrow morning when a free player runs out
  (cancelled when they have games again or go Premium). Both resolve the plugin's `class_name` nodes
  dynamically, so they no-op until the addons are installed: drop in
  [godot-inapp-review](https://github.com/godot-mobile-plugins/godot-inapp-review) (`InappReview`) and
  [godot-notification-scheduler](https://github.com/godot-mobile-plugins/godot-notification-scheduler)
  (`NotificationScheduler` + `NotificationData`), then rebuild. The notification adds the Android 13+
  `POST_NOTIFICATIONS` permission (requested at first schedule) and uses inexact alarms, so no
  `SCHEDULE_EXACT_ALARM` Play declaration is needed. A small-icon drawable + channel may need adding
  per the notification plugin's README if no icon shows.
