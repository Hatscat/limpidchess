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

## OPEN BUG: iOS Safari renders only in landscape (July 2026)

**Status: unsolved.** Android, desktop and *some* iPhones are fine. On affected iPhones
the game is unusable in portrait. Handoff doc for a session with a real Safari console.

### Symptom, stated precisely

It is **not** an input bug. Taps register, the tapped move plays its sound, and the game
state advances. What fails is **presentation**: the canvas keeps showing a stale frame.

- **Portrait: frozen.** Deterministic, every load, private tab or not, installed PWA or
  browser tab.
- **Landscape: works normally.**
- Rotating to landscape renders the pending state immediately (the move your friend
  played 20 s ago appears). Rotating back to portrait freezes again, every time.
- Rotating produces **exactly one correct frame**. A portrait screenshot taken after a
  rotation shows a correctly *portrait-laid-out* scene, so the engine does re-run layout
  and render for portrait dimensions. It simply never renders again after that.

### Confirmed by measurement, on a frozen portrait screen

| | Reading |
|---|---|
| Device | iPhone, iOS 18.1.1, Safari 18.1.1, dpr 3 |
| Engine main loop | 56-60 fps (rAF callbacks from emscripten, counted separately from ours) |
| Canvas | `1170x1974`, CSS `390x658` at `@0,0` — exactly `window * dpr`, no offset |
| GL drawing buffer | `1170x1974 ok` — matches the canvas, **not** clamped |
| WebGL context | never lost (`webglcontextlost` never fires) |
| Touch | reaches the canvas element, `down N up N`, 0 cancels, 0 drift |
| Godot's own touch handler | runs on every tap (verified by wrapping it at registration) |
| Listeners | `touchstart/end/move/cancel` + `mousedown` bound to the canvas, never removed |
| Audio | `running` |
| Console | only `ERROR: Condition "!is_inside_tree()" ... at: can_process (node.cpp:902)`, **identical on working Android**, so benign |

Landscape for comparison: `window 750x304`, `canvas 2250x912 ok`, 60 fps. Nearly the same
total pixels as portrait; less than half the height.

### Ruled out by measurement, do not re-investigate

1. **Canvas/viewport offset** — canvas is exactly `window * dpr` at origin; `visualViewport`
   matches the layout viewport with `offsetTop 0`.
2. **Storage quota** — 91 MB used of a 39 GB quota.
3. **Memory pressure / WebGL context loss** — context never lost, engine never stalls.
4. **`touch-action` gesture stealing** — 0 `touchcancel`, 0 drift; adding
   `touch-action:none` to the canvas changed nothing.
5. **Missing synthesized mouse events** — `cursor:pointer` changed nothing.
6. **Listener teardown** — `removeEventListener` on the canvas is never called, on either
   platform.
7. **Service worker / cache / stale pck** — private browsing runs no service worker and
   fails identically, 3 of 3.
8. **Safari browser chrome** — the installed standalone PWA fails the same way.
9. **Compositing-layer promotion** — `transform: translateZ(0)` changed nothing.
10. **Forcing a re-composite** — periodic `getBoundingClientRect`, `storage.estimate`,
    opacity toggling, DOM writes, a bare timer, and dirtying `canvas.style.height` by a
    half pixel: none of them unfreeze it.

### The mechanism, as far as it is understood

Godot polls the canvas size every frame from C++ via `_godot_js_display_size_update()`,
which calls `GodotDisplayScreen.updateSize()` in `index.js`. That function only touches
the canvas when the size actually changed:

```js
if (canvas.style.width !== csw || ... || canvas.height !== height) {
    canvas.width = width; canvas.height = height;
    canvas.style.width = csw; canvas.style.height = csh;
    GodotDisplayScreen._updateGL();
    return 1
}
return 0
```

Rotation changes `window.innerWidth/innerHeight`, that branch fires, and one good frame
reaches the screen. Held in portrait it returns 0 forever. **Why the normal per-frame
render path presents in landscape but not in portrait is the open question.**

Note that dirtying `canvas.style.height` by hand should also make that branch fire, and it
did not help. So either that is not the operative difference, or the branch is not what
actually unfreezes the screen on rotation.

### Reproducing

Affected iPhone, `https://limpidchess.com/play/`, portrait, do not rotate. Add `?debug=1`
for the live panel (frame rates, canvas and GL sizes, tap counts, last error). `?reset=1`
wipes the service worker and caches.

Note: 1 of 3 iPhones tested was never affected, so device or iOS build matters.

### What to try with a console attached

- Whether Godot's per-frame `RenderingServer` draw is actually running in portrait, or
  whether the engine skips drawing while still iterating the main loop at 56 fps.
- `gl.getError()` and framebuffer completeness after a frame, in both orientations.
- Whether the canvas is composited at all in portrait (Safari's Layers/Timelines panel).
- Whether a Godot build with `stretch/aspect` other than `expand`, or a smaller canvas
  (hidpi off), changes anything: portrait is 1974px tall against 912 in landscape, and
  height is the one dimension that differs sharply between working and broken.

### Methodology notes, learned the hard way

- **Every test round must re-run a known-good control in the same build.** Several
  conclusions were invalidated because "?debug=1 works" was measured on an older deploy.
- **Confirm exactly what the tester did.** A whole evening was lost because the tester was
  rotating the device between attempts without mentioning it, which made a deterministic
  bug look intermittent.
- Single trials are worthless against a bug you believe may be flaky. Repeat, and count.

## boot_diagnostics.js — making iOS failures visible

Inlined into `<head>` of the exported `index.html` by `build_web.sh` (step 5), ahead of
`index.js`. Inlined rather than shipped as a file so it needs no service-worker cache
entry and can never 404 offline. It only adds **passive** listeners and never calls
`preventDefault`/`stopPropagation`, so it cannot alter how input reaches the canvas.

| URL | Behavior |
|---|---|
| `/play/` | Watchdog only. After 40 s stalled, a panel appears with diagnostics and a **Reset and reload** button (unregisters the service worker, deletes every cache, reloads clean). |
| `/play/?debug=1` | Live pass-through panel: browser vs engine frame rate, window and canvas size, GL drawing-buffer size, tap counts, last error. Capped at 33% height with `pointer-events:none` so it never blocks the game. |
| `/play/?reset=1` | Wipes service worker + caches immediately, then boots clean. Sendable to anyone stuck. |

It also mirrors `console.error`/`console.warn` into the panel, since Godot prints its own
failures to a console nobody can open on a phone, and promotes a service worker stuck in
`waiting` (see the network-first section above).

**Keep this file.** It is what turns "it's broken" from a phone user into an actionable
report, and the reset path is the only remote recovery for a device with a bad cache.

Removed after they answered their question, and listed so nobody rebuilds them: an
`addEventListener` tally with an engine-handler invocation counter, a `removeEventListener`
counter, an `AudioContext` state probe, a `gl.readPixels` frame-difference sampler, and a
family of `?d=` experiment modes. The pixel sampler in particular is worth *not* bringing
back casually: `readPixels` forces a GPU sync every call, and it could not distinguish a
frozen screen from a static one anyway.

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
