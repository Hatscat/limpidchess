#!/usr/bin/env bash
# Export the Web/PWA build, patch the service worker cache list, optionally deploy.
#
#   web/build_web.sh            # export + patch into build/web/
#   web/build_web.sh --deploy   # ...then copy the build into docs/play/ (GitHub Pages)
#
# Every release MUST go through a full re-export: the PWA cache version is stamped
# at export time, so swapping single files under an old export leaves players on
# the cached previous version forever.
set -euo pipefail
cd "$(dirname "$0")/.."

# The VS Code snap leaks a snap-scoped XDG_DATA_HOME; Godot then can't find its
# export templates. Point it back at the real one when that happens.
if [[ "${XDG_DATA_HOME:-}" == *"/snap/"* ]]; then
	export XDG_DATA_HOME="$HOME/.local/share"
fi

# Always a clean full export: stale files from previous exports must never ride
# along (the --deploy globs would sweep them into docs/play and mask failures).
# Godot needs the target folder to exist, so recreate it after the wipe.
rm -rf build/web
mkdir -p build/web
# Keep the editor from importing exported artifacts back in as project resources.
touch build/.gdignore

godot --headless --path . --export-release "Web" build/web/index.html

# Patch the generated service worker (all verified against the 4.6.3 template; every
# patch asserts loudly if the template ever changes shape):
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
python3 - <<'EOF'
import json
import pathlib
import re

engine_files = sorted(
    p.name for p in pathlib.Path("web/engine").iterdir() if p.suffix in (".js", ".wasm"))
assert engine_files, "web/engine/ has no engine files"
for name in engine_files:
    assert pathlib.Path("build/web", name).exists(), \
        f"{name} not in build/web — web_export_plugin.gd failed?"

sw = pathlib.Path("build/web/index.service.worker.js")
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

# 5. Inline web/boot_diagnostics.js into <head>, ahead of index.js, so it is already
#    listening when the engine boots. Inlined rather than shipped as a file so it needs
#    no service-worker cache entry and can never itself 404 offline. See its header for
#    why: a stalled iOS boot leaves nothing in the DOM to report, and there is no Apple
#    device here to reproduce on.
html = pathlib.Path("build/web/index.html")
page = html.read_text()
diag = pathlib.Path("web/boot_diagnostics.js").read_text()
assert "</head>" in page, "no </head> in the export — did the Godot web template change?"
assert "limpid:boot_diagnostics" in diag, "marker missing from web/boot_diagnostics.js"
assert "limpid:boot_diagnostics" not in page, "boot diagnostics already injected"
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
notice = pathlib.Path("web/ios_portrait_notice.js").read_text()
assert "limpid:ios_portrait_notice" in notice, "marker missing from ios_portrait_notice.js"
assert "limpid:ios_portrait_notice" not in page, "notice already injected"
page = page.replace("</head>", css + "\t\t<script>\n" + diag + "\t\t</script>\n"
                    + "\t\t<script>\n" + notice + "\t\t</script>\n\t</head>", 1)
html.write_text(page)
print("index.html: canvas hardening + boot diagnostics + iOS portrait notice")
EOF

if [[ "${1:-}" == "--deploy" ]]; then
	rm -rf docs/play
	mkdir -p docs/play
	cp build/web/index.* build/web/stockfish-* build/web/Copying.txt docs/play/
	echo "deployed to docs/play/ — commit to publish via GitHub Pages"
fi
echo "done: build/web/"
