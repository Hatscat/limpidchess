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

## Android build

Toolchain present: Android SDK (`~/Android/Sdk`) + JDK (`~/android-studio/jbr`).
Export config: [`export_presets.cfg`](export_presets.cfg) — arm64-v8a, AAB,
min SDK 24, package `ai.groovin.limpidchess`. No native libraries, so **no NDK is
needed** (this is a benefit of the pure-GDScript engine).

1. In the editor: Project → Export → install Android build template + Android
   export templates if prompted; set a keystore for release signing.
2. Or headless once templates/keystore are set:

```bash
godot --headless --path ~/limpid-chess --export-release "Android" ../limpid-chess.aab
```

The first export will ask Godot to install the gradle build template into
`android/` (git-ignored).

## TODOs wired but not implemented

- **In-app purchase**: [`scripts/premium.gd`](scripts/premium.gd) `_on_get_pressed()`
  currently sets the premium flag locally. Wire Google Play Billing (and later
  StoreKit) there; call `GameManager.set_premium(true)` on a successful purchase.
- **App icon**: still the default Godot `icon.svg`. Replace with a Limpid Chess
  icon and point `launcher_icons/main_192x192` in `export_presets.cfg` at it.
- **Sound**: none yet (move/capture/reward cues would add a lot of game feel).
