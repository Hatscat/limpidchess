# Web page assets (not Godot resources)

This folder carries files that must ship **beside** the exported `index.html`, not
inside the pck. The whole folder is `.gdignore`d; on a Web export the
`limpid_export` plugin copies `engine/*` into the export directory
(see `addons/limpid_export/web_export_plugin.gd`).

## Service worker: navigations are network-first

`build_web.sh` patch 4 makes **navigations only** network-first, with a 2.5 s timeout and
the cached shell as fallback. Everything else stays cache-first, and offline still
launches from cache.

This is a safety valve, not a performance choice. The stock worker returns the cached
`index.html` without ever consulting the network once the cache is complete, and the only
thing that promotes a newly installed worker out of `waiting` is the `'update'` message
posted by `GameManager._check_web_update()` — from inside the running game. So a device
where the game fails to boot can never receive the fix that would make it boot, and a
single bad deploy strands those users permanently, with no remote way to reach them.
Costs one ~4 KB request per online launch. Do not revert it to save that request.

## The iOS input freeze (July 2026): what it was not, and what it probably was

iOS Safari showed a total input freeze on some iPhones while Android and other iPhones
were fine: the game rendered, the engine ticked at 60 fps, taps reached the canvas and
completed cleanly (`down N up N CANCEL 0`), Godot's touch handlers were registered *and
ran*, audio ran, focus was correct. Every browser-level probe was healthy, because the
browser genuinely was healthy.

**Ruled out by measurement**, in order: canvas/viewport offset, storage quota exhaustion,
memory pressure and WebGL context loss, `touch-action` gesture stealing, missing mouse
synthesis (`cursor: pointer`), and listener teardown (`removeEL` reads `none` on both
platforms, so nothing removes Godot's handlers).

**Leading explanation: service-worker version skew.** Patch 4 makes `index.html`
network-first, but `index.pck` and `index.wasm` stay cache-first. A newly installed
worker sits in `waiting` until something promotes it, so the page shell can be brand new
while the game data it loads is still the previous build's — or a bad first fetch that
got cached. That is invisible to every probe above and matches every symptom, including
why only some devices were hit and why `sw: controlled` was the single line that ever
differed between a broken iPhone and a working Android.

`boot_diagnostics.js` now reports `sw state` and lists cache versions (two caches = skew),
and promotes a held-back worker itself via the `'claim'` message. It uses `'claim'` rather
than `'update'` deliberately: it activates the new worker without navigating clients, so
it cannot interrupt a game in another tab. `GameManager._check_web_update()` only promotes
when it is the sole tab and online, which strands a worker indefinitely for anyone
browsing with other tabs open.

## boot_diagnostics.js — making iOS failures visible

Inlined into `<head>` of the exported `index.html` by `build_web.sh` (step 4), ahead of
`index.js`. Inlined rather than shipped as a file so it needs no service-worker cache
entry and can never 404 offline. It only adds **passive capture** listeners and never
calls `preventDefault`/`stopPropagation`, so it cannot alter how input reaches the canvas.

Godot's stock shell only reports *thrown* errors. The two iOS failures reported from the
field produce nothing in the DOM at all: a tab killed mid-wasm-compile just sits at a
full progress bar, and a poisoned service-worker cache survives every refresh. There is
no Apple device on this box, so the only way forward is to instrument.

| URL | Behavior |
|---|---|
| `/play/` | Watchdog only. After 40 s stalled, shows a panel with diagnostics and a **Reset and reload** button (unregisters the service worker, deletes every cache, reloads clean). |
| `/play/?debug=1` | Live pass-through overlay from boot: UA, window vs `visualViewport`, canvas pixel size vs CSS rect vs offset, a tap counter with last coordinates, storage usage/quota, service-worker control, captured errors. |
| `/play/?reset=1` | Wipes service worker + caches immediately, then boots clean. Sendable to anyone stuck. |

Reading the `?debug=1` dump: if **touches** increments but the game does not respond, the
taps reach the page and the problem is coordinate mapping, so compare the `canvas` line
(pixel size, CSS size, offset) against `window`/`visual`. If **touches** stays at 0, the
events never reach the page at all. If `storage` sits near its quota, the ~47 MB of
cacheable files is being evicted, which points at the payload rather than the code.

## engine/ — Stockfish for the browser

`stockfish-18-lite-single.js` + `.wasm`: Stockfish 18, "lite" NNUE net,
**single-threaded** WebAssembly build. Runs in a plain Web Worker: no
SharedArrayBuffer, no COOP/COEP headers, works on GitHub Pages and iOS Safari.
The `js` transport in [`stockfish_engine.gd`](../scripts/chess/stockfish_engine.gd)
spawns it via JavaScriptBridge. The `.js` wrapper resolves its `.wasm` by the same
basename, so the two filenames must stay in sync.

- Source: the `stockfish` npm package v18.0.8 (`package/bin/`),
  built from https://github.com/nmrugg/stockfish.js (maintained for Chess.com).
- License: GPL-3.0 (`Copying.txt`, kept beside the binaries and copied into the
  export). Same license as the game; the play page must keep the visible
  "Source & licenses" link, which also covers this engine.
- Updating: grab the new `-lite-single` pair from the npm tarball
  (`https://registry.npmjs.org/stockfish/-/stockfish-<version>.tgz`), keep the
  same-basename rule, and update `JS_ENGINE` in `stockfish_engine.gd` plus this
  note. Re-run the node benchmark (see PWA_PLAN.md phase 1) after an update.
