# Web / PWA Plan

Ship Limpid Chess as a browser game and installable PWA, reaching iOS and desktop
players without an App Store build. Researched and fact-checked July 2026 (Godot 4.6,
iOS 26 era). Verdict: **doable, near-zero running cost, and a good fit**, with one
real engineering task (Stockfish in the browser) and a few days of polish.

## Why it works

- The project already uses the `gl_compatibility` renderer, which is what the Web
  export requires. No renderer work.
- Since Godot 4.3 the **single-threaded** web export is the default and is the variant
  that works reliably on iOS/macOS Safari. It needs **no COOP/COEP headers**, so plain
  GitHub Pages hosting works. (Threaded builds need `SharedArrayBuffer` + special
  headers and are still flaky on Safari, so we simply never use them.)
- The Web export preset has a built-in **Progressive Web App** option: it generates the
  service worker, manifest, and icons for offline play and Add to Home Screen.
- The repo audit found **zero hard runtime blockers**: the only threading in the
  codebase is inside the StockfishEngine pipe transport (unreachable on web), the three
  Android-plugin autoloads (`Billing`, `Reviews`, `Notifications`) all guard on
  `Engine.has_singleton`, saving is one `user://` ConfigFile (IndexedDB on web), and
  puzzle mode needs no engine at all.
- Payload is small: ~5-6 MB pck + the Godot wasm runtime (~37 MB, ~9.4 MB gzipped).
  First load ≈ 15 MB over the wire, then the PWA cache serves repeats.

## The one real problem: the brain

Neither Stockfish transport exists on web (no subprocess, and the GDExtension has no
wasm build), so today a web export would silently fall back to the GDScript negamax:
weaker teaching evals **and** a synchronous main-thread search measured at 0.26-2.9 s
per turn natively (2-4x slower in wasm). That freezes the page every turn with the
"Reading the position…" label never even painting. Not smooth, not shippable as-is.

**The fix, verified against current docs and builds:** a third StockfishEngine
transport for web, using the maintained `stockfish` npm package (nmrugg/stockfish.js,
built for Chess.com, GPL-3.0, at Stockfish 18 as of Feb 2026):

- Use the **lite single-threaded** flavor (`stockfish-18-lite-single.js/.wasm`, ~7 MB).
  It runs in a plain **Web Worker**: no SharedArrayBuffer, no COOP/COEP, works on
  GitHub Pages and iOS 16+ Safari. The Worker keeps the search off the main thread,
  so the UI stays smooth (this is a browser feature, independent of Godot's
  no-threads build).
- GDScript side: `JavaScriptBridge.eval` spawns the Worker at app boot;
  UCI commands go out via `postMessage`, engine lines come back through a
  `JavaScriptBridge.create_callback` (store the returned JavaScriptObject in a member
  var, or the callback is silently dropped; JS args arrive as a single Array).
  The existing UCI line parser in [stockfish_engine.gd](scripts/chess/stockfish_engine.gd)
  is reused unchanged; the transport slots in beside `ext` and `pipe`.
- Do **not** compile the StockfishGD GDExtension to wasm: Godot web extension support
  requires cross-origin-isolation headers (GitHub Pages can't set them), needs fragile
  emscripten dlink builds matched to the thread mode, and our extension runs its search
  on a native thread that doesn't exist in a no-threads build anyway.
- Two tuning notes: SF 15.1+ uses *normalized* centipawns (+1.00 ≈ 50% win chance), so
  self-play test the option bands (`DECENT_MIN/MAX`, `BLUNDER_MIN/MAX`) and grading
  bands on the web build. And benchmark the depth-10 full-MultiPV pass on a real phone
  early; if it exceeds ~2-3 s, cap the wide pass with movetime instead of raising
  complexity. Set Hash to 16-32 MB.

## Layout & orientation: small work, no redesign

Findings from the layout audit (stretch `canvas_items` + aspect `expand` keeps the
1280 logical height, so a wide window only *widens* the canvas; fonts stay
proportionate by construction):

- **Gameplay is already correct in any window**: both game and puzzle scenes compute
  the board from the live viewport and re-center on resize; extra width shows the dark
  background. iOS Safari's collapsing address bar is handled by the same path.
- **Landscape support: not needed and not possible to avoid.** A PWA cannot lock
  portrait on iPhone (Screen Orientation lock needs the Fullscreen API, iPad-only),
  so the wide-window behavior above *is* the landscape story. It's usable; we just
  clamp the worst offenders below. No landscape redesign.
- Clamp list (~2-3 dev days total, all one-line-ish scene/script changes):
  - [premium.tscn](scenes/premium.tscn), [bots.tscn](scenes/bots.tscn),
    [about.tscn](scenes/about.tscn): content stretches edge-to-edge in wide windows.
    Fix: `size_flags_horizontal = SIZE_SHRINK_CENTER` + `custom_minimum_size.x ≈ 664-680`.
  - In-game top bar / feedback labels and puzzle header: clamp to the board's width in
    `_layout_for_safe_area` / `_layout`, like the eval bar already is.
  - Desktop nicety: pointing-hand cursor on the board while options are interactive.
  - Safe area on web returns (0,0) so the 16px floor kicks in everywhere: correct in a
    browser tab. Only an installed iOS PWA with `viewport-fit=cover` needs care:
    handle it in the HTML shell with `env(safe-area-inset-*)` padding (or just don't
    use cover).
- No LineEdit/TextEdit anywhere (promo codes go through Play), so the iOS virtual
  keyboard is a non-issue. Input is tap-only and already handles mouse + touch.

## Platform gating checklist (small code changes)

- **Export preset**: add a Web preset, `variant/thread_support = false`, exclude
  `addons/stockfish/*` (the .gdextension has no web entry and errors the export
  otherwise). Always export web with the **release** template: in debug,
  [billing.gd](scripts/billing.gd) grants premium locally and the dev reset button shows.
- **Premium screen on web**: hide Get/Restore (price never loads, buy dead-ends) and
  show "Premium is available in the Android app" + Play badge. `OS.has_feature("web")`.
- **Rate-this-app flow** ([reviews.gd](scripts/reviews.gd)): gate on Android; a browser
  player being sent to the Play listing to rate an app they don't have is wrong.
- **Leave-mid-game protection**: the Android back-gesture handler never fires on web;
  register a `beforeunload` handler via JavaScriptBridge while a game is live so the
  browser confirms before closing the tab.
- **Fallback smoothness safety net**: even with the web transport, keep the GDScript
  fallback playable: `await get_tree().process_frame` before the synchronous analysis
  so "Reading the position…" actually paints.

## Hosting: $0

- **Phase 1: GitHub Pages, `docs/play/`** in this repo, beside the landing site
  (which is already deployed from `docs/` on main). Pages serves `application/wasm`
  with on-the-fly gzip, the 100 GB/month soft cap is plenty to start, and the service
  worker scope is naturally confined to `/play/`. `docs/` carries `.gdignore`, so the
  build won't pollute the Godot project. Cost: $0.
- **Later, if it takes off**: custom domain (~$10/yr) + Cloudflare, with the >25 MiB
  wasm served from R2 (free egress). Unlimited free static bandwidth, brotli, and a
  `_headers` file if ever needed. Netlify's new credit pricing (~15 GB/month free) is
  out; itch.io is fine as a *mirror* for discovery but can't be the PWA home (iframe
  on a foreign origin, manifest never attaches to our brand).
- **Release discipline**: the PWA cache is versioned at export time, so every release
  is a full re-export (never just swap the pck). Wire `pwa_needs_update()` /
  `pwa_update()` so players actually get new versions. And test offline-relaunch once
  before advertising offline play: a known Godot bug (#100518, a wrong filename in the
  generated service worker's cache list) has broken PWA offline mode; the fix is a
  one-line patch we can apply to the exported service worker in a build script.

## iOS PWA reality check (verified 2026)

- Install is still the manual share-sheet "Add to Home Screen" (any browser since
  iOS 16.4; no install-prompt API). Since iOS 26, every added site opens standalone
  by default. Expect a weaker funnel than a store listing; that's fine, it's a
  secondary channel.
- **Storage**: Safari deletes site storage after 7 days of Safari use without visiting
  the site, but **installed** home-screen apps are exempt. Also, the installed app has
  a *separate* storage container from the Safari tab: progress does not transfer on
  install. So: encourage installing early, call `navigator.storage.persist()`, and
  treat web saves as best-effort. A save export/import (small code string) is a decent
  later insurance; premium-by-license-key (below) is inherently re-enterable.
- Memory: keep runtime well under ~300 MB on iOS Safari. We're a 2D board + a 7 MB
  engine; not a concern, just don't get fat.
- Audio unlocks on first tap (tap-driven game, non-issue). Push/badges need a push
  server: skip, we're no-backend.
- EU/DMA: Apple's 2024 threat to kill EU home-screen web apps was reversed; no current
  risk.

## Premium on web

**Phase 1 recommendation: no web premium.** Web = the existing 3 free daily games +
official "Get it on Google Play" badge (allowed and encouraged by Google; Apple has no
say over a website). This is the proven free-web-to-paid-app funnel (A Dark Room,
Universal Paperclips), costs ~a day, and carries zero payment/tax/platform risk. It
also tells us whether web players would pay at all. (Web daily-game tracking is
trivially resettable by clearing site data; same stance as clock-cheating: not worth
fighting.)

**Phase 2, if demand shows up: merchant-of-record license keys, not raw Stripe.**
Verified findings:

- Raw **Stripe** doesn't fit a no-backend app twice over: (1) verifying a purchase
  requires the secret key or a webhook consumer, i.e. a server; (2) Stripe Tax only
  *calculates* tax, the seller stays personally liable to register/file/remit VAT
  worldwide. Bad trade for a $3.99 unlock.
- **Lemon Squeezy** (MoR, ~5% + $0.50, handles global VAT) has a public License API
  (`/v1/licenses/activate|validate|deactivate`) authenticated by the key itself,
  CORS-friendly, designed to be called from shipped software. Flow: buy on the landing
  site → key arrives by email → "Redeem key" dialog in game → activate → store
  `{key, is_premium}` in the local save; re-validate silently on load; "restore
  purchase" = paste the key again (standard, accepted pattern; the key is the durable
  entitlement, surviving storage eviction and working across devices). ~2-4 dev days.
  Known risk: Stripe bought Lemon Squeezy and is migrating merchants to Stripe Managed
  Payments; the flow should port, and Gumroad is the fallback.
- Never link the web checkout from inside the Android app for non-US users (Play
  Payments policy); it stays a web-only path.
- GPL angle: anyone can rebuild with premium enabled for free, exactly as on Android.
  Shattered Pixel Dungeon and Mindustry prove convenience-payers fund GPL games anyway.

## Licensing obligations (unchanged, one addition)

The web page conveys the game + stockfish.js wasm (both GPL-3.0), so the play page
needs the same visible "Source & licenses" link as the Play listing:
`github.com/Hatscat/limpidchess`, GPL-3.0, Stockfish credit. OpenMoji CC BY-SA
attribution carries over via the in-game About screen. Nothing else changes.

## Step-by-step

**Phase 0: spike (~1 day)** ✅ done 2026-07-17
1. Add the Web export preset: threads OFF, PWA off for now, release template,
   exclude `addons/stockfish/*`. ✅ (`[preset.1]` in export_presets.cfg; the exclude
   does prevent the "no suitable library" GDExtension export error)
2. Export, serve locally, confirm the game boots and plays with the GDScript fallback
   (add the one-frame yield so the analysis label paints). ✅ Export:
   `godot --headless --path . --export-release "Web" build/web/index.html`.
   Gotcha: a terminal spawned by the VS Code *snap* exports a snap-remapped
   `XDG_DATA_HOME`, so Godot can't find the export templates; prefix with
   `XDG_DATA_HOME=$HOME/.local/share` in that case. Serve with
   `python3 -m http.server 8765` from `build/web/`.
   Verified in headless Chrome (CDP-driven): boots to Home, bots roster, full game
   loop vs Coco with options, "Best move!" reveal, bot reply, next-turn options.
   Result: 37.7 MB wasm (9.4 MB gzipped) + 2.3 MB pck (2.1 MB gzipped).
   Fallback-quality artifact noticed: the auto-opening picked h3/a3 (the depth-3
   PST eval ranks edge pushes near the top); the phase 1 web Stockfish transport
   fixes this, same as it fixes option quality.
3. Test on a desktop browser and an iPhone on the LAN. Go/no-go on feel.
   Desktop: ✅ plays fine; wide-window layout rough as predicted (Phase 2 clamps).
   Phone-over-LAN gotcha: Godot web exports need a **secure context**, and only
   `localhost` is exempt, so plain HTTP on a LAN IP shows "Secure Context - Check
   web server configuration (use HTTPS)". Recipe: self-signed cert with the LAN IP
   in `subjectAltName` (`openssl req -x509 ... -addext "subjectAltName=IP:<lan-ip>"`)
   + a small python `http.server` wrapped in `ssl.SSLContext`, then accept the
   certificate warning once on the phone. (Once deployed to real hosting this
   disappears: GitHub Pages / any host serves HTTPS.)
   ⬜ remaining: the real-iPhone pass over HTTPS.

**Phase 1: real Stockfish on web (~2-3 days)**
4. Ship `stockfish-18-lite-single.js/.wasm` beside `index.html`; spawn the Worker from
   a custom HTML shell (or `JavaScriptBridge.eval`) at boot.
5. Add the `js` transport to [stockfish_engine.gd](scripts/chess/stockfish_engine.gd)
   (postMessage out, `create_callback` in, keep the callback referenced, gate on
   `uciok`/`readyok`, Hash 16-32 MB).
6. Benchmark the per-turn analysis on a mid-range phone; cap with movetime if needed.
7. Self-play test the option/grading bands against SF 18's normalized centipawns;
   nudge constants if the spreads feel off. Run the headless checks + a web self-play.

**Phase 2: web polish (~2-3 days)**
8. Max-width clamps (premium, bots, about, in-game chrome, puzzle header).
9. Platform gating: premium screen message + Play badge, reviews flow off,
   `beforeunload` guard, pointing-hand cursor.
10. Visual pass on desktop + iPhone Safari (screenshot script won't cover this; test
    by hand).

**Phase 3: PWA + release (~1-2 days)**
11. Enable the PWA export option (standalone display, portrait preference, icons,
    background color; "ensure cross-origin isolation headers" OFF).
12. Verify offline relaunch; patch the service worker cache list in a build script if
    bug #100518 still bites. Wire `pwa_update_available` → `pwa_update()`.
13. Deploy to `docs/play/`, link it from the landing page ("Play in your browser",
    with the smooth-first copy), add the source & licenses link to the page.
14. Update the **Product Hunt launch draft** (assets in
    [docs/img/producthunt/](docs/img/producthunt/README.md)): non-Android visitors
    now have an answer. Add "Play in your browser, on iPhone too, installable as an
    app" to the tagline/first-comment copy with the `/play/` link, and consider a
    gallery card showing the game in a browser. PH traffic is mostly desktop + iOS,
    so this turns the launch's biggest dead-end into a playable demo.
15. Announce; watch whether people play and click the Play badge.

**Phase 4: later, optional**
16. Custom domain + Cloudflare/R2 if bandwidth approaches the Pages cap.
17. Lemon Squeezy premium + "Redeem key" dialog if web demand shows up.
18. Save export/import as storage-eviction insurance.

Total for a solid v1 (phases 0-3): **roughly 6-9 dev days**, $0 running cost.
