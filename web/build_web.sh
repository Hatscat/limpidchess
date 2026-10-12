#!/usr/bin/env bash
# Export a web build, patch it, optionally deploy.
#
#   web/build_web.sh            # the website's PWA build: export + patch into build/web/
#   web/build_web.sh --deploy   # ...then copy the build into docs/play/ (GitHub Pages)
#   web/build_web.sh --itch     # the itch.io build into build/itch/, zipped for upload
#
# Every release MUST go through a full re-export: the PWA cache version is stamped
# at export time, so swapping single files under an old export leaves players on
# the cached previous version forever.
#
# The itch.io build exports the "Web (itch)" preset: PWA off, feature tag "itch" (everything
# it changes is listed in scripts/itch.gd). itch serves every game from ONE origin, so that
# build never has a service worker: patches 1-4 below are replaced by checks that nothing of
# the PWA shipped, and the save gets its own database. See web/README.md, "itch.io build".
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
	echo "usage: web/build_web.sh [--deploy | --itch]" >&2
	exit 2
}
if [[ $# -gt 1 ]]; then
	usage
fi
MODE=web
case "${1:-}" in
	"") ;;
	--deploy) MODE=deploy ;;
	--itch) MODE=itch ;;
	*) usage ;;
esac
if [[ "$MODE" == "itch" ]]; then
	OUT=build/itch
	PRESET="Web (itch)"
else
	OUT=build/web
	PRESET="Web"
fi

# Refuse to publish a build wired to the Lemon Squeezy TEST store: test cards work
# there, so Premium would be free (and no money would arrive). See lemon_squeezy.gd.
# The itch.io build never starts the store client (see Itch), but it is a public release too.
if [[ "$MODE" != "web" ]] && grep -q '^const TEST_STORE := true' scripts/lemon_squeezy.gd; then
	echo "REFUSING to build a release: lemon_squeezy.gd has TEST_STORE = true." >&2
	echo "Fill LIVE_CHECKOUT_URL / LIVE_PRODUCT_IDS and set TEST_STORE := false first." >&2
	exit 1
fi

# The VS Code snap leaks a snap-scoped XDG_DATA_HOME; Godot then can't find its
# export templates. Point it back at the real one when that happens.
if [[ "${XDG_DATA_HOME:-}" == *"/snap/"* ]]; then
	export XDG_DATA_HOME="$HOME/.local/share"
fi

# Always a clean full export: stale files from previous exports must never ride
# along (the --deploy globs would sweep them into docs/play and mask failures).
# Godot needs the target folder to exist, so recreate it after the wipe.
rm -rf "$OUT"
mkdir -p "$OUT"
# Keep the editor from importing exported artifacts back in as project resources.
touch build/.gdignore

godot --headless --path . --export-release "$PRESET" "$OUT/index.html"

# Website build: patch the generated service worker (all verified against the 4.6.3
# template; every patch asserts loudly if the template ever changes shape):
# 1. Add the browser Stockfish files (names derived from web/engine/, never
#    hardcoded — an engine bump must not strand stale names in the cache list) and
#    the boot splash (index.png, absent from Godot's lists) to the
#    cache-on-first-fetch list, or an offline relaunch silently loses the engine.
# 2. Map scope-root navigations ("/", "/play/", with or without query strings) to
#    the cached index.html: the stock worker looks up the bare URL, misses, hits
#    the dead network, and shows the browser error page instead of the cached game.
# 3. Only cache OK responses: without it, one bad first fetch (a partial deploy's
#    404, a captive portal answering with its own 200 page) is stored forever and
#    poisons every later launch until the next release bumps the cache version.
# itch.io build: none of that (no service worker), but checks that nothing of the PWA
# shipped and that the pck carries the "itch" feature tag, its own save database, and
# itch's upload limits. Both builds get step 5, the index.html injection.
OUT="$OUT" MODE="$MODE" python3 - <<'EOF'
import json
import os
import pathlib
import re
import struct
import zipfile

out = pathlib.Path(os.environ["OUT"])
itch = os.environ["MODE"] == "itch"
project = pathlib.Path("project.godot").read_text()

engine_files = sorted(
    p.name for p in pathlib.Path("web/engine").iterdir() if p.suffix in (".js", ".wasm"))
assert engine_files, "web/engine/ has no engine files"
for name in engine_files:
    assert (out / name).exists(), \
        f"{name} not in {out} — web_export_plugin.gd failed?"

html = out / "index.html"
page = html.read_text()

if not itch:
    sw = out / "index.service.worker.js"
    src = sw.read_text()

    extra = engine_files + ["index.png"]
    inject = "".join(json.dumps(n) + "," for n in extra)
    src, n = re.subn(r"(const CACHEABLE_FILES = \[)", lambda m: m.group(1) + inject, src, count=1)
    assert n == 1, "CACHEABLE_FILES not found — did the Godot web template change?"
    print(f"service worker: added to CACHEABLE_FILES: {', '.join(extra)}")

    plain = "let cached = await cache.match(event.request);"
    mapped = (
        "const scopePath = new URL(self.registration.scope).pathname; "
        "const navPath = new URL(event.request.url).pathname; "
        "let cached = await cache.match("
        "navPath === scopePath ? CACHED_FILES[0] : event.request, { ignoreSearch: true });")
    assert plain in src, "cache.match line not found — did the Godot web template change?"
    src = src.replace(plain, mapped, 1)
    print("service worker: scope-root navigations mapped to index.html (query-safe)")

    put_plain = "if (isCacheable) {"
    put_guarded = "if (isCacheable && response.ok) {"
    assert put_plain in src, "cache.put guard not found — did the Godot web template change?"
    src = src.replace(put_plain, put_guarded, 1)
    print("service worker: only OK responses are cached")

    # 4. Network-first for navigations (the HTML shell only; everything else stays
    #    cache-first). The stock worker returns the cached index.html without ever
    #    consulting the network once the cache is complete, and the only thing that
    #    promotes a newly installed worker out of "waiting" is the 'update' message
    #    posted by GameManager._check_web_update() — from inside the running game.
    #    So a device where the game fails to boot can never receive the fix that
    #    would make it boot, and one bad deploy strands those users permanently.
    #    A short timeout keeps offline and flaky-network launches instant.
    anchor = "// Check if we have full cache during HTML page request."
    assert anchor in src, "navigate branch not found — did the Godot web template change?"
    line = next(ln for ln in src.splitlines() if anchor in ln)
    pad = line[:len(line) - len(line.lstrip())]
    block = "\n".join(pad + ln if ln else "" for ln in [
        "// Network-first for the shell, falling back to the cached copy below.",
        "// Without this, a cached index.html that fails to boot is unfixable:",
        "// the running game is what promotes a waiting worker, so a device that",
        "// cannot start can never be updated. See build_web.sh patch 4.",
        "let fresh = null;",
        "try {",
        "\tfresh = await Promise.race([",
        "\t\tself.fetch(event.request.url, { cache: 'reload' }),",
        "\t\tnew Promise((resolve) => { setTimeout(() => resolve(null), 2500); }),",
        "\t]);",
        "} catch (e) {",
        "\tfresh = null;  // offline or blocked: the cache path below still launches",
        "}",
        "if (fresh != null && fresh.ok) {",
        "\tevent.waitUntil(cache.put(CACHED_FILES[0], fresh.clone()));",
        "\treturn fresh;",
        "}",
        "",
    ])
    src = src.replace(pad + anchor, block + pad + anchor, 1)
    print("service worker: navigations are network-first (2.5 s timeout, cache fallback)")

    sw.write_text(src)
else:
    # Nothing of the PWA may ship to itch: html-classic.itch.zone is every itch game's origin.
    for name in ("index.service.worker.js", "index.manifest.json", "index.offline.html"):
        assert not (out / name).exists(), \
            f"{name} in the itch.io build — is PWA off in the 'Web (itch)' preset?"
    assert 'rel="manifest"' not in page, "manifest link in the itch.io build"
    config_line = re.compile(r"^const GODOT_CONFIG = (\{.*\});$", re.M)
    found = config_line.findall(page)
    assert len(found) == 1, "GODOT_CONFIG line not found — did the Godot web template change?"
    config = json.loads(found[0])
    assert not config.get("serviceWorker"), "the itch.io build would register a service worker"

    # The pck must carry the "itch" feature tag that turns on Itch.on, or this zip is the
    # website build under another name (Lemon Squeezy and all). The preset's custom features
    # ride in the pck's project settings as a String: u32 size, u32 type 4, u32 length, bytes.
    pck = (out / "index.pck").read_bytes()
    key = b"_custom_features"
    at = pck.find(key)
    assert at >= 0, "no custom features in index.pck — is custom_features=\"itch\" set?"
    _size, vtype, length = struct.unpack_from("<III", pck, at + len(key))
    assert vtype == 4, "unexpected encoding of _custom_features — did Godot's format change?"
    start = at + len(key) + 12
    features = pck[start:start + length].decode()
    assert "itch" in features.split(","), f"index.pck carries custom features {features!r}, not itch"
    print(f"index.pck: custom features {features!r}")

    # Its own save database. Every Godot game on itch shares the IndexedDB database "/userfs",
    # and Emscripten's sync deletes or rewinds the files a game does not hold in memory, so a
    # second Godot game open in another tab could roll back or delete our save. IDBFS names a
    # database after its mount point: mounting the user folder itself gives it one of its own.
    # GameManager's tab re-read reads the name back from GODOT_CONFIG.
    name = re.search(r'^config/name="([^"]*)"$', project, re.M).group(1)
    assert re.fullmatch(r"[A-Za-z0-9 _-]+", name), \
        f"config/name {name!r}: make sure Godot's user folder still has this exact name"
    assert "use_custom_user_dir=true" not in project, "a custom user dir moves the save folder"
    user_dir = f"/userfs/godot/app_userdata/{name}"
    config["persistentPaths"] = [user_dir]
    page = config_line.sub(
        lambda m: "const GODOT_CONFIG = " + json.dumps(config, separators=(",", ":")) + ";",
        page, count=1)
    print(f"index.html: the save lives in its own IndexedDB database, {user_dir!r}")

# 5. Inline web/boot_diagnostics.js into <head>, ahead of index.js, so it is already
#    listening when the engine boots. Inlined rather than shipped as a file so it needs
#    no service-worker cache entry and can never itself 404 offline. See its header for
#    why: a stalled iOS boot leaves nothing in the DOM to report, and there is no Apple
#    device here to reproduce on.
diag = pathlib.Path("web/boot_diagnostics.js").read_text()
assert "</head>" in page, "no </head> in the export — did the Godot web template change?"
assert "limpid:boot_diagnostics" in diag, "marker missing from web/boot_diagnostics.js"
assert "limpid:boot_diagnostics" not in page, "boot diagnostics already injected"
if itch:
    # The itch.io build never touches the origin's service workers or caches, and its reset
    # downloads these again instead (see boot_diagnostics.js, ITCH).
    own = sorted(p.name for p in out.iterdir() if p.suffix in (".js", ".wasm", ".pck"))
    for placeholder, value in (("var ITCH = false;", "var ITCH = true;"),
                               ("var OWN_FILES = [];", f"var OWN_FILES = {json.dumps(own)};")):
        assert diag.count(placeholder) == 1, f"{placeholder!r} not found once in boot_diagnostics.js"
        diag = diag.replace(placeholder, value)
#    Same injection also hardens the canvas for iOS. Godot's stock shell puts
#    `touch-action: none` on <body> only, but the property is not inherited, and
#    Safari has let its gesture recognizer steal touch sequences from a canvas that
#    does not set it itself. A stolen sequence ends in touchcancel instead of
#    touchend, so a Godot button receives a press with no matching release and never
#    activates — which looks exactly like "the buttons do nothing".
# Standard game-canvas hygiene, each justified on its own merits. `touch-action` is
# not an inherited property, so the template setting it on <body> does not cover the
# canvas. The selection and callout rules stop a long press from selecting text or
# raising the iOS callout menu over the board.
# NOTE: cursor:pointer and transform:translateZ(0) were tried here as fixes for the
# iOS portrait freeze and did NOT work (see README). Removed rather than left behind,
# so a console session is not misled by leftover speculative CSS.
css = (
    "\t\t<style>\n"
    "#canvas {\n"
    "\ttouch-action: none;\n"
    "\t-webkit-user-select: none;\n"
    "\tuser-select: none;\n"
    "\t-webkit-touch-callout: none;\n"
    "}\n"
    "\t\t</style>\n")
notice = pathlib.Path("web/ios_canvas_notice.js").read_text()
assert "limpid:ios_canvas_notice" in notice, "marker missing from ios_canvas_notice.js"
assert "limpid:ios_canvas_notice" not in page, "notice already injected"
page = page.replace("</head>", css + "\t\t<script>\n" + diag + "\t\t</script>\n"
                    + "\t\t<script>\n" + notice + "\t\t</script>\n\t</head>", 1)
html.write_text(page)
print("index.html: canvas hardening + boot diagnostics + iOS canvas notice"
      + (" (itch-safe reset)" if itch else ""))

if itch:
    # itch's limits for an HTML5 upload (itch.io/docs/creators/html5): 1,000 files, 240
    # characters per path, 500 MB unpacked, 200 MB per file. We use about a tenth of them.
    files = sorted(p for p in out.rglob("*") if p.is_file())
    total = sum(p.stat().st_size for p in files)
    biggest = max(files, key=lambda p: p.stat().st_size)
    longest = max(len(p.relative_to(out).as_posix()) for p in files)
    assert len(files) <= 1000, f"{len(files)} files: itch allows 1,000"
    assert biggest.stat().st_size <= 200_000_000, f"{biggest.name} is over itch's 200 MB per file"
    assert total <= 500_000_000, f"{total} bytes: itch allows 500 MB unpacked"
    assert longest <= 240, f"a {longest}-character path: itch allows 240"
    version = re.search(r'^config/version="([^"]*)"$', project, re.M).group(1)
    for old in out.parent.glob("limpid-chess-itch-*.zip"):
        old.unlink()
    zip_path = out.parent / f"limpid-chess-itch-{version}.zip"
    # index.html at the root of the zip, as itch wants.
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in files:
            z.write(p, p.relative_to(out).as_posix())
    print(f"itch.io: {len(files)} files, {total / 1e6:.1f} MB unpacked "
          f"(largest {biggest.name}, {biggest.stat().st_size / 1e6:.1f} MB), "
          f"zip {zip_path.stat().st_size / 1e6:.1f} MB: {zip_path}")
    print("  upload the zip on the itch page (Kind of project: HTML, 'This file will be played")
    print("  in the browser'), or push the folder with butler instead:")
    print(f"    butler push {out} lone-bee/limpid-chess:html5 --userversion {version}")
    print("  One or the other per page: a butler channel and a hand-uploaded zip are two builds.")
EOF

if [[ "$MODE" == "deploy" ]]; then
	rm -rf docs/play
	mkdir -p docs/play
	cp build/web/index.* build/web/stockfish-* build/web/Copying.txt docs/play/
	echo "deployed to docs/play/ — commit to publish via GitHub Pages"
fi
echo "done: $OUT/"
