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
11. **Canvas backing-store height** — `?d=lowdpi` overrides `devicePixelRatio` to 1, so
    portrait renders at `390x658` instead of `1170x1974`. Still frozen, so the 1974px
    height (the one large asymmetry against landscape's 912px) is not the trigger.
12. **WebKit itself** — Playwright's WebKit 26.5 on Linux, at the same viewport and dpr,
    repaints normally in *both* orientations (see the harness below). Whatever iOS does
    here, desktop WebKit does not share it.
13. **Engine render-path GL errors** — the harness catches
    `glBlitFramebuffer: Read and write color attachments cannot be the same image` from
    Godot's Compatibility renderer, but only ~4 times during startup; steady state is
    clean over 10 s. A real engine bug worth reporting upstream (compare
    [PR #106267](https://github.com/godotengine/godot/pull/106267), which replaced the
    final blit-to-screen with a shader copy in 4.5), but it stops after boot and so
    cannot explain a freeze that persists. Note the project has no shaders, no
    `BackBufferCopy` and no MSAA, so nothing in the game asks for that blit.

14. **Canvas aspect ratio** — `?d=wide` (canvas 1170x1053, ratio 1.11) and `?d=squat`
    (1170x525, ratio 2.23) both give a portrait-held phone a decisively landscape-shaped
    canvas. Both still freeze. So it is not the canvas geometry at all: **the trigger is
    the physical device orientation**, independent of anything about the canvas.
15. **Every WebGL context attribute reachable from JS** — `antialias` on/off,
    `preserveDrawingBuffer: true`, `alpha: false`, `desynchronized: true`; plus
    `gl.finish()` after every frame and a forced backing-store realloc 10x/s
    (`?d=resize`, which mimics what a rotation does). None of them present the frame.

Worth knowing: browsers emit WebGL errors through internal logging, **not** through the
page's `console.error`. That blind spot is now closed on-device by the `glerr` line in
`boot_diagnostics.js`, which drains `gl.getError()` on Godot's own context every frame.

### SOLVED HALF: Godot is innocent, WebKit is not presenting

Measured on a frozen portrait iPhone, `?debug=1`:

```
before taps:   raf 56 / engine 56fps   DRAW 1232/s   to-screen 56/s   blit 0/s
after 9 taps:  raf 57 / engine 57fps   DRAW 2216/s   to-screen 57/s   blit 0/s
```

`to-screen` **equals the frame rate**. Godot composites to the default framebuffer 56
times a second on a screen that looks dead. The draw count nearly doubles after tapping,
because the game really did navigate and build a heavier scene, and rendered it, while the
display still showed the previous screen.

**So the engine draws every frame and WebKit never presents the buffer.** Nothing is
fixable engine-side; what is needed is a workaround that makes WebKit present.

Godot requests **no context attributes at all** (`attrs (defaults)`), so the browser
defaults apply — notably `antialias: true`, which makes the default framebuffer
multisampled and requires a resolve at present time, and `preserveDrawingBuffer: false`,
which lets WebKit discard the buffer after compositing.

`boot_diagnostics.js` patches `HTMLCanvasElement.prototype.getContext` in `<head>`, before
Godot creates its context, so those attributes can be overridden from the URL. Test in
portrait, without rotating, most promising first:

| URL | Override | Why |
|---|---|---|
| `?d=noaa` | `antialias: false` | No multisample resolve on a 1170x1974 default framebuffer. Landscape's is less than half as tall and works. |
| `?d=preserve` | `preserveDrawingBuffer: true` | Stops WebKit discarding the buffer after compositing. The classic fix for a canvas that will not update. |
| `?d=noalpha` | `alpha: false` | Removes the alpha channel from the compositing path. |

Whichever unfreezes it becomes the permanent fix, applied to the real context creation
instead of a URL flag. Note the probe targets only the canvas with `id="canvas"`: Godot's
shell feature-detects WebGL2 on a throwaway canvas first, and recording that one reports
`(defaults)` regardless of what the engine asks for.

### Earlier measurement: the DRAW line

`boot_diagnostics.js` instruments `WebGL2RenderingContext.prototype` before Godot ever
calls `getContext`, counting draw calls per second and, separately, those issued while the
DRAW framebuffer binding is `null` — i.e. straight to the default framebuffer, which is
what actually reaches the display.

Healthy baseline, measured in Playwright WebKit where rendering works:

```
PORTRAIT   DRAW 449/s  to-screen 20/s  blit 0/s     (at 20 fps)
LANDSCAPE  DRAW 391/s  to-screen 18/s  blit 0/s     (at 18 fps)
```

Roughly 400 draws into offscreen buffers, then **exactly one composite per frame** to the
default framebuffer. On a frozen iPhone in portrait, that single number decides it:

| `to-screen` on frozen portrait | Meaning | Where the fix lives |
|---|---|---|
| ~0/s while `DRAW` stays high | Godot renders offscreen and never composites | Godot / engine-side |
| matches the frame rate (~56/s) | Godot composites every frame, Safari never presents it | WebKit compositor; needs a workaround, not a fix |

Everything else is already excluded, so this is the fork the whole investigation reduces
to. Get this reading before spending anything on a console session.

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
- Framebuffer completeness after a frame, in both orientations. (Raw `gl.getError()` is
  already reported on-device by the `glerr` panel line, so check that first — it may make
  the console session unnecessary.)
- Whether the canvas is composited at all in portrait (Safari's Layers/Timelines panel).
- Whether a Godot build with `stretch/aspect` other than `expand` changes anything.
  (Canvas size itself is already excluded: `?d=lowdpi` shrinks portrait to 390x658 and it
  still freezes.)
- Report the startup `glBlitFramebuffer` error upstream while you are in there. It is not
  the cause, but the Compatibility renderer should not be emitting it on WebGL.

### Shipped mitigation: web/ios_portrait_notice.js

The bug is unsolved and every JS-reachable lever is exhausted, so the build ships a
behavioural hint instead. Injected into `<head>` by `build_web.sh` alongside the
diagnostics.

It cannot detect the fault: the framebuffer updates correctly, so nothing readable from
the page distinguishes an affected iPhone from a healthy one, and only some are affected.
A blanket "rotate your phone" banner would be wrong for everyone else.

So it triggers on **behaviour**: six taps within eight seconds, on iOS, in portrait. That
is what a frozen screen feels like from the player's side, and someone whose screen is
responding does not do it. Then a dismissible card (EN/FR/ES, following `navigator.language`)
suggests turning the phone sideways. Dismissal is remembered for the session, and rotating
clears it automatically.

Verified: absent on load, appears after six taps, correct language. Delete this file and
its injection in `build_web.sh` once the underlying bug is fixed.

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

### Methodology notes, learned the hard way

- **Every test round must re-run a known-good control in the same build.** Several
  conclusions were invalidated because "?debug=1 works" was measured on an older deploy.
- **Confirm exactly what the tester did.** A whole evening was lost because the tester was
  rotating the device between attempts without mentioning it, which made a deterministic
  bug look intermittent.
- Single trials are worthless against a bug you believe may be flaky. Repeat, and count.

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
