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

mkdir -p build
# Keep the editor from importing exported artifacts back in as project resources.
touch build/.gdignore

godot --headless --path . --export-release "Web" build/web/index.html

# Patch the generated service worker (both fixes verified against the 4.6.3 template):
# 1. Add the browser Stockfish files to the cache-on-first-fetch list: Godot's worker
#    only knows its own exports, and an offline relaunch would otherwise silently
#    lose the engine (the game would fall back to the GDScript bot).
# 2. Map directory-URL navigations ("/", "/play/") to the cached index.html: the
#    template caches under the relative name only, so an offline visit to the bare
#    directory URL misses the cache, hits the dead network, and shows the browser
#    error page instead of the cached game.
python3 - <<'EOF'
import re
import pathlib

sw = pathlib.Path("build/web/index.service.worker.js")
src = sw.read_text()

engine = '"stockfish-18-lite-single.js","stockfish-18-lite-single.wasm",'
if "stockfish-18-lite-single" not in src:
    src, n = re.subn(r"(const CACHEABLE_FILES = \[)", r"\1" + engine, src, count=1)
    assert n == 1, "CACHEABLE_FILES not found — did the Godot web template change?"
    print("service worker: engine files added to CACHEABLE_FILES")

plain = "let cached = await cache.match(event.request);"
mapped = ("let cached = await cache.match("
          "event.request.url.endsWith('/') ? CACHED_FILES[0] : event.request);")
if mapped not in src:
    assert plain in src, "cache.match line not found — did the Godot web template change?"
    src = src.replace(plain, mapped, 1)
    print("service worker: directory-URL navigations mapped to index.html")

pathlib.Path(sw).write_text(src)
EOF

if [[ "${1:-}" == "--deploy" ]]; then
	rm -rf docs/play
	mkdir -p docs/play
	cp build/web/index.* build/web/stockfish-* build/web/Copying.txt docs/play/
	echo "deployed to docs/play/ — commit to publish via GitHub Pages"
fi
echo "done: build/web/"
