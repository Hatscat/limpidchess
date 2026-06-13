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

## License (GPL-3.0)

The project is GPL-3.0 (it ships Stockfish). [`LICENSE`](LICENSE) holds the full
text; the About screen discloses Stockfish + the licence in-app. When you publish,
make the source and the exact Stockfish build you ship available.

## TODOs wired but not implemented

- **Android-native Stockfish** — see above; the main remaining task.
- **In-app purchase**: [`scripts/premium.gd`](scripts/premium.gd) `_on_get_pressed()`
  sets the premium flag locally. Wire Google Play Billing there; call
  `GameManager.set_premium(true)` on a successful purchase.
- **App icon**: still the default Godot `icon.svg`.
- **Sound**: none yet (move/capture/reward cues would add a lot of game feel).
