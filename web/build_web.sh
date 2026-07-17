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

sw.write_text(src)
EOF

if [[ "${1:-}" == "--deploy" ]]; then
	rm -rf docs/play
	mkdir -p docs/play
	cp build/web/index.* build/web/stockfish-* build/web/Copying.txt docs/play/
	echo "deployed to docs/play/ — commit to publish via GitHub Pages"
fi
echo "done: build/web/"
