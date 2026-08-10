# WebKit bug report (draft)

Ready to file at <https://bugs.webkit.org> (component: WebKit / Layout and Rendering, or
Canvas). Also worth sending via Feedback Assistant, since that route reaches Apple's iOS
team directly.

Read `README.md`, "OPEN BUG", for the full investigation. This file is the report itself.

---

**Title:** iOS: canvas content is never presented until the viewport changes; WebGL and 2D
canvas both affected

**Product:** WebKit · **Component:** Layout and Rendering · **Platform:** iOS

## Summary

On some iPhones, canvas content is never presented to the screen. The page renders
correctly, every frame, and the display keeps showing a stale frame indefinitely. Changing
the viewport (rotating the device) presents exactly **one** frame, after which the display
freezes again.

Affects **Safari and Chrome for iOS alike** (both WebKit), in **both orientations**.

## Environment

- iPhone 13, iOS 18.x, `devicePixelRatio` 3
- Reproduced in Safari and in Chrome for iOS
- **Not** reproducible in Playwright's WebKit 26.5 on Linux at the same viewport and dpr
- Device-dependent: 1 of 3 iPhones tested was never affected

## Steps to reproduce

1. Open a WebGL application on an affected iPhone (ours: a Godot 4.6 web export,
   `gl_compatibility` renderer, single-threaded, no `SharedArrayBuffer`)
2. Interact with it. Hold the device still.
3. The screen never updates, although the application is responding.
4. Rotate the device: exactly one frame appears, then it freezes again.

## Expected

Canvas content is presented as it is drawn.

## Actual

Canvas content is presented only when the viewport changes.

## Evidence that the page is rendering correctly

Instrumentation was injected ahead of the application (full source: `boot_diagnostics.js`).

**The engine's main loop runs at full rate.** Counting `requestAnimationFrame` callbacks
registered by the application, separately from our own: **56-60 fps**, continuously.

**Draw calls are issued every frame, to the default framebuffer.** Wrapping
`WebGL2RenderingContext.prototype.drawArrays/drawElements` and tracking the bound DRAW
framebuffer:

```
DRAW 767/s    to-screen 59/s    (at 59 fps)
DRAW 6900/s   to-screen 60/s    (at 60 fps)
```

`to-screen` counts only draws issued while the DRAW framebuffer binding is `null`, i.e.
straight to the default framebuffer. **It equals the frame rate**: the application
composites to the screen on every single frame of a display that never changes.

Draw density also tracks real application state (22 draws/frame on one screen, 39 after
navigating, 115 on another), proving the application advanced through several screens while
the display kept showing the first one.

**The default framebuffer holds the current frame.** With `preserveDrawingBuffer: true`,
`readPixels` immediately after the application's rAF callback shows the buffer contents
changing exactly when the application navigates, and static when the scene is static.

**No errors.** `gl.getError()` drained every frame: clean. `webglcontextlost` never fires.
The drawing buffer always matches `canvas.width/height`; never clamped.

## Not specific to WebGL

A 2D canvas positioned over the WebGL canvas with `pointer-events: none`, receiving
`drawImage(webglCanvas, 0, 0)` after every frame (**3306 blits**, confirmed by counter),
**also never displays**. Nor does a CPU-backed 2D canvas requested with
`willReadFrequently: true`.

So no canvas element presents on the affected device, regardless of context type.

## What does not work around it

All tested on-device, each verified to actually be running:

- **Context attributes:** `antialias` true/false, `preserveDrawingBuffer: true`,
  `alpha: false`, `desynchronized: true`
- **Compositing hints:** `transform: translateZ(0)`, opacity toggling, a hidden element
  running an infinite CSS animation
- **Forced flushes:** `gl.finish()` after every frame
- **CSS box changes:** alternating `canvas.style.height` by 1px **every frame**, applied
  after the application's frame so it survives to the end of it (1344 applications logged)
- **Backing-store changes:** shrinking `canvas.width` before every frame so the application
  reallocates and re-renders within that frame
- **Canvas size:** `devicePixelRatio` forced to 1, canvas 390x658 instead of 1170x1974
- **Canvas aspect:** a landscape-shaped canvas (1170x525) on a portrait-held device
- **Installed PWA** (standalone display mode): identical
- **Private browsing** (no service worker): identical

The only thing that presents a frame is a genuine viewport change, which cannot be
synthesised from JavaScript.

## Instrumented log of a rotation

`geom` lines record every change to canvas pixel size, CSS size and window size:

```
2.14s  geom 1170x1995 css 390px,665px win 390x665     before
6.28s  resize  win 750x330 dpr3
6.36s  geom 2250x990  css 750px,330px win 750x330     one frame presented here
6.59s  orientationchange  win 750x330 dpr3
```

Reproducing both changes synthetically, at up to 60 Hz, does not present anything. The
distinguishing factor appears to be the viewport change forcing a full-page relayout and
re-composite.

## Attachments to include

- `build/lan.log` — full instrumented session logs from the affected device
- `boot_diagnostics.js` — the instrumentation, if useful

## Open question for whoever has a Safari console

Whether the canvas's compositing layer is ever marked dirty (Layers / Timelines panel), and
whether a **minimal WebGL page** (a spinning triangle, no engine) reproduces it on the same
device. A minimal reproduction would make this report much stronger, and no page-level
probe can answer the first.
