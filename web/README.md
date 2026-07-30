# Web page assets (not Godot resources)

This folder carries files that must ship **beside** the exported `index.html`, not
inside the pck. The whole folder is `.gdignore`d; on a Web export the
`limpid_export` plugin copies `engine/*` into the export directory
(see `addons/limpid_export/web_export_plugin.gd`).

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
