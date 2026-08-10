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

## OPEN BUG: iOS never presents canvas content (August 2026)

**Status: unsolved, and believed to be a WebKit bug.** Android, desktop and *some* iPhones
are fine. On an affected iPhone the web build is unusable. A ready-to-file report is in
[WEBKIT_BUG.md](WEBKIT_BUG.md).

### Symptom, stated precisely

Confirmed in person on an **iPhone 13**, in **Safari and Chrome alike** (both are WebKit),
in **both orientations**:

- The game is frozen on screen. The engine is not: input registers, taps play their sound,
  the game state advances, and the correct frame is composited every frame.
- **Rotating the device presents exactly ONE frame.** You can play the game by rotating
  after every move. Nothing else advances the display.

An earlier remote diagnosis of "portrait freezes, landscape works" was **wrong**, and the
mistake is instructive: in landscape Safari's toolbar auto-hides and reappears as you
interact, resizing the viewport repeatedly, and each of those resizes presented a frame.
Portrait's toolbar is stable, so nothing fired. Only watching it in person exposed that.

### Confirmed by measurement, on a frozen screen

| | Reading |
|---|---|
| Device | iPhone 13, iOS 18.x, dpr 3. Safari and Chrome both affected |
| Engine main loop | 56-60 fps (rAF callbacks from emscripten, counted separately from ours) |
| Draw calls | 767-6900/s, tracking real scene complexity: 22/frame on the menu, 39 after navigating, 115 with a board up |
| **Composites to screen** | **equals the frame rate** (`to-screen 59/s` at 59 fps) |
| Pixel readback | with `preserveDrawingBuffer: true`, the default framebuffer holds the *current* frame and changes exactly when the game navigates |
| Canvas | `1170x1974`, CSS `390x658` at `@0,0` — exactly `window * dpr`, no offset |
| GL drawing buffer | matches the canvas, never clamped |
| WebGL context | never lost; `gl.getError()` clean every frame |
| Touch | reaches the canvas, `down N up N`, 0 cancels; Godot's own handler runs on each |
| Audio | `running` |
| Console | only `ERROR: Condition "!is_inside_tree()" ... can_process (node.cpp:902)`, **identical on working Android**, so benign |

So the engine renders the correct frame, every frame, and the display never shows it.

### Ruled out by measurement, do not re-investigate

**Not the engine.** Godot composites to the default framebuffer at full frame rate and the
buffer provably holds the current scene.

**Not WebGL specifically.** A 2D canvas laid over the WebGL one, blitted 3306 times with
`drawImage`, does not display either (`?d=mirror`). Nor does a CPU-backed 2D canvas via
`willReadFrequently: true` (`?d=mirror2`).

**Not the canvas geometry.** Size is out: `devicePixelRatio` forced to 1 (canvas 390x658
instead of 1170x1974) still freezes. Aspect is out: a decisively landscape-shaped canvas
(1170x525, ratio 2.23) on a portrait-held phone still freezes.

**Not any WebGL context attribute.** `antialias` on/off, `preserveDrawingBuffer: true`,
`alpha: false`, `desynchronized: true`. Godot requests none of them, so browser defaults
apply (`aa=true preserve=false alpha=true`).

**Not compositor nudging.** `transform: translateZ(0)`, opacity toggling, a hidden element
running an infinite CSS animation, `gl.finish()` every frame, periodic
`getBoundingClientRect`, `storage.estimate`, DOM writes, a bare timer.

**Not the canvas CSS box.** Alternating `canvas.style.height` by 1px *every frame*, applied
after the engine's frame so it survives (1344 applications, logged): no effect.

**Not the backing store either.** Shrinking `canvas.width` before every engine frame so
Godot reallocates and re-renders inside that frame: no effect. This is the closest
synthetic analogue to a rotation and it still does not present.

**Not the service worker, cache, or a stale pck.** Private browsing runs no service worker
and fails identically, 3 of 3.

**Not Safari's browser chrome.** The installed standalone PWA fails the same way.

**Not `touch-action`, listener teardown, storage quota, memory pressure or context loss.**
All measured, all clean.

**Not an engine GL error.** A `glBlitFramebuffer` warning appears ~4 times at startup and
never again (steady state clean over 10 s), so it cannot explain a persistent freeze. Worth
reporting upstream anyway; the project has no shaders, no `BackBufferCopy` and no MSAA, so
nothing in the game asks for that blit. Compare
[PR #106267](https://github.com/godotengine/godot/pull/106267).

### The one thing that works, and why it cannot be faked

Godot polls the canvas size every frame via `_godot_js_display_size_update()`, which calls
`GodotDisplayScreen.updateSize()` and only touches the canvas when the size changed:

```js
if (canvas.style.width !== csw || ... || canvas.height !== height) {
    canvas.width = width; canvas.height = height;
    canvas.style.width = csw; canvas.style.height = csh;
    GodotDisplayScreen._updateGL();
    return 1
}
```

A rotation changes `window.innerWidth/innerHeight`, that branch fires, and one frame
reaches the screen. The event log captures it:

```
2.14s  geom 1170x1995 css 390px,665px win 390x665     portrait
6.36s  geom 2250x990  css 750px,330px win 750x330     after rotating
```

Every synthetic reproduction of that (CSS box, backing store, both, at up to 60 Hz) fails.
What we cannot fake from JavaScript is the **viewport itself** changing, which forces
WebKit to re-lay out and re-composite the whole page. That is the remaining candidate.

### Reproducing

Affected iPhone, the game, held still, no rotating. `?debug=1` gives the live panel;
`?log=1` POSTs it to [tools/lan_server.py](tools/lan_server.py) every 2 s; `?reset=1` wipes
the service worker and caches. The `geom` lines in the event log record every canvas and
window geometry change, which is what identified the rotation path.

1 of 3 iPhones tested was never affected, so device or iOS build matters.

**Do not put a tester through more experiments without a new hypothesis.** Roughly twenty
were tried; the list above is what they cost.

### One free question never answered

While the canvas is frozen, **does the diagnostics panel keep counting?** It is plain DOM
text updated once a second. If the DOM updates while no canvas does, the fault is specific
to composited canvas layers and the root layer is fine. If the DOM is frozen too, nothing
on the page presents and the scope is far larger. Ten seconds of looking, and it changes
what the bug report should say.

### What a real Safari console would still add

- Whether WebKit ever marks the canvas layer dirty (Layers / Timelines panel). No
  page-level probe can see this, and it is now the only open question.
- Whether a **minimal WebGL page** (a spinning triangle, no Godot) reproduces it on the
  same device. If it does, this is a clean WebKit bug with no Godot involved, and that is
  the single most valuable thing anyone could add to the report.

### Shipped mitigation: web/ios_canvas_notice.js

The bug is unsolved and every JS-reachable lever is exhausted, so the build ships an honest
message rather than a fix. It cannot detect the fault (the framebuffer updates correctly,
so nothing distinguishes an affected iPhone from a healthy one) and only some devices are
affected, so it triggers on **behaviour**: six taps within eight seconds, clustered inside
60 px. That is what a frozen screen feels like from the player's side, and clustering is
what stops a fast Puzzles player triggering it.

It replaced an earlier "turn your phone sideways" hint, which was actively wrong: rotating
presents one frame, so anyone following it got a slideshow. The current text says the
browser is at fault, not their phone, and points at desktop or Android.

### Methodology notes, learned the hard way

- **Verify the experiment ran.** Two experiments were silently broken by their own code
  (one overwrote its CSS animation with `none`; one applied its change before the engine
  frame so Godot reverted it in the same frame) and both were recorded as negative results.
  The panel now reports the active mode and an application count for exactly this reason.
- **Re-run a known-good control in the same build.** Several conclusions were invalidated
  because "?debug=1 works" had been measured on an older deploy.
- **Confirm what the tester actually did.** A whole evening was lost because the tester was
  rotating between attempts without mentioning it, which made a deterministic bug look
  intermittent, and weeks were lost to "landscape works", which was an artifact of Safari's
  toolbar resizing the viewport.
- **Watch it in person if you possibly can.** Ten minutes with the device disproved the
  central assumption of the whole remote investigation.

### A separate failure mode: corrupted wasm download

Distinct from the portrait freeze, and the likely explanation for "stuck on the loading
bar forever". Symptom, visible in the diagnostics panel:

```
err rejection: WebAssembly.Module doesn't parse at byte 101: invalid opcode
started false    canvas 300x150    engine 0fps
```

That is **not** a feature gap or a bad build. Byte 101 of both `index.wasm` and
`stockfish-18-lite-single.wasm` is `0x7f` (i32) inside the type section, both validate
under `WebAssembly.validate`, and the served copy is byte-identical to the deployed one.
The browser parsed something other than what we serve, i.e. the transfer was corrupted.

Seen reliably through BrowserStack Live's proxy, which mangles the ~9.5 MB gzipped wasm.
**BrowserStack Live is therefore a poor tool for this app** — the payload rarely arrives
intact. Prefer Safari Web Inspector over USB from any Mac, against the real device.

The same thing can happen to a real user on a flaky mobile connection, and the service
worker will happily cache a corrupt-but-`200` response. That is what the boot watchdog and
`?reset=1` exist for: after 40 s stalled, the panel offers **Reset and reload**, which
wipes caches and refetches. Keep both.

## tools/webkit_check.mjs — running the build in WebKit locally

Loads the exported build in Playwright's WebKit (same engine family as Safari, and the
closest thing to an iPhone that runs on Linux), taps the canvas, checks whether the frame
changed, and reports WebGL errors **bucketed by rate**. Rate is the point: a per-frame
message sits on the render path, a handful at startup does not.

It does not reproduce the iOS portrait freeze. It is still worth keeping, because it is
the only way to see engine-level WebGL errors at all, and it turns "change a setting and
ask a friend" into a one-minute local loop.

```bash
# once, deliberately outside the repo so no node_modules lands in a Godot project
mkdir -p /tmp/pwtest && cd /tmp/pwtest && npm init -y && npm install playwright
npx playwright install webkit

# run
cd build/web && python3 -m http.server 8099 &
env -u LD_LIBRARY_PATH -u GTK_PATH -u GIO_MODULE_DIR PW_DIR=/tmp/pwtest \
  node web/tools/webkit_check.mjs
```

**The `env -u` is not optional.** VS Code's snap leaks `GIO_MODULE_DIR` and friends into
child processes, dragging a 2020-era glibc into WebKit's network process, and every
navigation dies with `WebKit encountered an internal error`. The real message only shows
up under `DEBUG=pw:browser`:

```
WPENetworkProcess: symbol lookup error: /snap/core20/current/lib/x86_64-linux-gnu/
libpthread.so.0: undefined symbol: __libc_pthread_init, version GLIBC_PRIVATE
```

Same class of snap leak that `build_web.sh` already works around for `XDG_DATA_HOME`.
Expect it from any browser tooling launched out of the editor.

## tools/lan_server.py — testing on a real iPhone with no Mac

For a tester who is physically present. Serves the exported build over the LAN and prints
whatever the page posts back, so readings land in your terminal instead of being squinted
at through a screenshot.

```bash
python3 web/tools/lan_server.py            # serves build/web on :8099
# prints:  on the phone:  http://192.168.x.x:8099/?debug=1&log=1
```

`?log=1` makes the page POST its diagnostics panel to `/__log` every 2 s. Same origin, so
no CORS and nothing to configure: whoever serves the page collects the log.

The real win is the loop. Rebuild with `web/build_web.sh` (no `--deploy`), the phone
reloads, done: no commit, no push, no waiting on GitHub Pages, no service-worker cache to
fight (plain HTTP is an insecure origin, so the worker never registers — a feature here).
Ten experiments in the time one remote round trip used to take.

Debugging iOS from Linux directly is possible but unreliable: `ios-webkit-debug-proxy` is
not packaged in apt and predates iOS 17's RemoteXPC transport. `pymobiledevice3` (pip)
does support iOS 17/18 and has `webinspector` subcommands, but needs a root-started tunnel
and is fiddly. Try it if you like; do not build the session around it.

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

The **`glerr`** line is the important one. Browsers emit WebGL errors through internal
logging, not through `console.error`, so no page hook can see them and a phone has no
console — that blind spot is what stalled the iOS investigation for days. But
`canvas.getContext('webgl2')` returns the very context Godot created, and `getError()`
reports and clears one flag per call, so draining it right after the engine's own frame
callback surfaces engine-level GL errors on a real device with no inspector attached.
Note this consumes errors Godot might otherwise check itself; fine for a diagnostic build.

The **`gl`** line re-reads the drawing buffer whenever the canvas is resized rather than
once, because a single early read captures the untouched 300x150 default and caches it
forever. Keying on size also re-checks after each rotation, which is exactly when a clamp
would show up.

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
